part of 'market.dart';

/// Tasks: someone posts work with a reward, people apply, the owner picks
/// one and the reward goes into escrow for them. The worker submits
/// evidence against the task's criteria; the owner approves (the hold pays
/// out), asks for changes, or disputes. A worker whose submission is never
/// reviewed can claim the hold after the review window.
extension Tasks on Market {
  String _taskRec(String listingId) => 'task:$listingId';

  Rec? taskRecord(String listingId) => record(_taskRec(listingId));

  List<Rec> taskRecords({String? role}) => [
    for (final r in records('task'))
      if (role == null || r['role'] == role) r,
  ];

  /// Where a task stands for this phone.
  String taskStage(Rec r) {
    final lock = r['lock'] as String?;
    final e = lock == null ? null : engine.coin?.escrow(lock);
    if (r['role'] == 'worker' && lock == null) {
      return r['rejectedApp'] == true ? 'not chosen' : 'applied';
    }
    if (lock == null) return 'open';
    if (e == null) return 'paying';
    switch (e.state) {
      case HoldState.cancelled:
        return r['role'] == 'owner' ? 'open' : 'offer withdrawn';
      case HoldState.settled:
        if (e.released == 0) return r['role'] == 'owner' ? 'open' : 'withdrawn';
        return 'completed';
      case HoldState.disputed:
        return 'disputed';
      case HoldState.open:
        return 'offered';
      case HoldState.accepted:
        final subs = (r['submissions'] as List? ?? const []);
        final lastSub = subs.isEmpty ? 0 : ((subs.last as Map)['ts'] as int? ?? 0);
        final feedbackTs = r['feedbackTs'] as int? ?? 0;
        if (subs.isNotEmpty && lastSub > feedbackTs) return 'in review';
        if (feedbackTs > 0) return 'changes requested';
        return 'in progress';
    }
  }

  Future<void> apply(Listing task, String pitch) => _serial(() async {
    if (task.kind != Kinds.task || !task.active) throw StateError('This task is closed');
    if (task.author == me) throw StateError('This is your task');
    if (pitch.trim().isEmpty) throw ArgumentError('Say why you are a good fit');
    final r = taskRecord(task.id) ??
        <String, dynamic>{
          'id': _taskRec(task.id),
          'kind': 'task',
          'role': 'worker',
          'listing': task.id,
          'owner': task.author,
          'title': task.title,
          'reward': task.price,
          'created': nowMs(),
        };
    r['pitch'] = pitch.trim();
    final eid = '${me.substring(0, 6)}-apply-${toHex(randomBytes(4))}';
    _event(r, me, 'applied', text: pitch.trim(), eid: eid);
    _save(r);
    await _send(task.author, 'apply', {'task': task.id, 'pitch': pitch.trim(), 'eid': eid}, queue: 'mk-apply:$eid');
  });

  Future<void> _onTaskMessage(String from, Map<String, dynamic> m) async {
    final taskId = m['task'];
    if (taskId is! String || taskId.length > 80) return;
    final eid = m['eid'] is String ? m['eid'] as String : null;
    final text = m['text'] is String ? m['text'] as String : '';
    if (text.length > 4000) return;
    switch (m['op']) {
      case 'apply':
        final l = listing(taskId);
        if (l == null || l.author != me || l.kind != Kinds.task) return;
        final r = taskRecord(taskId) ?? _ownerRecord(l);
        final apps = (r['applications'] as List? ?? []).cast<dynamic>().toList();
        apps.removeWhere((a) => a is Map && a['by'] == from);
        final pitch = m['pitch'] is String ? (m['pitch'] as String) : '';
        if (pitch.length > 2000) return;
        apps.add({'by': from, 'pitch': pitch, 'ts': nowMs()});
        if (apps.length > 200) return;
        r['applications'] = apps;
        _event(r, from, 'applied', text: pitch, eid: eid);
        _save(r);
        _notify(from, taskId, 'apply', 'applied to “${l.title}”', '/market/r/task/$taskId');
        if (l.active) {
          await _publish(l.kind, {...l.body, 'applicants': apps.length}, id: l.id);
        }
      case 'assign':
        final lock = m['lock'];
        if (!isId(lock)) return;
        final l = listing(taskId);
        final r = taskRecord(taskId) ??
            <String, dynamic>{
              'id': _taskRec(taskId),
              'kind': 'task',
              'role': 'worker',
              'listing': taskId,
              'owner': from,
              'title': l?.title ?? 'Task',
              'reward': l?.price ?? 0,
              'created': nowMs(),
            };
        if (r['role'] != 'worker' || r['owner'] != from) return;
        final e = await _escrowFrom(m['bundle'], lock as String);
        if (e != null && (e.payer != from || e.payee != me || !e.memo.startsWith('task:'))) return;
        r['lock'] = lock;
        r['arbiter'] = m['arbiter'] is String ? m['arbiter'] : null;
        r['criteria'] = l?.body['criteria'] ?? m['criteria'];
        r['evidence'] = l?.body['evidence'] ?? m['evidence'];
        r.remove('rejectedApp');
        _event(r, from, 'offered', text: 'Offered ${Coin.format(e?.amount ?? 0)} in escrow', eid: eid);
        _save(r);
        _notify(from, taskId, 'assign', 'picked you for “${r['title']}”', '/market/r/task/$taskId');
      case 'task-up':
        await _taskUpdate(from, taskId, m, text, eid);
    }
  }

  Rec _ownerRecord(Listing l) => {
    'id': _taskRec(l.id),
    'kind': 'task',
    'role': 'owner',
    'listing': l.id,
    'owner': me,
    'title': l.title,
    'reward': l.price,
    'applications': <dynamic>[],
    'created': nowMs(),
  };

  Future<void> _taskUpdate(String from, String taskId, Map<String, dynamic> m, String text, String? eid) async {
    final what = m['what'];
    if (what is! String) return;
    var r = taskRecord(taskId);
    if (what == 'case' && r == null) {
      final snap = m['snapshot'];
      if (snap is! Map || snap['arbiter'] != me || !isId(snap['lock'])) return;
      if (from != snap['owner'] && from != snap['worker']) return;
      r = {
        'id': _taskRec(taskId),
        'kind': 'task',
        'role': 'arbiter',
        'listing': taskId,
        'owner': snap['owner'],
        'worker': snap['worker'],
        'title': snap['title'] is String ? snap['title'] : 'Task',
        'reward': snap['reward'] is int ? snap['reward'] : 0,
        'lock': snap['lock'],
        'arbiter': me,
        'criteria': snap['criteria'],
        'submissions': snap['submissions'] is List ? snap['submissions'] : const [],
        'created': nowMs(),
      };
    }
    if (r == null) return;
    final owner = r['owner'] as String;
    final worker = r['role'] == 'worker' ? me : r['worker'] as String?;
    final arbiter = r['arbiter'] as String?;
    if (from != owner && from != worker && from != arbiter) return;
    final bundle = m['bundle'];
    if (bundle is List) await coin.absorb(bundle);
    final fromWorker = from == worker;
    switch (what) {
      case 'submitted' when fromWorker:
        final subs = (r['submissions'] as List? ?? []).cast<dynamic>().toList();
        subs.add({
          'ts': nowMs(),
          'text': text,
          'media': [for (final f in refsFrom(m['media']).take(12)) f.toJson()],
          'links': [
            for (final x in (m['links'] is List ? m['links'] as List : const []).take(6))
              if (x is String && x.length <= 300) x,
          ],
        });
        if (subs.length > 20) subs.removeAt(0);
        r['submissions'] = subs;
      case 'changes' when from == owner:
        r['feedback'] = text;
        r['feedbackTs'] = nowMs();
      case 'accepted' || 'declined' || 'withdrawn' || 'claimed' when fromWorker:
        if (r['role'] == 'owner' && (what == 'declined' || what == 'withdrawn')) {
          await _reopen(r);
        }
      case 'approved' || 'rejected' || 'cancelled' || 'passed' when from == owner:
        if (what == 'passed' && r['role'] == 'worker') r['rejectedApp'] = true;
      case 'ruling' when from == arbiter:
        break;
      case 'note' || 'case':
        break;
      default:
        return;
    }
    if (!_event(r, from, what, text: text, eid: eid)) return;
    _save(r);
    final label = switch (what) {
      'submitted' => 'submitted work for “${r['title']}”',
      'changes' => 'asked for changes on “${r['title']}”',
      'accepted' => 'accepted “${r['title']}”',
      'declined' => 'declined “${r['title']}”',
      'withdrawn' => 'withdrew from “${r['title']}”',
      'approved' => 'approved your work and released payment',
      'rejected' => 'disputed your work',
      'cancelled' => 'withdrew the offer',
      'passed' => 'chose someone else',
      'claimed' => 'claimed the reward',
      'ruling' => 'settled the dispute',
      'case' => 'asked you to settle a task dispute',
      _ => 'sent a note',
    };
    _notify(from, taskId, what, label, '/market/r/task/$taskId');
  }

  Future<void> _reopen(Rec r) async {
    r.remove('assignee');
    final l = listing(r['listing'] as String);
    if (l != null && l.author == me && !l.deleted) {
      final body = {...l.body, 'status': 'open'}..remove('assignee');
      await _publish(l.kind, body, id: l.id);
    }
  }

  Future<void> _taskUp(Rec r, String to, String what, {String text = '', Map<String, dynamic> extra = const {}, String? stepHash}) async {
    final eid = '${me.substring(0, 6)}-$what-${toHex(randomBytes(4))}';
    _event(r, me, what, text: text, eid: eid);
    _save(r);
    await _send(to, 'task-up', {
      'task': r['listing'],
      'what': what,
      'eid': eid,
      if (text.isNotEmpty) 'text': text,
      if (stepHash != null) 'bundle': coin.bundle(stepHash, depth: 3),
      ...extra,
    }, queue: 'mk-tu:$eid');
  }

  Rec _mustTask(String listingId, String role, {bool held = true}) {
    final r = taskRecord(listingId);
    if (r == null || r['role'] != role) throw StateError('Only the task $role can do that');
    if (held && r['lock'] is! String) throw StateError('Nobody holds this task yet');
    return r;
  }

  /// Picks [worker] and puts the reward in escrow for them.
  Future<void> assign(String listingId, String worker, {String? arbiter}) => _serial(() async {
    final l = listing(listingId);
    if (l == null || l.author != me || l.kind != Kinds.task) throw StateError('Task not found');
    final r = taskRecord(listingId) ?? _ownerRecord(l);
    final prev = r['lock'] as String?;
    if (prev != null) {
      final e = coin.escrow(prev);
      if (e != null && e.remaining > 0) throw StateError('Someone already holds this task');
    }
    final apps = (r['applications'] as List? ?? const []).whereType<Map>();
    if (!apps.any((a) => a['by'] == worker)) throw StateError('They have not applied');
    final allowed = (l.body['arbiters'] as List?)?.whereType<String>() ?? const <String>[];
    if (arbiter != null && !allowed.contains(arbiter)) throw StateError('Pick an arbiter listed on the task');
    final deadline = l.body['deadline'] as int;
    final review = l.body['reviewDays'] as int;
    final until = DateTime.fromMillisecondsSinceEpoch(math.max(deadline, nowMs() + 3600000))
        .add(Duration(days: review));
    final memo = 'task:${toHex(sha256(utf8.encode('${l.id}|$worker|${nowMs()}'))).substring(0, 24)}';
    final lock = await coin.lock(
      worker,
      l.price,
      memo: memo,
      until: until,
      ackBy: DateTime.now().add(const Duration(days: 2)),
      arbiter: arbiter,
    );
    r['lock'] = lock.hash;
    r['worker'] = worker;
    r['arbiter'] = arbiter;
    r['submissions'] = <dynamic>[];
    r.remove('feedback');
    r.remove('feedbackTs');
    final eid = '${me.substring(0, 6)}-assign-${toHex(randomBytes(4))}';
    _event(r, me, 'offered', text: 'Offered to ${engine.nameOf(worker)}', eid: eid);
    _save(r);
    await _send(worker, 'assign', {
      'task': l.id,
      'lock': lock.hash,
      'eid': eid,
      'arbiter': ?arbiter,
      'criteria': l.body['criteria'],
      'evidence': l.body['evidence'],
      'bundle': coin.bundle(lock.hash, depth: 6),
    }, queue: 'mk-assign:$eid');
    for (final a in apps) {
      final by = a['by'];
      if (by is String && by != worker) {
        await _send(by, 'task-up', {'task': l.id, 'what': 'passed', 'eid': '$eid-$by'}, queue: 'mk-tu:$eid-$by');
      }
    }
    await _publish(l.kind, {...l.body, 'status': 'assigned', 'assignee': worker}, id: l.id);
  });

  Future<void> cancelOffer(String listingId) => _serial(() async {
    final r = _mustTask(listingId, 'owner');
    final tx = await coin.step(r['lock'] as String, 'cancel');
    await _taskUp(r, r['worker'] as String, 'cancelled', stepHash: tx.hash);
    r.remove('lock');
    r.remove('worker');
    _save(r);
    await _reopen(r);
  });

  Future<void> acceptOffer(String listingId) => _serial(() async {
    final r = _mustTask(listingId, 'worker');
    final tx = await coin.step(r['lock'] as String, 'ack');
    await _taskUp(r, r['owner'] as String, 'accepted', stepHash: tx.hash);
  });

  /// Hands the reward back. Before starting this is declining; after, withdrawing.
  Future<void> leaveTask(String listingId, String reason) => _serial(() async {
    final r = _mustTask(listingId, 'worker');
    final e = coin.escrow(r['lock'] as String);
    final what = e?.acked == true ? 'withdrawn' : 'declined';
    final tx = await coin.step(r['lock'] as String, 'refund');
    await _taskUp(r, r['owner'] as String, what, text: reason, stepHash: tx.hash);
  });

  Future<void> submitWork(String listingId, String text, {List<MediaRef> media = const [], List<String> links = const []}) =>
      _serial(() async {
        final r = _mustTask(listingId, 'worker');
        if (text.trim().isEmpty && media.isEmpty) throw ArgumentError('Describe the work you did');
        final subs = (r['submissions'] as List? ?? []).cast<dynamic>().toList()
          ..add({'ts': nowMs(), 'text': text.trim(), 'media': [for (final f in media) f.toJson()], 'links': links});
        r['submissions'] = subs;
        await _taskUp(r, r['owner'] as String, 'submitted', text: text.trim(), extra: {
          'media': [for (final f in media) f.toJson()],
          'links': links,
        });
      });

  Future<void> claimTask(String listingId) => _serial(() async {
    final r = _mustTask(listingId, 'worker');
    final tx = await coin.step(r['lock'] as String, 'claim');
    await _taskUp(r, r['owner'] as String, 'claimed', stepHash: tx.hash);
  });

  Future<void> approveWork(String listingId, {String text = ''}) => _serial(() async {
    final r = _mustTask(listingId, 'owner');
    final tx = await coin.step(r['lock'] as String, 'release');
    await _taskUp(r, r['worker'] as String, 'approved', text: text, stepHash: tx.hash);
    final l = listing(listingId);
    if (l != null && l.author == me && !l.deleted) {
      await _publish(l.kind, {...l.body, 'status': 'completed'}, id: l.id);
    }
  });

  Future<void> requestChanges(String listingId, String text) => _serial(() async {
    final r = _mustTask(listingId, 'owner');
    if (text.trim().isEmpty) throw ArgumentError('Say what needs to change');
    r['feedback'] = text.trim();
    r['feedbackTs'] = nowMs();
    await _taskUp(r, r['worker'] as String, 'changes', text: text.trim());
  });

  Future<void> rejectWork(String listingId, String reason) => _serial(() async {
    final r = _mustTask(listingId, 'owner');
    if (reason.trim().isEmpty) throw ArgumentError('Say why the work falls short');
    final tx = await coin.step(r['lock'] as String, 'dispute');
    await _taskUp(r, r['worker'] as String, 'rejected', text: reason.trim(), stepHash: tx.hash);
    final arbiter = r['arbiter'] as String?;
    if (arbiter != null) {
      await _taskUp(r, arbiter, 'case', text: reason.trim(), extra: {
        'snapshot': {
          'owner': me,
          'worker': r['worker'],
          'arbiter': arbiter,
          'title': r['title'],
          'reward': r['reward'],
          'lock': r['lock'],
          'criteria': listing(listingId)?.body['criteria'],
          'submissions': r['submissions'],
        },
        'bundle': coin.bundle(r['lock'] as String, depth: 6),
      });
    }
  });

  Future<void> ruleTask(String listingId, int toWorker, String text) => _serial(() async {
    final r = _mustTask(listingId, 'arbiter');
    final lock = r['lock'] as String;
    final e = coin.escrow(lock);
    if (e == null || !e.disputed) throw StateError('This hold is not disputed');
    if (toWorker < 0 || toWorker > e.remaining) throw ArgumentError('Amount out of range');
    final back = e.remaining - toWorker;
    String? last;
    if (back > 0) last = (await coin.step(lock, 'refund', amount: back)).hash;
    if (toWorker > 0) last = (await coin.step(lock, 'release', amount: toWorker)).hash;
    for (final p in [r['owner'] as String, r['worker'] as String]) {
      await _taskUp(r, p, 'ruling', text: text.isEmpty ? '${Coin.format(toWorker)} to the worker' : text, stepHash: last);
    }
  });

  Future<void> noteTask(String listingId, String text) => _serial(() async {
    final r = taskRecord(listingId);
    if (r == null || text.trim().isEmpty) return;
    final to = r['role'] == 'owner' ? r['worker'] as String? : r['owner'] as String?;
    if (to == null) return;
    await _taskUp(r, to, 'note', text: text.trim());
  });
}
