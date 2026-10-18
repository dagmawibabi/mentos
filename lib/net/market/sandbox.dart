part of 'market.dart';

/// Renting a sandbox on someone's device.
///
/// The renter pays an hourly rate for a block of hours into escrow and gets
/// a private workspace on the provider's device: a folder with a size limit,
/// and a script runner. Scripts are MentosScript (the same sandboxed
/// JavaScript subset plugins use). They run in an isolate on a step budget
/// and can only touch files inside their own workspace. Nothing native is
/// ever executed.
///
/// Files are readable by the provider's device, since the scripts need to
/// read them; the console says so. Storage leases are the private option.
///
/// Payment accrues by the hour: the renter releases the elapsed share as
/// time passes, and ending early refunds the rest.
///
/// A demo box runs the same workspace on this device, free, so anyone can
/// try the console before renting.
extension Sandboxes on Market {
  static const _hour = 3600000;
  static const maxRunsKept = 40;

  List<Rec> boxes({String? role}) => [
    for (final r in records('box'))
      if (role == null || r['role'] == role) r,
  ];

  Rec? box(String bid) => record('box:$bid');

  String boxStage(Rec r) {
    if (r['role'] == 'demo') return r['ended'] == true ? 'ended' : 'active';
    final e = engine.coin?.escrow(r['lock'] as String? ?? '');
    if (e == null) return 'paying';
    if (e.state == HoldState.cancelled) return 'cancelled';
    if (e.state == HoldState.disputed) return 'disputed';
    if (r['ended'] == true || e.remaining == 0) return 'ended';
    if (!e.acked) return 'requested';
    return nowMs() > (r['end'] as int? ?? 0) ? 'expired' : 'active';
  }

  /// Where a box keeps its files on the device that hosts it.
  Directory boxDir(String bid) => Directory('${engine.media.root}${Platform.pathSeparator}boxes${Platform.pathSeparator}$bid');

  int boxQuota(Rec r) => ((r['mb'] as int?) ?? 64) * 1024 * 1024;

  // ---- renter -------------------------------------------------------------

  Future<Rec> rentBox(Listing offer, {required int hours}) => _serial(() async {
    final sb = offer.body['sandbox'];
    if (offer.kind != Kinds.resource || sb is! Map || !offer.active) throw StateError('This device is not offering a sandbox');
    if (offer.author == me) throw StateError('That is your own offer');
    final maxH = (sb['maxHours'] as int?) ?? 72;
    if (hours < 1 || hours > maxH) throw ArgumentError('Choose 1 to $maxH hours');
    final total = hours * (sb['perHour'] as int);
    final bid = toHex(randomBytes(8));
    final now = DateTime.now();
    final lock = await coin.lock(
      offer.author,
      total,
      memo: 'resource:box:$bid',
      until: now.add(Duration(hours: hours + 24)),
      ackBy: now.add(const Duration(hours: 6)),
    );
    final r = <String, dynamic>{
      'id': 'box:$bid',
      'kind': 'box',
      'role': 'renter',
      'bid': bid,
      'listing': offer.id,
      'provider': offer.author,
      'renter': me,
      'hours': hours,
      'total': total,
      'mb': sb['mb'] ?? 64,
      'steps': sb['steps'] ?? 2000000,
      'lock': lock.hash,
      'start': nowMs(),
      'end': nowMs() + hours * _hour,
      'files': <dynamic>[],
      'runs': <dynamic>[],
    };
    _event(r, me, 'requested', text: '$hours h · ${Coin.format(total)} in escrow');
    _save(r);
    await _send(offer.author, 'box', {
      'box': {'bid': bid, 'listing': offer.id, 'hours': hours, 'total': total, 'lock': lock.hash},
      'bundle': coin.bundle(lock.hash, depth: 6),
    }, queue: 'mk-box:$bid');
    return r;
  });

  /// A free box on this device, for trying the console.
  Rec startDemoBox() {
    final bid = toHex(randomBytes(8));
    final r = <String, dynamic>{
      'id': 'box:$bid',
      'kind': 'box',
      'role': 'demo',
      'bid': bid,
      'provider': me,
      'renter': me,
      'hours': 1,
      'total': 0,
      'mb': 16,
      'steps': 2000000,
      'start': nowMs(),
      'end': nowMs() + _hour,
      'files': <dynamic>[],
      'runs': <dynamic>[],
    };
    final dir = boxDir(bid)..createSync(recursive: true);
    for (final e in demoFiles.entries) {
      File('${dir.path}${Platform.pathSeparator}${e.key}').writeAsStringSync(e.value);
    }
    r['files'] = _listFiles(bid);
    _event(r, me, 'demo', text: 'A free sandbox on this device');
    _save(r);
    return r;
  }

  /// Runs [code] in the box. The result arrives on the record's `runs`.
  Future<String> runInBox(String bid, String code, {Map<String, dynamic> args = const {}}) => _serial(() async {
    final r = box(bid);
    if (r == null || r['role'] == 'provider') throw StateError('Box not found');
    if (boxStage(r) != 'active') throw StateError('This sandbox is not active');
    if (code.trim().isEmpty) throw ArgumentError('Write some code first');
    if (code.length > 64 * 1024) throw ArgumentError('Scripts are limited to 64 KB');
    final rid = toHex(randomBytes(6));
    _addRun(r, {'rid': rid, 'code': _clip(code, 400), 'ts': nowMs(), 'state': 'running'});
    _save(r);
    if (r['role'] == 'demo') {
      unawaited(_runLocal(r, rid, code, args));
    } else {
      await _send(r['provider'] as String, 'box-up', {'bid': bid, 'what': 'run', 'rid': rid, 'code': code, 'args': args});
    }
    return rid;
  });

  Future<void> _runLocal(Rec r, String rid, String code, Map<String, dynamic> args) async {
    final out = await _boxRunAsync(boxDir(r['bid'] as String).path, code, args, boxQuota(r), (r['steps'] as int?) ?? 2000000);
    await _serial(() async {
      final rec = box(r['bid'] as String) ?? r;
      _finishRun(rec, rid, out);
      rec['files'] = _listFiles(rec['bid'] as String);
      _save(rec);
    });
  }

  /// Copies a file from this device into the box.
  Future<void> putInBox(String bid, File file, {String? name}) => _serial(() async {
    final r = box(bid);
    if (r == null || r['role'] == 'provider') throw StateError('Box not found');
    if (boxStage(r) != 'active') throw StateError('This sandbox is not active');
    final n = _safeName(name ?? file.uri.pathSegments.last);
    final size = await file.length();
    final used = _usedBytes(r);
    if (used + size > boxQuota(r)) throw StateError('That would go past ${r['mb']} MB');
    if (r['role'] == 'demo') {
      await file.copy('${boxDir(bid).path}${Platform.pathSeparator}$n');
      r['files'] = _listFiles(bid);
      _event(r, me, 'uploaded', text: n);
      _save(r);
      return;
    }
    final ref = await engine.media.import(file, name: n, scope: 'box:$bid');
    final files = (r['files'] as List).whereType<Map>().where((f) => f['name'] != n).toList()
      ..add({'name': n, 'size': size, 'ts': nowMs(), 'pending': true});
    r['files'] = files;
    _event(r, me, 'uploading', text: n);
    _save(r);
    await _send(r['provider'] as String, 'box-up', {'bid': bid, 'what': 'put', 'name': n, 'ref': ref.toJson()}, queue: 'mk-boxput:$bid:$n');
  });

  /// Brings a box file to this device. Returns null until it arrives.
  Future<File?> getFromBox(String bid, String name) async {
    final r = box(bid);
    if (r == null) return null;
    final n = _safeName(name);
    if (r['role'] == 'demo') {
      final f = File('${boxDir(bid).path}${Platform.pathSeparator}$n');
      return f.existsSync() ? f : null;
    }
    final have = (r['files'] as List).whereType<Map>().where((f) => f['name'] == n).firstOrNull;
    final ref = mediaFrom(have?['ref']);
    if (ref != null) {
      final f = await engine.media.open(ref, sources: [r['provider'] as String]);
      if (f != null) return f;
    }
    await _send(r['provider'] as String, 'box-up', {'bid': bid, 'what': 'get', 'name': n});
    return null;
  }

  Future<void> deleteFromBox(String bid, String name) => _serial(() async {
    final r = box(bid);
    if (r == null || r['role'] == 'provider') return;
    final n = _safeName(name);
    if (r['role'] == 'demo') {
      final f = File('${boxDir(bid).path}${Platform.pathSeparator}$n');
      if (f.existsSync()) f.deleteSync();
      r['files'] = _listFiles(bid);
      _save(r);
      return;
    }
    r['files'] = (r['files'] as List).whereType<Map>().where((f) => f['name'] != n).toList();
    _save(r);
    await _send(r['provider'] as String, 'box-up', {'bid': bid, 'what': 'del', 'name': n});
  });

  Future<void> endBox(String bid) => _serial(() async {
    final r = box(bid);
    if (r == null) return;
    if (r['role'] == 'demo') {
      r['ended'] = true;
      try {
        boxDir(bid).deleteSync(recursive: true);
      } catch (_) {}
      _save(r);
      return;
    }
    if (r['role'] == 'provider') {
      await _finishBox(r, reason: 'The host ended the session');
      return;
    }
    await _releaseBoxAccrued(r);
    r['ended'] = true;
    _event(r, me, 'ended');
    _save(r);
    await _send(r['provider'] as String, 'box-up', {'bid': bid, 'what': 'end'}, queue: 'mk-boxend:$bid');
  });

  Future<void> _releaseBoxAccrued(Rec r) async {
    final e = coin.escrow(r['lock'] as String);
    if (e == null || e.remaining == 0 || !e.actionsFor(me, nowMs()).contains('release')) return;
    final hours = r['hours'] as int;
    final elapsed = ((nowMs() - (r['start'] as int)) / _hour).ceil().clamp(1, hours);
    final due = e.amount * elapsed ~/ hours - e.released;
    if (due <= 0) return;
    final tx = await coin.step(r['lock'] as String, 'release', amount: math.min(due, e.remaining));
    _event(r, me, 'paid', text: 'Released ${Coin.format(tx.amount)} for $elapsed of $hours h');
    await _send(r['provider'] as String, 'box-up', {'bid': r['bid'], 'what': 'paid', 'bundle': coin.bundle(tx.hash, depth: 3)});
  }

  // ---- provider -----------------------------------------------------------

  Future<void> _onBox(String from, Map<String, dynamic> m) async {
    final raw = m['box'];
    if (raw is! Map) return;
    final bid = raw['bid'], hours = raw['hours'], total = raw['total'], lockHash = raw['lock'];
    if (bid is! String || !RegExp(r'^[0-9a-f]{16}$').hasMatch(bid) || box(bid) != null) return;
    if (hours is! int || total is! int || !isId(lockHash)) return;
    final offer = listing('${raw['listing']}');
    final sb = offer?.body['sandbox'];
    if (offer == null || offer.author != me || sb is! Map) return;
    final r = <String, dynamic>{
      'id': 'box:$bid',
      'kind': 'box',
      'role': 'provider',
      'bid': bid,
      'listing': offer.id,
      'provider': me,
      'renter': from,
      'hours': hours,
      'total': total,
      'mb': sb['mb'] ?? 64,
      'steps': sb['steps'] ?? 2000000,
      'lock': lockHash,
      'start': nowMs(),
      'end': nowMs() + hours * _hour,
      'files': <dynamic>[],
      'runs': <dynamic>[],
    };
    final e = await _escrowFrom(m['bundle'], lockHash as String);
    final fair = hours >= 1 && hours <= ((sb['maxHours'] as int?) ?? 72) && total >= hours * (sb['perHour'] as int);
    final active = boxes(role: 'provider').where((x) => boxStage(x) == 'active').length;
    final paid = e != null && e.payer == from && e.payee == me && e.amount == total && e.memo == 'resource:box:$bid';
    _event(r, from, 'requested', text: '$hours h');
    _save(r);
    if (!paid || !fair || active >= ((sb['slots'] as int?) ?? 2)) {
      if (e != null && e.payee == me && e.remaining > 0) {
        try {
          final tx = await coin.step(lockHash, 'refund');
          _event(r, me, 'declined', text: !fair ? 'Price does not match the offer' : 'No free slot');
          r['ended'] = true;
          _save(r);
          await _send(from, 'box-up', {'bid': bid, 'what': 'declined', 'bundle': coin.bundle(tx.hash, depth: 3)}, queue: 'mk-bu:$bid:declined');
        } catch (_) {}
      }
      return;
    }
    final tx = await coin.step(lockHash, 'ack');
    boxDir(bid).createSync(recursive: true);
    _event(r, me, 'accepted');
    _save(r);
    _notify(from, bid, 'box', 'rented a sandbox on your device for $hours h', '/market/box/$bid');
    await _send(from, 'box-up', {'bid': bid, 'what': 'accepted', 'files': const [], 'bundle': coin.bundle(tx.hash, depth: 3)},
        queue: 'mk-bu:$bid:accepted');
  }

  Future<void> _onBoxUp(String from, Map<String, dynamic> m) async {
    final bid = m['bid'], what = m['what'];
    if (bid is! String || what is! String) return;
    final r = box(bid);
    if (r == null) return;
    final isProvider = r['role'] == 'provider';
    if (from != (isProvider ? r['renter'] : r['provider'])) return;
    final bundle = m['bundle'];
    if (bundle is List) await coin.absorb(bundle);

    if (!isProvider) {
      switch (what) {
        case 'accepted' || 'declined' || 'ended' || 'paid-back':
          if (what != 'accepted') r['ended'] = true;
          if (m['files'] is List) r['files'] = m['files'];
          _event(r, from, what, text: m['text'] is String ? m['text'] as String : '');
          _save(r);
          _notify(from, bid, what, switch (what) {
            'accepted' => 'opened your sandbox',
            'declined' => 'declined your sandbox',
            _ => 'closed your sandbox',
          }, '/market/box/$bid');
        case 'out':
          final rid = m['rid'];
          if (rid is! String || m['out'] is! Map) return;
          _finishRun(r, rid, (m['out'] as Map).cast<String, dynamic>());
          if (m['files'] is List) r['files'] = _mergeRefs(r, m['files'] as List);
          _save(r);
        case 'files':
          if (m['files'] is List) r['files'] = _mergeRefs(r, m['files'] as List);
          _save(r);
        case 'file':
          final ref = mediaFrom(m['ref']);
          final name = m['name'];
          if (ref == null || name is! String) return;
          for (final f in (r['files'] as List).whereType<Map>()) {
            if (f['name'] == name) f['ref'] = ref.toJson();
          }
          _save(r);
      }
      return;
    }

    if (boxStage(r) != 'active' && what != 'end' && what != 'paid') {
      await _send(from, 'box-up', {'bid': bid, 'what': 'ended', 'text': 'This sandbox is no longer active'});
      return;
    }
    final dir = boxDir(bid);
    switch (what) {
      case 'run':
        final rid = m['rid'], code = m['code'];
        if (rid is! String || rid.length > 20 || code is! String || code.length > 64 * 1024) return;
        if (r['busy'] == true) {
          await _send(from, 'box-up', {'bid': bid, 'what': 'out', 'rid': rid, 'out': {'ok': false, 'error': 'Another run is still going'}});
          return;
        }
        r['busy'] = true;
        _addRun(r, {'rid': rid, 'code': _clip(code, 400), 'ts': nowMs(), 'state': 'running'});
        _save(r);
        final args = m['args'] is Map ? (m['args'] as Map).cast<String, dynamic>() : <String, dynamic>{};
        unawaited(() async {
          final out = await _boxRunAsync(dir.path, code, args, boxQuota(r), (r['steps'] as int?) ?? 2000000);
          await _serial(() async {
            final rec = box(bid) ?? r;
            rec['busy'] = false;
            _finishRun(rec, rid, out);
            rec['files'] = _listFiles(bid);
            final usage = (rec['usage'] as Map?)?.cast<String, dynamic>() ?? {'runs': 0, 'steps': 0, 'ms': 0};
            usage['runs'] = (usage['runs'] as int) + 1;
            usage['steps'] = (usage['steps'] as int) + ((out['steps'] as int?) ?? 0);
            usage['ms'] = (usage['ms'] as int) + ((out['ms'] as int?) ?? 0);
            rec['usage'] = usage;
            _save(rec);
            await _send(from, 'box-up', {'bid': bid, 'what': 'out', 'rid': rid, 'out': out, 'files': rec['files']});
          });
        }());
      case 'put':
        final name = m['name'];
        final ref = mediaFrom(m['ref']);
        if (name is! String || ref == null) return;
        final n = _safeName(name);
        if (_usedBytes(r) + ref.size > boxQuota(r)) {
          await _send(from, 'box-up', {'bid': bid, 'what': 'files', 'files': _listFiles(bid)});
          return;
        }
        final f = await engine.media.open(ref, sources: [from]);
        if (f != null) {
          dir.createSync(recursive: true);
          await f.copy('${dir.path}${Platform.pathSeparator}$n');
          _event(r, from, 'uploaded', text: n);
        }
        r['files'] = _listFiles(bid);
        _save(r);
        await _send(from, 'box-up', {'bid': bid, 'what': 'files', 'files': r['files']});
      case 'get':
        final name = m['name'];
        if (name is! String) return;
        final file = File('${dir.path}${Platform.pathSeparator}${_safeName(name)}');
        if (!file.existsSync()) return;
        final ref = await engine.media.import(file, name: _safeName(name), scope: 'box:$bid');
        await _send(from, 'box-up', {'bid': bid, 'what': 'file', 'name': _safeName(name), 'ref': ref.toJson()});
      case 'del':
        final name = m['name'];
        if (name is! String) return;
        final file = File('${dir.path}${Platform.pathSeparator}${_safeName(name)}');
        if (file.existsSync()) file.deleteSync();
        r['files'] = _listFiles(bid);
        _save(r);
        await _send(from, 'box-up', {'bid': bid, 'what': 'files', 'files': r['files']});
      case 'paid':
        _event(r, from, 'paid');
        _save(r);
      case 'end':
        await _finishBox(r, reason: 'The renter ended the session');
    }
  }

  Future<void> _finishBox(Rec r, {String reason = ''}) async {
    if (r['ended'] == true) return;
    final e = coin.escrow(r['lock'] as String? ?? '');
    String? hash;
    if (e != null && e.remaining > 0 && e.payee == me && !e.disputed) {
      try {
        hash = (await coin.step(r['lock'] as String, 'refund')).hash;
      } catch (_) {}
    }
    try {
      boxDir(r['bid'] as String).deleteSync(recursive: true);
    } catch (_) {}
    r['ended'] = true;
    _event(r, me, 'ended', text: reason);
    _save(r);
    await _send(r['renter'] as String, 'box-up', {
      'bid': r['bid'],
      'what': 'paid-back',
      'text': reason,
      if (hash != null) 'bundle': coin.bundle(hash, depth: 3),
    }, queue: 'mk-bu:${r['bid']}:end');
  }

  Future<void> _boxesTick() async {
    final c = engine.coin;
    if (c == null) return;
    for (final r in boxes()) {
      final stage = boxStage(r);
      if (r['role'] == 'renter' && (stage == 'active' || stage == 'expired')) {
        await _releaseBoxAccrued(r);
      }
      if (r['role'] == 'provider') {
        final e = c.escrow(r['lock'] as String? ?? '');
        if (e != null && e.actionsFor(me, nowMs()).contains('claim')) {
          try {
            await c.step(r['lock'] as String, 'claim');
          } catch (_) {}
        }
        if (stage == 'expired' && nowMs() > (r['end'] as int) + _hour) {
          await _finishBox(r, reason: 'Time is up');
        }
      }
      if (r['role'] == 'demo' && stage == 'active' && nowMs() > (r['end'] as int)) {
        r['ended'] = true;
        _save(r);
      }
    }
  }

  // ---- helpers ------------------------------------------------------------

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  static String _safeName(String name) {
    final n = name.split(RegExp(r'[\\/]')).last.trim();
    if (!RegExp(r'^[\w.\- ]{1,80}$').hasMatch(n) || n.startsWith('.')) throw ArgumentError('File names are letters, digits, spaces, . _ and -');
    return n;
  }

  int _usedBytes(Rec r) => (r['files'] as List? ?? const []).whereType<Map>().fold<int>(0, (s, f) => s + ((f['size'] as int?) ?? 0));

  List<Map<String, dynamic>> _listFiles(String bid) {
    final dir = boxDir(bid);
    if (!dir.existsSync()) return [];
    return [
      for (final f in dir.listSync().whereType<File>())
        {'name': f.uri.pathSegments.last, 'size': f.lengthSync(), 'ts': f.lastModifiedSync().millisecondsSinceEpoch},
    ]..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  }

  /// Keeps any downloaded refs the renter already has.
  List<dynamic> _mergeRefs(Rec r, List incoming) {
    final old = {for (final f in (r['files'] as List).whereType<Map>()) f['name']: f};
    return [
      for (final f in incoming.whereType<Map>())
        {...f, if (old[f['name']]?['ref'] != null && old[f['name']]?['size'] == f['size']) 'ref': old[f['name']]!['ref']},
    ];
  }

  void _addRun(Rec r, Map<String, dynamic> run) {
    final runs = (r['runs'] as List? ?? []).cast<dynamic>().toList()..add(run);
    if (runs.length > maxRunsKept) runs.removeRange(0, runs.length - maxRunsKept);
    r['runs'] = runs;
  }

  void _finishRun(Rec r, String rid, Map<String, dynamic> out) {
    for (final run in (r['runs'] as List).whereType<Map>()) {
      if (run['rid'] != rid) continue;
      run['state'] = out['ok'] == true ? 'done' : 'failed';
      run['logs'] = out['logs'];
      run['result'] = out['result'];
      run['error'] = out['error'];
      run['ms'] = out['ms'];
      run['steps'] = out['steps'];
    }
  }

  static const demoFiles = {
    'hello.txt': 'Hello from a rented sandbox!\nEvery line here lives on the host device.\nScripts can read and write files in this folder.\n',
    'scores.csv': 'name,score\nAbebe,82\nSara,95\nYonas,71\nMeron,88\nDawit,64\n',
    'notes.json': '{"project":"Mentos","tags":["p2p","sandbox","demo"],"stars":42}',
  };

  /// Ready-made scripts for the console.
  static const sampleScripts = <String, String>{
    'Read a file': r'''// Files live in this sandbox. List them, then read one.
const files = box.files();
log("files:", files.map(f => f.name).join(", "));
const text = box.read("hello.txt");
return { lines: text.split("\n").filter(l => l.length > 0).length, first: text.split("\n")[0] };''',
    'Crunch a CSV': r'''// Average and best score from scores.csv, saved as a report.
const rows = box.read("scores.csv").trim().split("\n").slice(1).map(l => l.split(","));
const scores = rows.map(r => ({ name: r[0], score: Number(r[1]) }));
const avg = scores.reduce((a, s) => a + s.score, 0) / scores.length;
const best = scores.reduce((a, s) => s.score > a.score ? s : a, scores[0]);
box.write("report.txt", `Average ${avg.toFixed(1)}\nBest ${best.name} (${best.score})\n`);
return { average: avg, best: best.name, people: scores.length };''',
    'Primes': r'''// Pure compute: count primes below a limit (pass {"limit": 20000} as input).
const limit = box.args.limit || 10000;
let count = 0;
for (let n = 2; n < limit; n++) {
  let prime = true;
  for (let d = 2; d * d <= n; d++) { if (n % d === 0) { prime = false; break; } }
  if (prime) count++;
}
return { limit: limit, primes: count };''',
    'Edit JSON': r'''// Load, change and save a JSON file.
const doc = box.json("notes.json");
doc.stars = doc.stars + 1;
doc.tags.push("edited");
box.write("notes.json", JSON.stringify(doc, null, 2));
return doc;''',
  };
}

// ---- isolate work ---------------------------------------------------------

Future<Map<String, dynamic>> _boxRunAsync(String dir, String code, Map<String, dynamic> args, int quota, int steps) =>
    Isolate.run(() => _boxRun(dir, code, args, quota, steps)).timeout(
      const Duration(seconds: 60),
      onTimeout: () => {'ok': false, 'error': 'Ran longer than 60 seconds', 'logs': const <String>[], 'ms': 60000, 'steps': steps},
    );

/// Runs one script against a box folder. Everything it can touch is here.
Map<String, dynamic> _boxRun(String dir, String code, Map<String, dynamic> args, int quota, int steps) {
  final logs = <String>[];
  final watch = Stopwatch()..start();
  final folder = Directory(dir)..createSync(recursive: true);
  String path(Object? name) {
    final n = '$name'.split(RegExp(r'[\\/]')).last.trim();
    if (!RegExp(r'^[\w.\- ]{1,80}$').hasMatch(n) || n.startsWith('.')) throw ScriptError('bad file name "$name"');
    return '${folder.path}${Platform.pathSeparator}$n';
  }

  int used() => folder.listSync().whereType<File>().fold<int>(0, (s, f) => s + f.lengthSync());
  void write(Object? name, Object? data, {bool append = false}) {
    final p = path(name);
    final text = data is String ? data : Interp.show(data);
    final f = File(p);
    final before = f.existsSync() ? f.lengthSync() : 0;
    final after = append ? before + utf8.encode(text).length : utf8.encode(text).length;
    if (used() - before + after > quota) throw ScriptError('the sandbox is full (${quota ~/ (1024 * 1024)} MB)');
    if (folder.listSync().whereType<File>().length >= 500 && !f.existsSync()) throw ScriptError('at most 500 files');
    f.writeAsStringSync(text, mode: append ? FileMode.append : FileMode.write);
  }

  final interp = Interp(stepBudget: steps, onLog: (l) {
    if (logs.length < 500) logs.add(l.length > 2000 ? '${l.substring(0, 2000)}…' : l);
  });
  Object? arg(List<Object?> a, int i) => i < a.length ? a[i] : null;
  interp.define('box', frozen({
    'args': Interp.fromJson(args),
    'files': Native('box.files', (a) => [
      for (final f in folder.listSync().whereType<File>()) {'name': f.uri.pathSegments.last, 'size': f.lengthSync()},
    ]),
    'exists': Native('box.exists', (a) => File(path(arg(a, 0))).existsSync()),
    'read': Native('box.read', (a) {
      final f = File(path(arg(a, 0)));
      if (!f.existsSync()) throw ScriptError('no file "${arg(a, 0)}"');
      if (f.lengthSync() > 8 * 1024 * 1024) throw ScriptError('files over 8 MB cannot be read as text');
      return f.readAsStringSync();
    }),
    'json': Native('box.json', (a) {
      final f = File(path(arg(a, 0)));
      if (!f.existsSync()) throw ScriptError('no file "${arg(a, 0)}"');
      return Interp.fromJson(jsonDecode(f.readAsStringSync()));
    }),
    'write': Native('box.write', (a) {
      write(arg(a, 0), arg(a, 1) ?? '');
      return null;
    }),
    'append': Native('box.append', (a) {
      write(arg(a, 0), arg(a, 1) ?? '', append: true);
      return null;
    }),
    'remove': Native('box.remove', (a) {
      final f = File(path(arg(a, 0)));
      if (f.existsSync()) f.deleteSync();
      return null;
    }),
    'size': Native('box.size', (a) => File(path(arg(a, 0))).existsSync() ? File(path(arg(a, 0))).lengthSync() : 0),
  }));
  interp.define('log', Native('log', (a) {
    if (logs.length < 500) logs.add(a.map(Interp.show).join(' '));
    return null;
  }));
  try {
    // A top-level `return` gives the run its result.
    final result = interp.eval('(function () {\n$code\n})()');
    return {'ok': true, 'result': Interp.toJson(result), 'logs': logs, 'ms': watch.elapsedMilliseconds, 'steps': interp.stepsUsed};
  } on ScriptError catch (e) {
    return {'ok': false, 'error': e.toString(), 'logs': logs, 'ms': watch.elapsedMilliseconds, 'steps': interp.stepsUsed};
  } catch (e) {
    return {'ok': false, 'error': '$e', 'logs': logs, 'ms': watch.elapsedMilliseconds, 'steps': interp.stepsUsed};
  }
}
