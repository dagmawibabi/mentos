part of 'market.dart';

/// Renting out part of a phone.
///
/// Storage: a renter opens a lease and pays the whole term into escrow. Each
/// file is encrypted on the renter's phone before the provider fetches it,
/// so the provider holds bytes it cannot read. Before handing a file over,
/// the renter computes a handful of one-time challenges: hash(nonce, file).
/// Audits send a nonce; only a provider that still has every byte can
/// answer. Each passed audit releases the share of the term that has
/// elapsed; failed audits stop payment and, twice in a row, dispute it.
///
/// Compute: fixed job types (compress, resize a photo, proof-of-work) run
/// in an isolate. Nothing the renter sends is executed as code. The renter's
/// phone checks every result before the hold pays out.
extension Resources on Market {
  static const _gib = 1024 * 1024 * 1024;
  static const _day = 86400000;

  // ---- storage leases -----------------------------------------------------

  List<Rec> leases({String? role}) => [
    for (final r in records('lease'))
      if (role == null || r['role'] == role) r,
  ];

  Rec? lease(String lid) => record('lease:$lid');

  int leaseCost(int gb, int days, int perGbDay) => gb * days * perGbDay;

  /// Bytes this phone stores for renters right now.
  int get leasedBytes => leases(role: 'provider')
      .where((r) => leaseStage(r) == 'active')
      .fold<int>(0, (s, r) => s + _storedBytes(r));

  int _storedBytes(Rec r) => (r['files'] as List? ?? const [])
      .whereType<Map>()
      .where((f) => f['stored'] == true)
      .fold<int>(0, (s, f) => s + ((f['sz'] as int?) ?? 0));

  String leaseStage(Rec r) {
    final e = engine.coin?.escrow(r['lock'] as String? ?? '');
    if (e == null) return 'paying';
    if (e.state == HoldState.cancelled) return 'cancelled';
    if (e.state == HoldState.disputed) return 'disputed';
    if (e.remaining == 0 || r['ended'] == true) return 'ended';
    if (!e.acked) return 'requested';
    return nowMs() > (r['end'] as int? ?? 0) ? 'expired' : 'active';
  }

  Future<Rec> rentStorage(Listing offer, {required int gb, required int days}) => _serial(() async {
    final storage = offer.body['storage'];
    if (offer.kind != Kinds.resource || storage is! Map || !offer.active) {
      throw StateError('This phone is not offering storage');
    }
    if (offer.author == me) throw StateError('That is your own offer');
    if (gb < 1 || gb > (storage['gb'] as int)) throw ArgumentError('Choose up to ${storage['gb']} GB');
    if (days < 1 || days > 365) throw ArgumentError('Choose 1 to 365 days');
    final total = leaseCost(gb, days, storage['perGbDay'] as int);
    final lid = toHex(randomBytes(8));
    final now = DateTime.now();
    final lock = await coin.lock(
      offer.author,
      total,
      memo: 'resource:lease:$lid',
      until: now.add(Duration(days: days + 1)),
      ackBy: now.add(const Duration(days: 1)),
    );
    final r = <String, dynamic>{
      'id': 'lease:$lid',
      'kind': 'lease',
      'role': 'renter',
      'lid': lid,
      'listing': offer.id,
      'provider': offer.author,
      'renter': me,
      'gb': gb,
      'days': days,
      'total': total,
      'lock': lock.hash,
      'start': nowMs(),
      'end': nowMs() + days * _day,
      'files': <dynamic>[],
      'audits': <dynamic>[],
    };
    _event(r, me, 'requested', text: '$gb GB for $days days · ${Coin.format(total)} in escrow');
    _save(r);
    await _send(offer.author, 'lease', {
      'lease': {'lid': lid, 'listing': offer.id, 'gb': gb, 'days': days, 'total': total, 'lock': lock.hash},
      'bundle': coin.bundle(lock.hash, depth: 6),
    }, queue: 'mk-lease:$lid');
    return r;
  });

  /// Encrypts [file], prepares audit challenges and asks the provider to keep it.
  Future<void> storeFile(String lid, File file) => _serial(() async {
    final r = lease(lid);
    if (r == null || r['role'] != 'renter') throw StateError('Lease not found');
    if (leaseStage(r) != 'active') throw StateError('The provider has not started this lease yet');
    final size = await file.length();
    final used = (r['files'] as List).whereType<Map>().fold<int>(0, (s, f) => s + ((f['sz'] as int?) ?? 0));
    if (used + size > (r['gb'] as int) * _gib) throw StateError('That would go past ${r['gb']} GB');
    final ref = await engine.media.import(file, scope: 'lease:$lid');
    final path = engine.net.blobPath(ref.hash);
    final cipherSize = await File(path).length();
    final nonces = [for (var i = 0; i < 10; i++) toHex(randomBytes(16))];
    final answers = await _proofsAsync(path, nonces);
    final files = (r['files'] as List).cast<dynamic>().toList()
      ..add({
        'h': ref.hash,
        'sz': cipherSize,
        'ref': ref.toJson(),
        'challenges': [
          for (var i = 0; i < nonces.length; i++) {'n': nonces[i], 'a': answers[i], 'used': false},
        ],
        'stored': false,
        'added': nowMs(),
      });
    r['files'] = files;
    _event(r, me, 'store', text: ref.name);
    _save(r);
    await _send(r['provider'] as String, 'lease-up', {
      'lid': lid,
      'what': 'store',
      'files': [
        {'h': ref.hash, 'sz': cipherSize},
      ],
    }, queue: 'mk-store:$lid:${ref.hash}');
  });

  /// Opens a leased file, fetching it back from the provider when this
  /// phone no longer has a copy.
  Future<File?> retrieveFile(String lid, String hash) async {
    final r = lease(lid);
    final f = (r?['files'] as List?)?.whereType<Map>().where((x) => x['h'] == hash).firstOrNull;
    final ref = mediaFrom(f?['ref']);
    if (r == null || ref == null) return null;
    return engine.media.open(ref, sources: [r['provider'] as String], origin: 'cache');
  }

  /// Drops this phone's encrypted copy once the provider confirmed it,
  /// freeing the space. The key stays here.
  Future<void> offloadFile(String lid, String hash) => _serial(() async {
    final r = lease(lid);
    final f = (r?['files'] as List?)?.whereType<Map>().where((x) => x['h'] == hash).firstOrNull;
    if (r == null || f == null) return;
    if (f['stored'] != true) throw StateError('Wait until the provider confirms it has the file');
    await engine.media.deleteBlob(hash);
    f['offloaded'] = true;
    _save(r);
  });

  /// Sends one unused challenge; the answer arrives as a `proof` message.
  Future<bool> auditLease(String lid) => _serial(() => _audit(lid));

  Future<bool> _audit(String lid) async {
    final r = lease(lid);
    if (r == null || r['role'] != 'renter' || leaseStage(r) != 'active') return false;
    final files = (r['files'] as List).whereType<Map>().where((f) => f['stored'] == true).toList();
    if (files.isEmpty) return false;
    final f = files[math.Random().nextInt(files.length)];
    final c = (f['challenges'] as List).whereType<Map>().where((x) => x['used'] != true).firstOrNull;
    if (c == null) return false;
    c['used'] = true;
    final cid = toHex(randomBytes(6));
    r['pending'] = {'cid': cid, 'h': f['h'], 'a': c['a'], 'ts': nowMs()};
    _save(r);
    return _send(r['provider'] as String, 'lease-up', {'lid': lid, 'what': 'challenge', 'h': f['h'], 'n': c['n'], 'cid': cid});
  }

  Future<void> endLease(String lid) => _serial(() async {
    final r = lease(lid);
    if (r == null || r['role'] != 'renter') return;
    await _releaseAccrued(r);
    r['ended'] = true;
    _event(r, me, 'ended');
    _save(r);
    await _send(r['provider'] as String, 'lease-up', {'lid': lid, 'what': 'end'}, queue: 'mk-end:$lid');
  });

  Future<void> _releaseAccrued(Rec r) async {
    final e = coin.escrow(r['lock'] as String);
    if (e == null || e.remaining == 0 || !e.actionsFor(me, nowMs()).contains('release')) return;
    final days = r['days'] as int;
    final elapsed = ((nowMs() - (r['start'] as int)) / _day).ceil().clamp(1, days);
    final due = e.amount * elapsed ~/ days - e.released;
    if (due <= 0) return;
    final tx = await coin.step(r['lock'] as String, 'release', amount: math.min(due, e.remaining));
    _event(r, me, 'paid', text: 'Released ${Coin.format(tx.amount)} for $elapsed of $days days');
    await _send(r['provider'] as String, 'lease-up', {
      'lid': r['lid'],
      'what': 'paid',
      'bundle': coin.bundle(tx.hash, depth: 3),
    });
  }

  // ---- compute jobs -------------------------------------------------------

  List<Rec> jobs({String? role}) => [
    for (final r in records('job'))
      if (role == null || r['role'] == role) r,
  ];

  Rec? job(String jid) => record('job:$jid');

  int jobUnits(String type, int bytes, Map<String, dynamic> params) => switch (type) {
    'pow' => math.max(1, 1 << math.max(0, ((params['bits'] as int?) ?? 18) - 18)),
    _ => math.max(1, (bytes / (1024 * 1024)).ceil()),
  };

  String jobStage(Rec r) {
    final e = engine.coin?.escrow(r['lock'] as String? ?? '');
    if (e == null) return 'paying';
    if (e.state == HoldState.cancelled) return 'cancelled';
    if (e.state == HoldState.disputed) return 'disputed';
    if (e.remaining == 0) return e.released > 0 ? 'paid' : 'refunded';
    if (r['output'] != null) return r['verified'] == false ? 'failed check' : 'checking';
    if (r['failed'] == true) return 'failed';
    return e.acked ? 'running' : 'sent';
  }

  Future<Rec> submitJob(Listing offer, String type, {File? input, Map<String, dynamic> params = const {}}) =>
      _serial(() async {
        final compute = offer.body['compute'];
        if (offer.kind != Kinds.resource || compute is! Map || !offer.active) {
          throw StateError('This phone is not offering compute');
        }
        if (offer.author == me) throw StateError('That is your own offer');
        if (!(compute['jobs'] as List).contains(type)) throw StateError('They do not run that job');
        MediaRef? ref;
        var bytes = 0;
        if (type != 'pow') {
          if (input == null) throw ArgumentError('Choose a file');
          bytes = await input.length();
          if (bytes > (compute['maxMb'] as int) * 1024 * 1024) {
            throw StateError('They take files up to ${compute['maxMb']} MB');
          }
          ref = await engine.media.import(input);
        } else {
          final bits = params['bits'];
          if (bits is! int || bits < 12 || bits > 28) throw ArgumentError('Difficulty must be 12 to 28 bits');
        }
        final units = jobUnits(type, bytes, params);
        final price = units * (compute['perUnit'] as int);
        final jid = toHex(randomBytes(8));
        final now = DateTime.now();
        final lock = await coin.lock(
          offer.author,
          price,
          memo: 'resource:job:$jid',
          until: now.add(const Duration(days: 1)),
          ackBy: now.add(const Duration(hours: 2)),
        );
        final spec = {
          'jid': jid,
          'type': type,
          'params': params,
          if (ref != null) 'input': ref.toJson(),
          'units': units,
          'price': price,
          'lock': lock.hash,
          'listing': offer.id,
        };
        final r = <String, dynamic>{
          ...spec,
          'id': 'job:$jid',
          'kind': 'job',
          'role': 'renter',
          'provider': offer.author,
          'renter': me,
          'created': nowMs(),
        };
        _event(r, me, 'sent', text: '${jobTypes[type]} · ${Coin.format(price)} in escrow');
        _save(r);
        await _send(offer.author, 'job', {'job': spec, 'bundle': coin.bundle(lock.hash, depth: 6)}, queue: 'mk-job:$jid');
        return r;
      });

  // ---- messages -----------------------------------------------------------

  Future<void> _onResourceMessage(String from, Map<String, dynamic> m) async {
    switch (m['op']) {
      case 'lease':
        await _onLease(from, m);
      case 'lease-up':
        await _onLeaseUp(from, m);
      case 'job':
        await _onJob(from, m);
      case 'job-up':
        await _onJobUp(from, m);
    }
  }

  Future<void> _onLease(String from, Map<String, dynamic> m) async {
    final raw = m['lease'];
    if (raw is! Map) return;
    final lid = raw['lid'], gb = raw['gb'], days = raw['days'], total = raw['total'], lockHash = raw['lock'];
    if (lid is! String || !RegExp(r'^[0-9a-f]{16}$').hasMatch(lid) || lease(lid) != null) return;
    if (gb is! int || days is! int || total is! int || !isId(lockHash)) return;
    final offer = listing('${raw['listing']}');
    final storage = offer?.body['storage'];
    if (offer == null || offer.author != me || storage is! Map) return;
    final reserved = leases(role: 'provider')
        .where((x) => const ['active', 'requested'].contains(leaseStage(x)))
        .fold<int>(0, (s, x) => s + ((x['gb'] as int?) ?? 0));
    final r = <String, dynamic>{
      'id': 'lease:$lid',
      'kind': 'lease',
      'role': 'provider',
      'lid': lid,
      'listing': offer.id,
      'provider': me,
      'renter': from,
      'gb': gb,
      'days': days,
      'total': total,
      'lock': lockHash,
      'start': nowMs(),
      'end': nowMs() + days * _day,
      'files': <dynamic>[],
    };
    final e = await _escrowFrom(m['bundle'], lockHash as String);
    final capacity = (storage['gb'] as int) - reserved;
    final fair = gb >= 1 && days >= 1 && total >= leaseCost(gb, days, storage['perGbDay'] as int);
    final paid = e != null &&
        e.payer == from &&
        e.payee == me &&
        e.amount == total &&
        e.memo == 'resource:lease:$lid';
    _event(r, from, 'requested', text: '$gb GB for $days days');
    _save(r);
    if (!paid || !fair || gb > capacity) {
      if (e != null && e.payee == me && e.remaining > 0) {
        try {
          final tx = await coin.step(lockHash, 'refund');
          _event(r, me, 'declined', text: !fair ? 'Price does not match the offer' : 'Not enough room');
          _save(r);
          await _send(from, 'lease-up', {'lid': lid, 'what': 'declined', 'bundle': coin.bundle(tx.hash, depth: 3)},
              queue: 'mk-lu:$lid:declined');
        } catch (_) {}
      }
      return;
    }
    final tx = await coin.step(lockHash, 'ack');
    _event(r, me, 'accepted');
    _save(r);
    _notify(from, lid, 'lease', 'rented $gb GB of your storage', '/market/r/lease/$lid');
    await _send(from, 'lease-up', {'lid': lid, 'what': 'accepted', 'bundle': coin.bundle(tx.hash, depth: 3)},
        queue: 'mk-lu:$lid:accepted');
  }

  Future<void> _onLeaseUp(String from, Map<String, dynamic> m) async {
    final lid = m['lid'];
    final what = m['what'];
    if (lid is! String || what is! String) return;
    final r = lease(lid);
    if (r == null) return;
    final isProvider = r['role'] == 'provider';
    if (from != (isProvider ? r['renter'] : r['provider'])) return;
    final bundle = m['bundle'];
    if (bundle is List) await coin.absorb(bundle);
    switch (what) {
      case 'accepted' || 'declined' || 'paid-back' when !isProvider:
        _event(r, from, what);
        _save(r);
        _notify(from, lid, what, what == 'accepted' ? 'started your storage lease' : 'declined your lease', '/market/r/lease/$lid');
      case 'stored' when !isProvider:
        final h = m['h'];
        for (final f in (r['files'] as List).whereType<Map>()) {
          if (f['h'] == h) f['stored'] = true;
        }
        _event(r, from, 'stored', eid: 'stored-$h');
        _save(r);
      case 'proof' when !isProvider:
        final pending = r['pending'];
        if (pending is! Map || pending['cid'] != m['cid']) return;
        final ok = m['a'] == pending['a'];
        r.remove('pending');
        final audits = (r['audits'] as List? ?? []).cast<dynamic>().toList()
          ..add({'ts': nowMs(), 'h': pending['h'], 'ok': ok});
        if (audits.length > 60) audits.removeAt(0);
        r['audits'] = audits;
        r['lastAudit'] = nowMs();
        _event(r, from, ok ? 'audit passed' : 'audit failed');
        _save(r);
        if (ok) {
          await _releaseAccrued(r);
          _save(r);
        } else {
          final recent = audits.reversed.take(2).toList();
          if (recent.length == 2 && recent.every((a) => (a as Map)['ok'] == false)) {
            try {
              await coin.step(r['lock'] as String, 'dispute');
              _event(r, me, 'disputed', text: 'Two audits in a row failed');
              _save(r);
            } catch (_) {}
          }
        }
      case 'store' when isProvider:
        await _keepFiles(r, from, m['files']);
      case 'challenge' when isProvider:
        final h = m['h'], n = m['n'], cid = m['cid'];
        if (!isId(h) || n is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(n) || cid is! String) return;
        final kept = (r['files'] as List).whereType<Map>().any((f) => f['h'] == h && f['stored'] == true);
        final path = engine.net.blobPath(h as String);
        var answer = '';
        if (kept && File(path).existsSync()) {
          answer = (await _proofsAsync(path, [n])).first;
        }
        r['lastChallenge'] = nowMs();
        _save(r);
        await _send(from, 'lease-up', {'lid': lid, 'what': 'proof', 'cid': cid, 'a': answer});
      case 'paid' when isProvider:
        _event(r, from, 'paid');
        _save(r);
      case 'end' when isProvider:
        await _finishLease(r);
    }
  }

  Future<void> _keepFiles(Rec r, String renter, Object? raw) async {
    if (raw is! List || leaseStage(r) != 'active') return;
    final files = (r['files'] as List).cast<dynamic>().toList();
    for (final x in raw.take(20)) {
      if (x is! Map || !isId(x['h']) || x['sz'] is! int) continue;
      final h = x['h'] as String, sz = x['sz'] as int;
      if (files.any((f) => f is Map && f['h'] == h)) continue;
      final used = files.whereType<Map>().fold<int>(0, (s, f) => s + ((f['sz'] as int?) ?? 0));
      if (used + sz > (r['gb'] as int) * _gib) continue;
      final free = await _freeBytes(engine.media.blobs.path);
      if (free != null && free < sz + 256 * 1024 * 1024) continue;
      final ok = engine.media.hasBlob(h) || await engine.net.fetchBlob(h, renter);
      if (!ok) continue;
      final actual = await File(engine.net.blobPath(h)).length();
      if (actual != sz) {
        await engine.media.deleteBlob(h);
        continue;
      }
      engine.db.putFile(StoredFile(
        hash: h,
        name: 'lease-${r['lid']}',
        mime: 'application/octet-stream',
        size: sz,
        key: '',
        origin: 'lease',
        scope: 'lease:${r['lid']}',
        created: nowMs(),
      ));
      files.add({'h': h, 'sz': sz, 'stored': true, 'added': nowMs()});
      r['files'] = files;
      _event(r, renter, 'stored', eid: 'stored-$h');
      _save(r);
      await _send(renter, 'lease-up', {'lid': r['lid'], 'what': 'stored', 'h': h}, queue: 'mk-lu:${r['lid']}:$h');
    }
  }

  Future<void> _finishLease(Rec r) async {
    final e = coin.escrow(r['lock'] as String);
    if (e != null && e.remaining > 0 && e.payee == me && !e.disputed) {
      try {
        final tx = await coin.step(r['lock'] as String, 'refund');
        await _send(r['renter'] as String, 'lease-up', {'lid': r['lid'], 'what': 'paid-back', 'bundle': coin.bundle(tx.hash, depth: 3)});
      } catch (_) {}
    }
    for (final f in (r['files'] as List).whereType<Map>()) {
      final h = f['h'];
      if (h is String) await engine.media.deleteBlob(h);
      f['stored'] = false;
    }
    r['ended'] = true;
    _event(r, me, 'ended');
    _save(r);
  }

  Future<void> _onJob(String from, Map<String, dynamic> m) async {
    final raw = m['job'];
    if (raw is! Map) return;
    final spec = raw.cast<String, dynamic>();
    final jid = spec['jid'], type = spec['type'], lockHash = spec['lock'];
    if (jid is! String || !RegExp(r'^[0-9a-f]{16}$').hasMatch(jid) || job(jid) != null) return;
    if (type is! String || !jobTypes.containsKey(type) || !isId(lockHash)) return;
    final params = spec['params'] is Map ? (spec['params'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    if (jsonEncode(params).length > 600) return;
    final offer = listing('${spec['listing']}');
    final compute = offer?.body['compute'];
    if (offer == null || offer.author != me || compute is! Map || !(compute['jobs'] as List).contains(type)) return;
    final input = mediaFrom(spec['input']);
    final r = <String, dynamic>{
      'id': 'job:$jid',
      'kind': 'job',
      'role': 'provider',
      'jid': jid,
      'type': type,
      'params': params,
      if (input != null) 'input': input.toJson(),
      'lock': lockHash,
      'listing': offer.id,
      'provider': me,
      'renter': from,
      'created': nowMs(),
    };
    _event(r, from, 'sent');
    _save(r);
    final e = await _escrowFrom(m['bundle'], lockHash as String);
    final units = jobUnits(type, input?.size ?? 0, params);
    final price = units * (compute['perUnit'] as int);
    final tooBig = (input?.size ?? 0) > (compute['maxMb'] as int) * 1024 * 1024;
    final paid = e != null && e.payer == from && e.payee == me && e.amount >= price && e.memo == 'resource:job:$jid';
    if (!paid || tooBig || (type != 'pow' && input == null)) {
      await _jobFailed(r, e, tooBig ? 'File too large' : 'Payment does not match');
      return;
    }
    await coin.step(lockHash, 'ack');
    r['units'] = units;
    r['price'] = e.amount;
    _save(r);
    unawaited(_runJob(r, input));
  }

  Future<void> _runJob(Rec r, MediaRef? input) async {
    final renter = r['renter'] as String;
    try {
      String? inPath;
      if (input != null) {
        final f = await engine.media.open(input, sources: [renter]);
        if (f == null) throw StateError('Could not fetch the input');
        inPath = f.path;
      }
      final type = r['type'] as String;
      final params = (r['params'] as Map).cast<String, dynamic>();
      final ext = switch (type) {
        'gzip' => '.gz',
        'image' => '.jpg',
        _ => '.json',
      };
      final outPath = engine.media.newTmpPath(ext);
      final watch = Stopwatch()..start();
      await _executeAsync(type, inPath, outPath, params).timeout(const Duration(minutes: 3));
      final ms = watch.elapsedMilliseconds;
      final name = switch (type) {
        'gzip' => '${input?.name ?? 'file'}.gz',
        'image' => 'resized.jpg',
        _ => 'stamp.json',
      };
      final out = await engine.media.import(File(outPath), name: name, deleteSource: true);
      await _serial(() async {
        final rec = job(r['jid'] as String) ?? r;
        rec['output'] = out.toJson();
        rec['ms'] = ms;
        _event(rec, me, 'done', text: 'Finished in ${(ms / 1000).toStringAsFixed(1)} s');
        _save(rec);
        await _send(renter, 'job-up', {'jid': r['jid'], 'what': 'done', 'output': out.toJson(), 'ms': ms},
            queue: 'mk-ju:${r['jid']}:done');
        _notify(renter, r['jid'] as String, 'job', 'ran a job for you', '/market/r/job/${r['jid']}');
      });
    } catch (e) {
      await _serial(() async {
        final rec = job(r['jid'] as String) ?? r;
        await _jobFailed(rec, coin.escrow(rec['lock'] as String), '$e');
      });
    }
  }

  Future<void> _jobFailed(Rec r, Escrow? e, String why) async {
    r['failed'] = true;
    _event(r, me, 'failed', text: why.length > 200 ? why.substring(0, 200) : why);
    _save(r);
    String? hash;
    if (e != null && e.payee == me && e.remaining > 0) {
      try {
        hash = (await coin.step(r['lock'] as String, 'refund')).hash;
      } catch (_) {}
    }
    await _send(r['renter'] as String, 'job-up', {
      'jid': r['jid'],
      'what': 'failed',
      'text': why.length > 200 ? why.substring(0, 200) : why,
      if (hash != null) 'bundle': coin.bundle(hash, depth: 3),
    }, queue: 'mk-ju:${r['jid']}:failed');
  }

  Future<void> _onJobUp(String from, Map<String, dynamic> m) async {
    final jid = m['jid'];
    if (jid is! String) return;
    final r = job(jid);
    if (r == null || r['role'] != 'renter' || r['provider'] != from) return;
    final bundle = m['bundle'];
    if (bundle is List) await coin.absorb(bundle);
    switch (m['what']) {
      case 'failed':
        r['failed'] = true;
        _event(r, from, 'failed', text: m['text'] is String ? m['text'] as String : '');
        _save(r);
      case 'done':
        final out = mediaFrom(m['output']);
        if (out == null || r['output'] != null) return;
        r['output'] = out.toJson();
        r['ms'] = m['ms'] is int ? m['ms'] : null;
        _event(r, from, 'done');
        _save(r);
        _notify(from, jid, 'done', 'finished your job', '/market/r/job/$jid');
        unawaited(_serial(() => _checkJob(jid)));
    }
  }

  /// Verifies a result and pays for it, or disputes it.
  Future<void> _checkJob(String jid) async {
    final r = job(jid);
    if (r == null || r['verified'] != null) return;
    final out = mediaFrom(r['output']);
    if (out == null) return;
    final outFile = await engine.media.open(out, sources: [r['provider'] as String]);
    if (outFile == null) return;
    final input = mediaFrom(r['input']);
    final inFile = input == null ? null : await engine.media.open(input);
    final type = r['type'] as String;
    final params = (r['params'] as Map).cast<String, dynamic>();
    final inPath = inFile?.path, outPath = outFile.path;
    final ok = await _verifyAsync(type, inPath, outPath, params);
    r['verified'] = ok;
    _event(r, me, ok ? 'verified' : 'check failed');
    _save(r);
    try {
      final step = await coin.step(r['lock'] as String, ok ? 'release' : 'dispute');
      await _send(r['provider'] as String, 'job-up', {'jid': jid, 'what': ok ? 'paid' : 'disputed', 'bundle': coin.bundle(step.hash, depth: 3)});
    } catch (_) {}
  }

  Future<void> recheckJob(String jid) => _serial(() async {
    final r = job(jid);
    if (r == null) return;
    r.remove('verified');
    _save(r);
    await _checkJob(jid);
  });

  // ---- housekeeping -------------------------------------------------------

  Future<void> _resourcesTick() async {
    final c = engine.coin;
    if (c == null) return;
    for (final r in leases()) {
      final stage = leaseStage(r);
      final lock = r['lock'] as String;
      if (r['role'] == 'renter' && stage == 'active') {
        final last = r['lastAudit'] as int? ?? r['start'] as int;
        final pending = r['pending'];
        if (pending is Map && nowMs() - (pending['ts'] as int) > 3600000) {
          r.remove('pending');
          _save(r);
        }
        if (nowMs() - last > const Duration(hours: 12).inMilliseconds && r['pending'] == null) {
          await _audit(r['lid'] as String);
        }
      }
      if (r['role'] == 'provider') {
        final e = c.escrow(lock);
        if (e != null && e.actionsFor(me, nowMs()).contains('claim')) {
          try {
            await c.step(lock, 'claim');
            _event(r, me, 'claimed');
            _save(r);
          } catch (_) {}
        }
        if ((stage == 'expired' || stage == 'ended') &&
            r['ended'] != true &&
            nowMs() > (r['end'] as int) + _day) {
          await _finishLease(r);
        }
      }
    }
    for (final r in jobs(role: 'provider')) {
      final e = c.escrow(r['lock'] as String? ?? '');
      if (e != null && e.actionsFor(me, nowMs()).contains('claim')) {
        try {
          await c.step(r['lock'] as String, 'claim');
        } catch (_) {}
      }
    }
  }
}

// ---- isolate work ---------------------------------------------------------

// Isolate.run copies everything its closure captures. These top-level
// wrappers keep the closures down to plain arguments.
Future<List<String>> _proofsAsync(String path, List<String> nonces) =>
    Isolate.run(() => _proofs(path, nonces));

Future<void> _executeAsync(String type, String? inPath, String outPath, Map<String, dynamic> params) =>
    Isolate.run(() => _execute(type, inPath, outPath, params));

Future<bool> _verifyAsync(String type, String? inPath, String outPath, Map<String, dynamic> params) =>
    Isolate.run(() => _verify(type, inPath, outPath, params));

/// sha256(nonce ‖ file) for each nonce, in one pass over the file.
List<String> _proofs(String path, List<String> nonces) {
  final sinks = [for (final _ in nonces) _Sink()];
  final inputs = [
    for (var i = 0; i < nonces.length; i++) hashes.sha256.startChunkedConversion(sinks[i])..add(fromHex(nonces[i])),
  ];
  final f = File(path).openSync();
  try {
    while (true) {
      final chunk = f.readSync(1024 * 1024);
      if (chunk.isEmpty) break;
      for (final input in inputs) {
        input.add(chunk);
      }
    }
  } finally {
    f.closeSync();
  }
  for (final input in inputs) {
    input.close();
  }
  return [for (final s in sinks) s.value.toString()];
}

void _execute(String type, String? inPath, String outPath, Map<String, dynamic> params) {
  switch (type) {
    case 'gzip':
      final data = File(inPath!).readAsBytesSync();
      File(outPath).writeAsBytesSync(GZipCodec(level: 9).encode(data), flush: true);
    case 'image':
      final decoded = img.decodeImage(File(inPath!).readAsBytesSync());
      if (decoded == null) throw StateError('Not an image');
      final max = ((params['max'] as int?) ?? 1280).clamp(64, 8192);
      final q = ((params['q'] as int?) ?? 80).clamp(20, 100);
      final scaled = decoded.width >= decoded.height
          ? (decoded.width > max ? img.copyResize(decoded, width: max) : decoded)
          : (decoded.height > max ? img.copyResize(decoded, height: max) : decoded);
      File(outPath).writeAsBytesSync(img.encodeJpg(scaled, quality: q), flush: true);
    case 'pow':
      final challenge = '${params['challenge'] ?? ''}';
      final bits = (params['bits'] as int).clamp(12, 28);
      for (var nonce = 0; nonce < 1 << 34; nonce++) {
        final digest = hashes.sha256.convert(utf8.encode('$challenge:$nonce')).bytes;
        if (_leadingZeros(digest) >= bits) {
          File(outPath).writeAsStringSync(jsonEncode({'challenge': challenge, 'bits': bits, 'nonce': nonce, 'hash': toHex(digest)}), flush: true);
          return;
        }
      }
      throw StateError('No stamp found');
    default:
      throw StateError('Unknown job');
  }
}

bool _verify(String type, String? inPath, String outPath, Map<String, dynamic> params) {
  try {
    switch (type) {
      case 'gzip':
        final restored = GZipCodec().decode(File(outPath).readAsBytesSync());
        final original = File(inPath!).readAsBytesSync();
        return hashes.sha256.convert(restored) == hashes.sha256.convert(original);
      case 'image':
        final decoded = img.decodeImage(File(outPath).readAsBytesSync());
        if (decoded == null) return false;
        final max = ((params['max'] as int?) ?? 1280).clamp(64, 8192);
        return decoded.width <= max && decoded.height <= max;
      case 'pow':
        final m = jsonDecode(File(outPath).readAsStringSync()) as Map;
        final challenge = '${params['challenge'] ?? ''}';
        if (m['challenge'] != challenge || m['nonce'] is! int) return false;
        final digest = hashes.sha256.convert(utf8.encode('$challenge:${m['nonce']}')).bytes;
        return _leadingZeros(digest) >= (params['bits'] as int);
    }
  } catch (_) {}
  return false;
}

int _leadingZeros(List<int> bytes) {
  var n = 0;
  for (final b in bytes) {
    if (b == 0) {
      n += 8;
      continue;
    }
    var x = b;
    while (x & 0x80 == 0) {
      n++;
      x <<= 1;
    }
    break;
  }
  return n;
}
