import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../core/crypto/crypto.dart';
import '../data/db.dart';
import '../data/media_store.dart';
import '../data/models.dart';
import '../state/settings.dart';
import 'transport.dart';
import 'views.dart';

/// Change keys emitted on [Engine.changes] besides plain scopes.
abstract final class Ch {
  static const peers = '#peers';
  static const presence = '#presence';
  static const spaces = '#spaces';
  static const activity = '#activity';
  static const grants = '#grants';
  static const files = '#files';
  static const xfers = '#xfers';
  static const groups = '#groups';
  static const net = '#net';
  static const feed = '#feed';
  static const chats = '#chats';
  static const stories = '#stories';
  static const bookmarks = '#bookmarks';
  static const alerts = '#alerts';
  static const jobs = '#jobs';
  static const channels = '#channels';
  static String typing(String scope) => '#typing:$scope';
  static String receipts(String scope) => '#rcpt:$scope';
}

class _Mem {
  _Mem(this.item, this.sources);
  final Item item;
  final Set<String> sources;
}

/// The peer-to-peer core.
///
/// Storage tiers:
///  * owned  – created here, stored in the encrypted DB, served to peers
///  * kept   – someone else's item that they consented to and this device
///             accepted; stored and served on their behalf
///  * live   – everything else from others; held in memory only while a
///             source (the author or a custodian) is reachable
class Engine {
  Engine({
    required this.me,
    required this.db,
    required this.net,
    required this.media,
    required Settings settings,
  })
    // ignore: prefer_initializing_formals
    : _settings = settings;

  final Identity me;
  final Db db;
  final Transport net;
  final MediaStore media;
  Settings _settings;

  final _mem = <String, _Mem>{};
  final _tombstones = <String>{};
  final _liveProfiles = <String, Profile>{};
  final _links = <String>{};
  final _lastHeard = <String, int>{};
  final _helloAt = <String, int>{};
  final _typing = <String, Map<String, int>>{};
  final _neighbors = <String, Set<String>>{};
  final _spaceTopics = <String, String>{};
  final _feedTopics = <String, String>{};
  final _groupTopics = <String, String>{};
  final _pendingQueries = <String, Completer<void>>{};
  final _xfers = <String, FileTransfer>{};
  final _alerts = <String, Alert>{};
  final _jobs = <String, Job>{};
  final _invites = <String, Map<String, dynamic>>{};
  /// Group id -> invited node -> when. Kept on disk so an acceptance that
  /// arrives after a restart still admits the person.
  final _outgoingInvites = <String, Map<String, int>>{};
  static const _inviteTtl = Duration(days: 14);
  final _peerBps = <String, int>{};

  final _changes = StreamController<Set<String>>.broadcast();
  final _notes = StreamController<OsNote>.broadcast();

  /// Everything that may deserve an operating-system notification. The
  /// listener decides, using the person's notification settings.
  Stream<OsNote> get notes => _notes.stream;

  final _callSignals = StreamController<({String from, Map<String, dynamic> m})>.broadcast();
  final _media = StreamController<MediaEvent>.broadcast();

  /// Call signalling received over the authenticated direct channel.
  Stream<({String from, Map<String, dynamic> m})> get callSignals => _callSignals.stream;

  /// Media connections opening and closing.
  Stream<MediaEvent> get mediaEvents => _media.stream;

  /// Sends a call control message now; calls are real time, so nothing is
  /// queued for later.
  Future<bool> sendCallSignal(String peer, Map<String, dynamic> body) => _send(peer, {...body, 't': 'call'});

  /// Records something for the person's activity feed and notifications.
  void noteActivity(Activity a, {String? title, String? body, String? route, String category = 'other'}) {
    db.addActivity(a);
    _emit({Ch.activity});
    if (title != null) {
      _notify(id: a.id, title: title, body: body ?? '', route: route, category: category, at: a.ts);
    }
  }
  final _pending = <String>{};
  Timer? _flush;
  final _subs = <StreamSubscription>[];
  final _timers = <Timer>[];
  bool _running = false;
  String _status = 'starting';
  String? _dataDir;
  bool _held = false;
  bool _connecting = false;
  Future<void>? _stopping;
  bool _meshJoined = false;
  bool _bringing = false;
  bool _sawStatus = false;
  int _runningPolls = 0;
  DateTime? _bindStarted;
  Future<void>? _deliveryPump;
  bool _flushingOutbox = false;
  bool _outboxAgain = false;
  bool _deliveryAgain = false;
  Completer<void>? _outboxIdle;
  final _eventTasks = <Future<void>>{};
  final _eventWaiters = <Completer<void>>[];
  int _eventSlots = 0;
  static const _eventCap = 4;
  final _accepting = <String, Future<bool>>{};
  /// A replacement group key that arrived before the owner's departure.
  final _pendingGroupKey = <String, ({String from, String key})>{};

  Stream<Set<String>> get changes => _changes.stream;
  Settings get settings => _settings;
  String get status => _status;
  bool get running => _running;

  /// True while a connect attempt is in progress.
  bool get connecting => _connecting;

  /// True after the user asked the node to stay down.
  bool get held => _held;

  void noteStartError(String message) {
    _status = 'offline';
    _running = true;
  }

  static const _purgeGrace = Duration(seconds: 20);

  // ---------------------------------------------------------------------------
  // lifecycle

  Future<void> start(String dataDir) async {
    _dataDir = dataDir;
    db.deleteExpired(nowMs());
    for (final item in db.legacyQueuedMessages()) {
      db.queueMessage(item.e, _messageRecipients(item.e.scope));
    }
    db.recoverDeliveries();
    await _loadTombstones();
    _loadInvites();
    _loadOutgoingInvites();
    _bindStarted = DateTime.now();
    _applyNetOptions();
    try {
      await net.start(
        secret: me.seed,
        dataDir: dataDir,
        blobDir: media.blobs.path,
      );
      _status = 'online';
    } catch (e) {
      _bindStarted = null;
      _status = 'offline';
    }
    media.quotaBytes = _settings.quotaMb.clamp(256, 32768) * 1024 * 1024;
    _running = true;
    _subs.add(
      net.events.listen((ev) {
        late Future<void> task;
        task = Future(() async {
          while (_eventSlots >= _eventCap) {
            if (!_running) return;
            final gate = Completer<void>();
            _eventWaiters.add(gate);
            await gate.future;
          }
          if (!_running) return;
          _eventSlots++;
          try {
            await _onEvent(ev);
          } catch (_) {
          } finally {
            _eventSlots--;
            if (_eventWaiters.isNotEmpty) {
              _eventWaiters.removeAt(0).complete();
            }
          }
        }).whenComplete(() => _eventTasks.remove(task));
        _eventTasks.add(task);
      }),
    );

    try {
      await _ensureProfile();
    } catch (_) {}
    unawaited(_bringUpWhenReady());
    _timers.add(
      Timer.periodic(const Duration(seconds: 15), (_) {
        unawaited(_tick());
        unawaited(_flushOutbox());
        unawaited(flushDeliveries());
      }),
    );
    _timers.add(
      Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(_syncLinks());
      }),
    );
    _timers.add(
      Timer.periodic(const Duration(seconds: 45), (_) => _dialContacts()),
    );
    _timers.add(
      Timer.periodic(const Duration(seconds: 60), (_) => _announceHere()),
    );
    _emit({Ch.net});
  }

  bool get _bindInFlight =>
      _bindStarted != null &&
      DateTime.now().difference(_bindStarted!) < const Duration(seconds: 20);

  /// Joins topics and dials contacts only after the endpoint is actually bound.
  /// Calls made before that used to fail and were never retried.
  Future<void> _bringUpWhenReady() async {
    for (var i = 0; i < 40; i++) {
      if (_held || _meshJoined) return;
      if (await _bringUp()) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<bool> _bringUp({bool forceDial = false}) async {
    if (_held || _bringing) return _meshJoined;
    _bringing = true;
    try {
      final st = await netStatus();
      if (!st.running || _held) {
        _runningPolls = 0;
        return false;
      }
      _runningPolls++;
      final ready = _sawStatus || _runningPolls >= 6;
      if (!ready) return false;
      if (_meshJoined) {
        if (forceDial) {
          await _restoreAddrs();
          await _dialContacts();
          _emit({Ch.net});
        }
        return true;
      }
      _meshJoined = true;
      await _restoreAddrs();
      await _joinMesh();
      await _dialContacts();
      unawaited(flushDeliveries());
      _emit({Ch.net});
      return true;
    } finally {
      _bringing = false;
    }
  }

  Future<void> _restoreAddrs() async {
    for (final p in db.peers()) {
      final a = p.addr;
      if (a == null || a.isEmpty) continue;
      final ticket = a.startsWith('{') || a.contains('|') ? a : '${p.id}|$a';
      try {
        await net.addTicket(ticket);
      } catch (_) {}
    }
  }

  Future<void> _loadTombstones() async {
    for (final i in db.itemsByKind(K.del, limit: 100000)) {
      if (!await i.e.verify() || !i.e.sane) {
        db.deleteItem(i.id);
        continue;
      }
      final t = i.e.target;
      if (t == null) continue;
      final target = db.item(t);
      if (target == null) continue;
      if (target.author == i.author || _canModerate(i.author, target)) {
        _tombstones.add(t);
      } else {
        db.deleteItem(i.id);
      }
    }
  }

  Future<void> _joinMesh() async {
    try {
      await _joinFeedTopic(me.id, const []);
      for (final p in db.peers().where((p) => p.iFollow && !p.blocked)) {
        await _joinFeedTopic(p.id, [p.id]);
      }
      for (final s in db.spaces()) {
        await _joinSpaceTopic(s);
      }
      for (final g in db.groups()) {
        await _joinGroupTopic(g);
      }
    } catch (_) {}
    _emit({Ch.net});
  }

  Future<void> stop() async {
    _running = false;
    _held = true;
    for (final gate in _eventWaiters) {
      if (!gate.isCompleted) gate.complete();
    }
    _eventWaiters.clear();
    for (final query in _pendingQueries.values) {
      if (!query.isCompleted) query.complete();
    }
    _pendingQueries.clear();
    for (final t in _timers) {
      t.cancel();
    }
    for (final s in _subs) {
      await s.cancel();
    }
    await net.stop();
    await _deliveryPump;
    await Future.wait(_eventTasks.toList());
    await _outboxIdle?.future;
    _flush?.cancel();
    _flush = null;
    _pending.clear();
  }

  /// Last refusal from the native node for the privacy options, if any.
  String? netOptionsError;

  void _applyNetOptions() {
    final Object tools = net;
    if (tools is! NetTools) return;
    netOptionsError = tools.setOptions(_settings.netOptions);
  }

  void updateSettings(Settings s) {
    final rebind = s.privacy != _settings.privacy || (s.privacy == 'tor' && s.proxyUrl != _settings.proxyUrl);
    final profileChanged =
        s.keepPosts != _settings.keepPosts ||
        s.keepProfile != _settings.keepProfile ||
        s.discoverable != _settings.discoverable;
    _settings = s;
    media.quotaBytes = s.quotaMb.clamp(256, 32768) * 1024 * 1024;
    db.setKv('settings', s.encode());
    if (profileChanged) {
      final p = myProfile;
      unawaited(updateProfile(name: p.name, bio: p.bio, avatar: p.avatar));
      if (!s.keepPosts) unawaited(_broadcastRevoke(Scope.feed(me.id)));
    }
    if (rebind && _running) unawaited(_rebind());
  }

  /// Privacy modes change which transports the endpoint binds, so the node
  /// restarts with the new options.
  Future<void> _rebind() async {
    final wasHeld = _held;
    await disconnectNode();
    if (!wasHeld) await connectNode();
  }

  void _emit(Iterable<String> keys) {
    _pending.addAll(keys);
    _flush ??= Timer(const Duration(milliseconds: 24), () {
      _flush = null;
      if (_pending.isEmpty || _changes.isClosed) return;
      final batch = Set.of(_pending);
      _pending.clear();
      _changes.add(batch);
    });
  }

  /// Re-evaluates [compute] whenever a change matching [filter] happens.
  Stream<T> watch<T>(
    bool Function(Set<String> keys) filter,
    T Function() compute,
  ) async* {
    try {
      yield compute();
    } catch (_) {
      return;
    }
    await for (final keys in changes) {
      if (!filter(keys) || _changes.isClosed) continue;
      try {
        yield compute();
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // presence

  bool isOnline(String peer) {
    if (peer == me.id) return _running && !_held;
    return _links.contains(peer);
  }

  Set<String> get onlinePeers =>
      {..._links, ..._lastHeard.keys.where(isOnline)}..remove(me.id);

  void _heard(String peer) {
    if (peer == me.id) return;
    final was = isOnline(peer);
    _lastHeard[peer] = nowMs();
    if (!was) {
      _emit({Ch.presence});
      db.updatePeer(peer, {'last_seen': nowMs()});
    }
  }

  Future<void> _tick() async {
    final now = nowMs();
    // purge live items whose every source went away
    final gone = <String>{};
    _mem.removeWhere((id, m) {
      final alive = m.sources.any(isOnline);
      final grace = now - m.item.ts < _purgeGrace.inMilliseconds;
      if (!alive && !grace) {
        gone.add(m.item.e.scope);
        return true;
      }
      return false;
    });
    _liveProfiles.removeWhere((id, _) => !isOnline(id));
    // disappearing messages and expired stories
    final expired = db.expiredIds(now);
    if (expired.isNotEmpty) {
      for (final id in expired) {
        final it = db.item(id);
        if (it != null) {
          gone.add(it.e.scope);
          for (final m in MediaRef.listFrom(it.body['media'])) {
            if (it.owned || !db.referencedHashes().contains(m.hash)) {
              await media.deleteBlob(m.hash);
            }
          }
        }
      }
      db.deleteExpired(now);
    }
    _mem.removeWhere((id, m) {
      final e = m.item.e.expires;
      if (e != null && e <= now) {
        gone.add(m.item.e.scope);
        return true;
      }
      return false;
    });
    // typing expiry
    for (final entry in _typing.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((_, exp) => exp < now);
      if (entry.value.length != before) gone.add(Ch.typing(entry.key));
    }
    if (gone.isNotEmpty) {
      _emit({...gone, Ch.feed, Ch.chats, Ch.stories, Ch.peers});
    }
    _emit({Ch.presence});
  }

  /// Drops peers whose QUIC connection is already gone, even if the close
  /// event has not been delivered yet.
  Future<void> _syncLinks() async {
    if (!_running) return;
    if (_held) {
      if (_links.isEmpty) return;
      _links.clear();
      _emit({Ch.presence, Ch.net});
      return;
    }
    final NetStatus st;
    try {
      st = await netStatus();
    } catch (_) {
      return;
    }
    if (_held) return;
    final live = st.links.map((l) => l.peer).toSet()..remove(me.id);
    if (live.length == _links.length && live.containsAll(_links)) return;
    _links
      ..clear()
      ..addAll(live);
    _emit({Ch.presence, Ch.net});
  }

  Future<void> _dialContacts() async {
    if (!_running || _held) return;
    final targets = <String>{};
    for (final p in db.peers()) {
      if (p.blocked) continue;
      if (p.iFollow || p.followsMe || p.preserve) targets.add(p.id);
    }
    for (final s in db.dmScopes()) {
      final peer = Scope.dmPeer(s, me.id);
      if (peer != null) targets.add(peer);
    }
    for (final g in db.grants()) {
      targets.add(g.peer);
    }
    for (final g in db.groups()) {
      targets.addAll(g.members);
      targets.add(g.owner);
    }
    targets.removeAll(_links);
    targets.remove(me.id);
    final batch = targets.take(24).toList();
    await Future.wait(
      batch.map((p) => net.connect(p).catchError((_) => false)),
    );
  }

  Future<void> _announceHere() async {
    if (_held) return;
    for (final s in db.spaces()) {
      await _spaceSend(s, {'t': 'here', 'a': me.id});
    }
    for (final g in db.groups()) {
      await _groupSend(g, {'t': 'here', 'a': me.id});
    }
  }

  // ---------------------------------------------------------------------------
  // network events

  Future<void> _onEvent(NetEvent ev) async {
    switch (ev) {
      case LinkEvent(:final peer, :final up):
        if (up) {
          _links.add(peer);
          _heard(peer);
          db.reviveDeliveries(peer);
          unawaited(flushDeliveries());
          await _hello(peer);
          db.reviveOutbox(peer);
          await _flushOutbox();
        } else {
          _links.remove(peer);
          _emit({Ch.presence, Ch.net});
        }
      case DirectEvent(:final from, :final data):
        _heard(from);
        final msg = _decode(data);
        if (msg != null) await _onDirect(from, msg);
      case GossipEvent(:final topic, :final from, :final data):
        await _onGossip(topic, from, data);
      case MediaEvent():
        _media.add(ev);
      case NeighborEvent(:final topic, :final peer, :final up):
        final set = _neighbors.putIfAbsent(topic, () => <String>{});
        up ? set.add(peer) : set.remove(peer);
        if (up) _heard(peer);
        _emit({Ch.net, Ch.presence});
      case StatusEvent():
        _sawStatus = true;
        unawaited(_bringUp(forceDial: true));
        _emit({Ch.net});
    }
  }

  Map<String, dynamic>? _decode(Uint8List data) {
    try {
      return (jsonDecode(utf8.decode(data)) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _sendOrQueue(
    String id,
    String peer,
    Map<String, dynamic> msg,
  ) async {
    db.enqueueOutbox(id, peer, jsonEncode(msg));
    final ok = await _send(peer, msg);
    if (ok) {
      db.deleteOutbox(id);
    } else {
      db.bumpOutbox(id, failed: false);
    }
    _emit({Ch.chats});
    return ok;
  }

  Future<void> _flushOutbox() async {
    if (!_running || _held) return;
    if (_flushingOutbox) {
      _outboxAgain = true;
      return;
    }
    _outboxAgain = false;
    _flushingOutbox = true;
    final idle = Completer<void>();
    _outboxIdle = idle;
    try {
      for (final row in db.dueOutbox(nowMs())) {
        if (!_running || _held) break;
        Map<String, dynamic>? msg;
        try {
          msg = (jsonDecode(row.payload) as Map).cast<String, dynamic>();
        } catch (_) {
          db.deleteOutbox(row.id);
          continue;
        }
        final envelope = Envelope.fromWire(msg['e']);
        if (msg['t'] == 'seen' && !_settings.readReceipts) {
          db.deleteOutbox(row.id);
          continue;
        }
        if (envelope != null &&
            (!db.hasItem(envelope.id) ||
                (envelope.expires != null && envelope.expires! <= nowMs()))) {
          db.deleteOutbox(row.id);
          continue;
        }
        final ok = await _deliverQueued(row.peer, msg);
        if (ok) {
          db.deleteOutbox(row.id);
        } else {
          db.bumpOutbox(row.id, failed: row.attempts + 1 >= 6);
        }
      }
      _emit({Ch.chats});
    } finally {
      _flushingOutbox = false;
      idle.complete();
      _outboxIdle = null;
      if (_outboxAgain) unawaited(_flushOutbox());
    }
  }

  Set<String> _messageRecipients(String scope) {
    final parts = Scope.parts(scope);
    final peers = <String>{};
    if (parts.first == 'dm') {
      final peer = Scope.dmPeer(scope, me.id);
      if (peer != null) peers.add(peer);
    } else if (parts.length > 1 && parts.first == 'gdm') {
      final group = db.group(parts[1]);
      if (group != null && group.has(me.id)) {
        peers.addAll({group.owner, ...group.members});
      }
    } else {
      final sid = Scope.spaceOf(scope);
      final space = sid == null ? null : db.space(sid);
      if (space != null && _canReadSpace(space, me.id)) {
        peers.addAll(_spaceAudience(space));
      }
    }
    peers.remove(me.id);
    return peers.where((p) => !(db.peer(p)?.blocked ?? false)).toSet();
  }

  /// Single flight across timer, reconnect, and manual retry. The recipient
  /// snapshot is durable; no gossip send is treated as delivery to a group.
  Future<void> flushDeliveries() {
    if (!_running || _held) return Future.value();
    if (_deliveryPump != null) {
      _deliveryAgain = true;
      return _deliveryPump!;
    }
    return _deliveryPump = (() async {
      do {
        _deliveryAgain = false;
        await _pumpDeliveries();
      } while (_deliveryAgain && _running && !_held);
    })().whenComplete(() => _deliveryPump = null);
  }

  Future<void> _pumpDeliveries() async {
    try {
      if (!(await net.status()).running || !_running || _held) return;
    } catch (_) {
      return; // Keep the durable queue intact until the transport recovers.
    }
    final due = db.dueDeliveries(nowMs());
    for (var i = 0; i < due.length; i += 4) {
      if (!_running || _held) break;
      await Future.wait(due.skip(i).take(4).map(_attemptDelivery));
    }
  }

  Future<void> _attemptDelivery(RecipientDelivery job) async {
    if (!_running || _held) return;
    final item = db.item(job.id);
    if (item == null ||
        (item.e.expires != null && item.e.expires! <= nowMs())) {
      return;
    }
    final scope = item.e.scope;
    if (!_messageRecipients(scope).contains(job.peer)) {
      db.failDelivery(
        job.id,
        job.peer,
        'Recipient is blocked or is no longer in this conversation.',
      );
      _emit({scope, Ch.chats});
      return;
    }
    if (!db.beginDelivery(job)) return;
    _emit({scope, Ch.chats});
    final sent = await _send(job.peer, {'t': 'item', 'e': item.e.toWire()});
    // Conditional update preserves receipts/cancellation arriving during I/O.
    db.finishDelivery(job, sent: sent);
    _emit({scope, Ch.chats});
  }

  void retryMessage(String id) {
    final item = db.item(id);
    if (item == null ||
        !item.owned ||
        (item.e.expires != null && item.e.expires! <= nowMs())) {
      return;
    }
    db.retryDeliveries(id);
    _emit({item.e.scope, Ch.chats});
    unawaited(flushDeliveries());
  }

  void cancelMessage(String id) {
    final item = db.item(id);
    if (item == null || !item.owned) return;
    db.cancelDeliveries(id);
    db.deleteOutbox(id);
    _emit({item.e.scope, Ch.chats});
  }

  bool _mayServeMessage(Item item, String peer) {
    if (!item.owned || item.e.kind != K.msg) return true;
    final jobs = db.deliveries(item.id);
    if (jobs.isEmpty) return true; // Messages created before delivery tracking.
    return jobs.any(
      (j) =>
          j.peer == peer &&
          j.state != Delivery.cancelled &&
          j.state != Delivery.saved,
    );
  }

  Future<bool> _deliverQueued(String route, Map<String, dynamic> msg) async {
    if (route.startsWith('gdm:')) {
      final g = db.group(route.substring(4));
      if (g == null) return true;
      return _groupSend(g, msg);
    }
    if (route.startsWith('space:')) {
      final s = db.space(route.substring(6));
      if (s == null) return true;
      return _spaceSend(s, msg);
    }
    if (route.startsWith('feed:')) {
      if (!_settings.discoverable) return _sendQuiet(msg);
      return _feedSend(msg, author: route.substring(5));
    }
    if (route.startsWith('quiet:')) return _sendQuiet(msg);
    return _send(route, msg);
  }

  /// Hidden posts go only to people this device follows. Success means at
  /// least one of them accepted the bytes.
  Future<bool> _sendQuiet(Map<String, dynamic> msg) async {
    final peers = db
        .peers()
        .where((p) => p.iFollow && !p.blocked)
        .map((p) => p.id)
        .toList();
    if (peers.isEmpty) return false;
    var any = false;
    for (final p in peers.take(32)) {
      if (await _send(p, msg)) any = true;
    }
    return any;
  }

  Future<void> _queueFanout(
    String id,
    String route,
    Map<String, dynamic> msg,
    Future<bool> Function() send,
  ) async {
    db.enqueueOutbox(id, route, jsonEncode(msg));
    var ok = false;
    try {
      ok = await send();
    } catch (_) {}
    if (ok) {
      db.deleteOutbox(id);
    } else {
      db.bumpOutbox(id, failed: false);
    }
    _emit({Ch.chats});
  }

  Future<bool> _send(String peer, Map<String, dynamic> msg) async {
    if (peer == me.id || !_running || _held) return false;
    try {
      return await net.send(
        peer,
        Uint8List.fromList(utf8.encode(jsonEncode(msg))),
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _hello(String peer, {bool reply = false}) async {
    final last = _helloAt[peer] ?? 0;
    if (nowMs() - last < 8000) return;
    _helloAt[peer] = nowMs();
    final profile = _myProfileEnvelope();
    await _send(peer, {
      't': 'hello',
      'v': 1,
      'profile': profile?.toWire(),
      'reply': reply,
    });
  }

  Future<void> _onDirect(String from, Map<String, dynamic> m) async {
    if (db.peer(from)?.blocked ?? false) return;
    switch (m['t']) {
      case 'hello':
        final e = Envelope.fromWire(m['profile']);
        if (e != null && e.author == from) await ingest(e, via: from);
        db.ensurePeer(from);
        if (m['reply'] != true) {
          _helloAt.remove(from);
          await _hello(from, reply: true);
        }
        await _pullFrom(from);
        await _resendOffers(from);
      case 'item':
        final e = Envelope.fromWire(m['e']);
        if (e != null) await _receiveItem(e, from);
      case 'items':
        final list = (m['es'] as List?) ?? const [];
        for (final w in list) {
          final e = Envelope.fromWire(w);
          if (e != null) await _receiveItem(e, from);
        }
        final qid = m['qid'] as String?;
        if (qid != null && m['more'] != true) {
          _pendingQueries.remove(qid)?.complete();
        }
      case 'q':
        await _answer(
          from,
          m['qid'] as String?,
          m['scope'] as String? ?? '',
          (m['since'] as num?)?.toInt() ?? 0,
        );
      case 'typing':
        _setTyping(m['scope'] as String? ?? '', from, m['on'] == true);
      case 'ack':
        final scope = m['scope'] as String? ?? '';
        if (m['id'] is String) {
          db.acknowledgeMessage(m['id'] as String, from, scope);
          _emit({scope, Ch.chats});
        }
        if (_dmWith(scope, from)) {
          db.setReceipt(
            scope,
            from,
            delivered: (m['ts'] as num?)?.toInt() ?? 0,
          );
          _emit({Ch.receipts(scope), scope, Ch.chats});
        }
      case 'seen':
        final scope = m['scope'] as String? ?? '';
        if (m['ids'] is List) {
          for (final id in (m['ids'] as List).take(120).whereType<String>()) {
            db.acknowledgeMessage(id, from, scope, read: true);
          }
          _emit({scope, Ch.chats});
        }
        if (_dmWith(scope, from)) {
          db.setReceipt(scope, from, read: (m['ts'] as num?)?.toInt() ?? 0);
          _emit({Ch.receipts(scope), scope, Ch.chats});
        }
      case 'sync':
        await _onSync(
          from,
          m['op'] as String? ?? '',
          m['scope'] as String? ?? '',
        );
      case 'follow':
        db.updatePeer(from, {'follows_me': m['on'] == true ? 1 : 0});
        if (m['on'] == true) {
          db.addActivity(
            Activity(
              id: 'follow:$from',
              kind: 'follow',
              actor: from,
              ts: nowMs(),
            ),
          );
          _notify(
            id: 'follow:$from',
            title: nameOf(from),
            body: 'Started following you',
            route: '/activity',
          );
          _emit({Ch.activity});
        }
        _emit({Ch.peers});
      case 'preserve':
        db.setGrant(
          Scope.feed(me.id),
          from,
          GrantDir.out,
          m['on'] == true ? GrantState.active : null,
        );
        _emit({Ch.grants});
      case 'revoke':
        final scope = m['scope'] as String? ?? '';
        await _onRevoke(from, scope);
      case 'xfer':
        await _onXfer(from, m);
      case 'group':
        final e = Envelope.fromWire(m['e']);
        if (e != null) await ingest(e, via: from);
      case 'ginvite':
        await _onGroupInvite(from, m);
      case 'call':
        if (!(db.peer(from)?.blocked ?? false)) _callSignals.add((from: from, m: m));
      case 'gkey':
        final gid = m['id'] as String? ?? '';
        final key = m['key'] as String? ?? '';
        final g = db.group(gid);
        if (g == null ||
            _sealKey(key) == null ||
            !g.has(me.id) ||
            from == me.id) {
          break;
        }
        final heir = _groupHeir(g);
        if (from == g.owner) {
          _applyGroupKey(g, key);
        } else if (from == heir) {
          if (g.members.contains(g.owner)) {
            _pendingGroupKey[gid] = (from: from, key: key);
          } else {
            _pendingGroupKey.remove(gid);
            _applyGroupKey(g, key, owner: from);
          }
        }
      case 'skey':
        final sid = m['id'] as String? ?? '';
        final key = m['key'] as String? ?? '';
        final s = db.space(sid);
        if (s != null &&
            from == s.owner &&
            _sealKey(key) != null &&
            from != me.id &&
            _canReadSpace(s, me.id)) {
          db.putSpace(s.copyWith(key: key));
          _emit({Ch.spaces});
        }
      case 'gaccept':
        final gid = m['id'] as String? ?? '';
        final g = db.group(gid);
        final pending = _outgoingInvites[gid];
        final invitedAt = pending?[from];
        final fresh = invitedAt != null && nowMs() - invitedAt < _inviteTtl.inMilliseconds;
        if (invitedAt != null) {
          pending!.remove(from);
          _saveOutgoingInvites();
        }
        if (g != null && g.owner == me.id && fresh) {
          await updateGroup(
            gid,
            (x) => x.copyWith(members: {...x.members, from}.toList()),
          );
          final current = db.group(gid);
          if (current != null && _sealKey(current.key) != null) {
            await _sendOrQueue('gkey:$gid:$from', from, {
              't': 'gkey',
              'id': gid,
              'key': current.key,
            });
          }
        }
    }
  }

  /// What to fetch from a peer the moment they're reachable.
  Future<void> _pullFrom(String peer) async {
    final dm = Scope.dm(me.id, peer);
    await query(peer, dm);
    final p = db.peer(peer);
    final known = p != null && (p.iFollow || p.preserve || p.followsMe);
    if (known || !_settings.hideStrangers) {
      await query(peer, Scope.feed(peer));
      await query(peer, Scope.story(peer));
      await query(peer, Scope.files(peer));
      await query(peer, Scope.profile(peer));
    }
    for (final g in db.groups().where((g) => g.has(peer))) {
      await query(peer, Scope.gdm(g.id));
      await query(peer, Scope.gmeta(g.id));
    }
  }

  Future<void> query(String peer, String scope, {int since = 0}) async {
    final qid = newId();
    final c = Completer<void>();
    _pendingQueries[qid] = c;
    final ok = await _send(peer, {
      't': 'q',
      'qid': qid,
      'scope': scope,
      'since': since,
    });
    if (!ok) {
      _pendingQueries.remove(qid);
      return;
    }
    await c.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => _pendingQueries.remove(qid),
    );
  }

  /// Items this device will hand to [requester] for [scope].
  List<Item> _serve(String scope, String requester) {
    if (db.peer(requester)?.blocked ?? false) return const [];
    final type = Scope.type(scope);
    final parts = Scope.parts(scope);
    switch (type) {
      case 'dm':
        if (!parts.contains(requester) || !parts.contains(me.id)) {
          return const [];
        }
        // mine, plus the requester's own items I keep for them
        return db
            .itemsInScope(scope)
            .where((i) => i.owned || i.author == requester)
            .toList();
      case 'feed' || 'story' || 'profile' || 'files' || 'bcast':
        if (!_settings.discoverable && type != 'bcast') {
          final p = db.peer(requester);
          if (p == null || !p.iFollow) return const [];
        }
        return db
            .itemsInScope(scope)
            .where((i) => i.owned || i.e.keep)
            .toList();
      case 'post':
        if (parts.length < 3) return const [];
        final pa = parts[1];
        if (pa == me.id) {
          return [
            ...db.itemsInScope(scope).where((i) => i.owned || i.e.keep),
            ...db.mutationsFor([parts[2]]).where((i) => i.owned || i.e.keep),
          ];
        }
        return db
            .itemsInScope(scope)
            .where((i) => i.owned || i.e.keep)
            .toList();
      case 'chan' || 'sfeed' || 'space' || 'forum':
        if (parts.length < 2 || parts[1].isEmpty) return const [];
        final s = db.space(parts[1]);
        if (s == null || !_canReadSpace(s, requester)) return const [];
        return db
            .itemsInScope(scope)
            .where((i) => i.owned || (i.e.keep && s.archive))
            .toList();
      case 'gdm' || 'gmeta':
        if (parts.length < 2 || parts[1].isEmpty) return const [];
        final g = db.group(parts[1]);
        if (g == null || !g.has(requester)) return const [];
        return db
            .itemsInScope(scope)
            .where((i) => i.owned || i.e.keep)
            .toList();
    }
    return const [];
  }

  Future<void> _answer(String to, String? qid, String scope, int since) async {
    final items = _serve(scope, to)
        .where(
          (i) =>
              i.ts >= since &&
              (i.e.expires == null || i.e.expires! > nowMs()) &&
              _mayServeMessage(i, to),
        )
        .toList();
    if (scope.startsWith('feed:') && scope == Scope.feed(me.id)) {
      // include likes, comments and edits on my posts
      final postIds = items
          .where((i) => i.e.kind == K.post)
          .map((i) => i.id)
          .toList();
      items.addAll(db.mutationsFor(postIds).where((i) => i.owned || i.e.keep));
    }
    if (items.isEmpty) {
      await _send(to, {'t': 'items', 'qid': qid, 'es': const []});
      return;
    }
    // The native layer refuses frames over 2 MiB, so batches are cut by size
    // as well as count. A single oversized envelope is skipped, not retried.
    const maxCount = 120;
    const maxBytes = 1536 * 1024;
    final batches = <List<Object?>>[];
    var part = <Object?>[];
    var bytes = 0;
    for (final item in items) {
      final wire = item.e.toWire();
      final size = utf8.encode(jsonEncode(wire)).length;
      if (size > maxBytes) continue;
      if (part.isNotEmpty && (part.length >= maxCount || bytes + size > maxBytes)) {
        batches.add(part);
        part = <Object?>[];
        bytes = 0;
      }
      part.add(wire);
      bytes += size;
    }
    if (part.isNotEmpty) batches.add(part);
    if (batches.isEmpty) {
      await _send(to, {'t': 'items', 'qid': qid, 'es': const []});
      return;
    }
    for (var i = 0; i < batches.length; i++) {
      await _send(to, {
        't': 'items',
        'qid': qid,
        'es': batches[i],
        'more': i + 1 < batches.length,
      });
    }
  }

  // ---------------------------------------------------------------------------
  // gossip

  String _topicFor(String label) => toHex(sha256(utf8.encode(label)));

  Future<void> _joinFeedTopic(String author, List<String> bootstrap) async {
    final t = _topicFor('mentos-feed:$author');
    _feedTopics[t] = author;
    await net.join(t, bootstrap.where((b) => b != me.id).toList());
  }

  Future<void> _leaveFeedTopic(String author) async {
    final t = _topicFor('mentos-feed:$author');
    _feedTopics.remove(t);
    await net.leave(t);
  }

  Future<void> _joinSpaceTopic(
    SpaceInfo s, [
    List<String> extra = const [],
  ]) async {
    final t = _topicFor('mentos-space:${s.id}');
    _spaceTopics[t] = s.id;
    final boot = <String>{s.owner, ...extra, ..._knownMembers(s.id)}
      ..remove(me.id);
    await net.join(t, boot.take(8).toList());
  }

  Future<void> _joinGroupTopic(
    GroupInfo g, [
    List<String> extra = const [],
  ]) async {
    final t = _topicFor('mentos-gdm:${g.id}');
    _groupTopics[t] = g.id;
    final boot = <String>{g.owner, ...g.members, ...extra}..remove(me.id);
    await net.join(t, boot.take(8).toList());
  }

  Uint8List? _sealKey(String key) {
    try {
      final bytes = base64Decode(key);
      if (bytes.length != 32) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _groupSend(GroupInfo g, Map<String, dynamic> msg) async {
    final key = _sealKey(g.key);
    if (key == null) return false;
    try {
      final t = _topicFor('mentos-gdm:${g.id}');
      final sealed = await Seal.close(key, utf8.encode(jsonEncode(msg)));
      return await net.broadcast(t, sealed);
    } catch (_) {
      return false;
    }
  }

  Set<String> _knownMembers(String spaceId) {
    final out = <String>{};
    for (final i in db.itemsInScope(Scope.spaceMeta(spaceId))) {
      out.add(i.author);
    }
    for (final m in _mem.values) {
      if (Scope.spaceOf(m.item.e.scope) == spaceId) out.add(m.item.author);
    }
    return out;
  }

  /// Owner, an explicit role, or a signed join that arrived on the sealed topic.
  /// A banned role always loses. An unknown id is not a member.
  bool _canReadSpace(SpaceInfo s, String peer) {
    if (s.roles[peer] == Role.banned) return false;
    if (peer == s.owner) return true;
    if (s.roles[peer] != null) return true;
    return _joinedMembers(s.id).contains(peer);
  }

  Set<String> _joinedMembers(String spaceId) {
    final announced = <String, bool>{};
    final all = [
      ...db.itemsInScope(Scope.spaceMeta(spaceId)),
      ..._memIn(Scope.spaceMeta(spaceId)),
    ];
    for (final i in all.where((i) => i.e.kind == K.member)) {
      announced[i.author] = i.body['left'] != true;
    }
    return announced.entries.where((e) => e.value).map((e) => e.key).toSet();
  }

  Set<String> _spaceAudience(SpaceInfo s) {
    final out = <String>{s.owner, ..._joinedMembers(s.id)};
    for (final e in s.roles.entries) {
      if (e.value == Role.banned) {
        out.remove(e.key);
      } else {
        out.add(e.key);
      }
    }
    return out;
  }

  Future<void> _rotateSpaceKey(SpaceInfo s) async {
    if (s.owner != me.id) return;
    final next = s.copyWith(key: base64Encode(randomBytes(32)));
    db.putSpace(next);
    for (final peer in _spaceAudience(next)) {
      if (peer == me.id) continue;
      await _sendOrQueue('skey:${next.id}:$peer', peer, {
        't': 'skey',
        'id': next.id,
        'key': next.key,
      });
    }
    _emit({Ch.spaces});
  }

  /// First remaining member, in a stable order, when the owner is gone.
  String? _groupHeir(GroupInfo g) {
    final rest = [for (final m in g.members) if (m != g.owner) m]..sort();
    if (rest.isEmpty) return null;
    return rest.first;
  }

  void _applyGroupKey(GroupInfo g, String key, {String? owner}) {
    final hadKey = _sealKey(g.key) != null;
    final next = g.copyWith(key: key, owner: owner ?? g.owner);
    db.putGroup(next);
    _emit({Ch.groups});
    if (!hadKey) {
      unawaited(
        _groupSend(next, {
          't': 'q',
          'scope': Scope.gdm(g.id),
          'a': me.id,
          'since': 0,
        }),
      );
      unawaited(
        _groupSend(next, {
          't': 'q',
          'scope': Scope.gmeta(g.id),
          'a': me.id,
          'since': 0,
        }),
      );
    }
  }

  /// Sends [key] to every other member. The caller has to be the owner.
  Future<void> _shareGroupKey(GroupInfo g, String key) async {
    if (g.owner != me.id || _sealKey(key) == null) return;
    final next = g.copyWith(key: key);
    db.putGroup(next);
    for (final peer in {next.owner, ...next.members}) {
      if (peer == me.id) continue;
      await _sendOrQueue('gkey:${next.id}:$peer', peer, {
        't': 'gkey',
        'id': next.id,
        'key': key,
      });
    }
    _emit({Ch.groups});
  }

  Future<void> _rotateGroupKey(GroupInfo g) async {
    await _shareGroupKey(g, base64Encode(randomBytes(32)));
  }

  Future<bool> _spaceSend(SpaceInfo s, Map<String, dynamic> msg) async {
    final key = _sealKey(s.key);
    if (key == null) return false;
    try {
      final t = _topicFor('mentos-space:${s.id}');
      final sealed = await Seal.close(key, utf8.encode(jsonEncode(msg)));
      return await net.broadcast(t, sealed);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _feedSend(Map<String, dynamic> msg, {String? author}) async {
    final t = _topicFor('mentos-feed:${author ?? me.id}');
    return net.broadcast(t, Uint8List.fromList(utf8.encode(jsonEncode(msg))));
  }

  Future<void> _onGossip(String topic, String from, Uint8List data) async {
    _heard(from);
    final spaceId = _spaceTopics[topic];
    if (spaceId != null) {
      final s = db.space(spaceId);
      if (s == null) return;
      final key = _sealKey(s.key);
      if (key == null) return;
      final plain = await Seal.open(key, data);
      if (plain == null) return;
      final m = _decode(plain);
      if (m == null) return;
      final a = m['a'] as String?;
      if (a != null) _heard(a);
      switch (m['t']) {
        case 'item':
          final e = Envelope.fromWire(m['e']);
          if (e != null && Scope.spaceOf(e.scope) == spaceId) {
            await ingest(e, via: e.author, sealed: true);
          }
        case 'q':
          final scope = m['scope'] as String? ?? '';
          if (a != null &&
              a != me.id &&
              Scope.spaceOf(scope) == spaceId &&
              _canReadSpace(s, a)) {
            final items = db
                .itemsInScope(scope, since: (m['since'] as num?)?.toInt() ?? 0)
                .where(
                  (i) =>
                      (i.owned || (i.e.keep && s.archive)) &&
                      _mayServeMessage(i, a),
                )
                .toList();
            if (items.isNotEmpty) {
              for (var i = 0; i < items.length; i += 120) {
                await _send(a, {
                  't': 'items',
                  'es': items
                      .skip(i)
                      .take(120)
                      .map((x) => x.e.toWire())
                      .toList(),
                });
              }
            }
          }
        case 'typing':
          if (a != null) {
            _setTyping(m['scope'] as String? ?? '', a, m['on'] == true);
          }
        case 'here':
          break;
      }
      return;
    }
    final groupId = _groupTopics[topic];
    if (groupId != null) {
      final g = db.group(groupId);
      if (g == null) return;
      final key = _sealKey(g.key);
      if (key == null) return;
      final plain = await Seal.open(key, data);
      if (plain == null) return;
      final m = _decode(plain);
      if (m == null) return;
      final a = m['a'] as String?;
      if (a != null) _heard(a);
      switch (m['t']) {
        case 'item':
          final e = Envelope.fromWire(m['e']);
          if (e != null &&
              (e.scope == Scope.gdm(groupId) ||
                  e.scope == Scope.gmeta(groupId))) {
            await ingest(e, via: e.author, sealed: true);
          }
        case 'q':
          final scope = m['scope'] as String? ?? '';
          if (a != null &&
              a != me.id &&
              g.has(a) &&
              (scope == Scope.gdm(groupId) || scope == Scope.gmeta(groupId))) {
            final items = db
                .itemsInScope(scope, since: (m['since'] as num?)?.toInt() ?? 0)
                .where((i) => (i.owned || i.e.keep) && _mayServeMessage(i, a))
                .toList();
            for (var i = 0; i < items.length; i += 120) {
              await _send(a, {
                't': 'items',
                'es': items.skip(i).take(120).map((x) => x.e.toWire()).toList(),
              });
            }
          }
        case 'typing':
          if (a != null) {
            _setTyping(m['scope'] as String? ?? '', a, m['on'] == true);
          }
      }
      return;
    }
    if (_feedTopics.containsKey(topic)) {
      final m = _decode(data);
      if (m == null) return;
      switch (m['t']) {
        case 'item':
          final e = Envelope.fromWire(m['e']);
          if (e != null) await ingest(e, via: e.author);
        case 'revoke':
          final author = _feedTopics[topic]!;
          if (from == author) {
            await _onRevoke(author, m['scope'] as String? ?? '');
          }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // ingest

  Future<void> _receiveItem(Envelope e, String from) async {
    // Serialize duplicates per ID: otherwise simultaneous retries can both
    // pass the pre-verification existence check and repeat side effects.
    final pending = _accepting[e.id];
    if (pending != null) {
      await pending;
    } else {
      final acceptance = ingest(e, via: from);
      _accepting[e.id] = acceptance;
      try {
        await acceptance;
      } finally {
        _accepting.remove(e.id);
      }
    }
    final accepted = db.item(e.id) ?? _mem[e.id]?.item;
    if (e.kind != K.msg ||
        e.author != from ||
        accepted == null ||
        accepted.e.payload != e.payload ||
        accepted.e.sig != e.sig ||
        _tombstones.contains(e.id) ||
        (e.expires != null && e.expires! <= nowMs())) {
      return;
    }
    // Re-acknowledge accepted duplicates so a lost ACK does not strand a send.
    db.enqueueOutbox(
      'ack:${e.id}',
      from,
      jsonEncode({'t': 'ack', 'id': e.id, 'scope': e.scope, 'ts': e.ts}),
    );
    if (_settings.readReceipts && db.wasMessageRead(e.id)) {
      db.enqueueOutbox(
        'seen:${e.id}',
        from,
        jsonEncode({
          't': 'seen',
          'ids': [e.id],
          'scope': e.scope,
          'ts': e.ts,
        }),
      );
    }
    unawaited(_flushOutbox());
  }

  /// Accepts a verified item from the network into the right tier.
  Future<bool> ingest(Envelope e, {String? via, bool sealed = false}) async {
    if (_tombstones.contains(e.id)) return false;
    if (e.author == me.id) {
      // my own item coming back, e.g. restored from someone who kept it
      if (db.hasItem(e.id) || !await e.verify()) return false;
      db.putItem(e, owned: true);
      _emit({e.scope, ..._derivedKeys(e)});
      return true;
    }
    final existing = _mem[e.id];
    if (existing != null) {
      if (via != null) existing.sources.add(via);
      return false;
    }
    if (db.hasItem(e.id)) return false;
    if (db.peer(e.author)?.blocked ?? false) return false;
    if (!e.sane) return false;
    final exp = e.expires;
    if (exp != null && exp <= nowMs()) return false;
    if (e.ts > nowMs() + 120000) return false;
    if (!_authorized(e, sealed: sealed)) return false;
    if (!await e.verify()) return false;
    _heard(e.author);

    final keep = _shouldKeep(e);
    final item = Item(e, owned: false, kept: keep);
    if (keep) {
      db.putItem(e, owned: false);
      unawaited(_keepMedia(item, via));
    } else {
      _mem[e.id] = _Mem(item, {e.author, ?via});
    }
    await _sideEffects(e, via);
    _emit({e.scope, ..._derivedKeys(e)});
    return true;
  }

  Set<String> _derivedKeys(Envelope e) {
    final t = Scope.type(e.scope);
    return {
      if (t == 'feed' || t == 'post' || t == 'sfeed') Ch.feed,
      if (t == 'dm' || t == 'gdm') Ch.chats,
      if (t == 'story') Ch.stories,
      if (t == 'bcast' || t == 'chan') Ch.feed,
      if (t == 'profile') Ch.peers,
      if (t == 'space') Ch.spaces,
      if (t == 'gmeta') Ch.groups,
      if (t == 'files') Ch.files,
      if (t == 'forum') Ch.feed,
      if (e.target != null) 'item:${e.target}',
    };
  }

  bool _dmWith(String scope, String peer) {
    final parts = Scope.parts(scope);
    return parts.length == 3 &&
        parts.first == 'dm' &&
        parts.contains(peer) &&
        parts.contains(me.id);
  }

  bool _authorized(Envelope e, {bool sealed = false}) {
    final parts = Scope.parts(e.scope);
    switch (parts.first) {
      case 'dm':
        return parts.length == 3 &&
            parts.contains(e.author) &&
            parts.contains(me.id);
      case 'feed' || 'profile' || 'files':
        return parts.length == 2 && parts[1] == e.author;
      case 'story':
        if (parts.length != 2) return false;
        if (e.kind == K.story) return parts[1] == e.author;
        return K.mutations.contains(e.kind);
      case 'bcast':
        if (parts.length != 3) return false;
        if (e.kind == K.post || e.kind == K.chan) return parts[1] == e.author;
        return K.mutations.contains(e.kind);
      case 'post':
        if (parts.length != 3) return false;
        return e.kind == K.comment || K.mutations.contains(e.kind);
      case 'chan' || 'sfeed' || 'space' || 'forum':
        if (parts.length < 2 || parts[1].isEmpty) return false;
        final s = db.space(parts[1]);
        if (s == null || s.roles[e.author] == Role.banned) return false;
        if (e.kind == K.spaceMeta) return e.author == s.owner;
        if (sealed) return true;
        return _canReadSpace(s, e.author);
      case 'gdm' || 'gmeta':
        if (parts.length < 2 || parts[1].isEmpty) return false;
        final g = db.group(parts[1]);
        return g != null && g.has(e.author);
    }
    return false;
  }

  bool _shouldKeep(Envelope e) {
    final parts = Scope.parts(e.scope);
    switch (parts.first) {
      case 'dm':
        return db.grant(e.scope, e.author, GrantDir.inbound) ==
            GrantState.active;
      case 'profile':
        if (!e.keep) return false;
        final p = db.peer(e.author);
        return p != null &&
            (p.iFollow ||
                p.followsMe ||
                p.preserve ||
                db.dmScopes().contains(Scope.dm(me.id, e.author)));
      case 'feed' || 'story' || 'files':
        return e.keep && (db.peer(e.author)?.preserve ?? false);
      case 'post':
        if (parts.length < 2 || !e.keep) return false;
        final pa = parts[1];
        return pa == me.id || (db.peer(pa)?.preserve ?? false);
      case 'space':
        if (parts.length < 2) return false;
        final s = db.space(parts[1]);
        if (s == null) return false;
        return e.kind == K.spaceMeta || e.keep;
      case 'chan' || 'sfeed' || 'forum':
        if (parts.length < 2) return false;
        final s = db.space(parts[1]);
        return s != null && s.preserve && s.archive && e.keep;
      case 'gdm' || 'gmeta':
        if (parts.length < 2) return false;
        final g = db.group(parts[1]);
        return g != null && g.preserve && e.keep;
    }
    return false;
  }

  Future<void> _keepMedia(Item item, String? via) async {
    try {
      final refs = [...MediaRef.listFrom(item.body['media'])];
      final avatar = MediaRef.fromJson(item.body['avatar']);
      if (avatar != null) refs.add(avatar);
      for (final r in refs) {
        await media.keep(r, [item.author, ?via], item.e.scope);
      }
      if (refs.isNotEmpty) _emit({Ch.files});
    } catch (_) {}
  }

  Future<void> _sideEffects(Envelope e, String? via) async {
    final type = Scope.type(e.scope);
    switch (e.kind) {
      case K.profile:
        final p = Profile.fromEnvelope(e);
        final prev = _liveProfiles[e.author] ?? db.keptProfile(e.author);
        if (prev == null || prev.ts <= p.ts) _liveProfiles[e.author] = p;
        db.ensurePeer(e.author);
        if (!p.keepPosts && (db.peer(e.author)?.preserve ?? false)) {
          await _onRevoke(e.author, Scope.feed(e.author));
        }
        // Keep only the latest profile, and only inside the profile scope.
        // Cleaning the whole scope used to delete a chat when a profile
        // arrived there.
        if (e.scope == Scope.profile(e.author)) {
          for (final old in db.itemsInScope(e.scope).where(
            (i) => !i.owned && i.id != e.id && i.e.kind == K.profile,
          )) {
            db.deleteItem(old.id);
          }
        }
        _emit({Ch.peers});
      case K.msg:
        if (type == 'dm') {
          db.ensureChat(e.scope, defaultTtl: _settings.defaultTtl);
          db.ensurePeer(e.author);
          _setTyping(e.scope, e.author, false);
        } else {
          _setTyping(e.scope, e.author, false);
        }
        if (e.author != me.id) {
          final text = (e.body['text'] as String?)?.trim() ?? '';
          final gid = type == 'gdm' ? Scope.parts(e.scope).elementAtOrNull(1) : null;
          final group = gid == null ? null : db.group(gid);
          _notify(
            at: e.ts,
            id: 'msg:${e.id}',
            title: group == null ? nameOf(e.author) : '${nameOf(e.author)} · ${group.name}',
            body: text.isNotEmpty ? text : 'New message',
            route: type == 'dm' ? '/chat/${e.author}' : (gid != null ? '/g/$gid' : '/chats'),
            scope: e.scope,
            category: type == 'dm' ? 'dm' : (mentionsMe(text) ? 'mention' : 'group'),
          );
        }
      case K.story:
        if (e.author != me.id && (db.peer(e.author)?.iFollow ?? false)) {
          _notify(
            at: e.ts,
            id: 'story:${e.id}',
            title: nameOf(e.author),
            body: 'Posted a story',
            route: '/story/${e.author}',
            category: 'story',
          );
        }
      case K.post:
        final owner = Scope.bcastOwner(e.scope);
        final text = (e.body['text'] as String?)?.trim() ?? '';
        if (e.author != me.id && owner != null) {
          final chan = Scope.parts(e.scope).elementAtOrNull(2) ?? '';
          if (e.body['silent'] == true || !isSubscribed(owner, chan)) break;
          _notify(
            at: e.ts,
            id: 'chan:${e.id}',
            title: nameOf(e.author),
            body: text.isNotEmpty ? text : 'New post in a channel',
            route: '/ch/$owner/$chan',
            scope: e.scope,
            category: 'channel',
          );
        } else if (e.author != me.id && mentionsMe(text)) {
          _notify(
            at: e.ts,
            id: 'mention:${e.id}',
            title: nameOf(e.author),
            body: text,
            route: '/post/${e.id}',
            scope: e.scope,
            category: 'mention',
          );
        }
      case K.comment:
        if (Scope.postAuthor(e.scope) == me.id) {
          db.addActivity(
            Activity(
              id: e.id,
              kind: 'comment',
              actor: e.author,
              ref: Scope.parts(e.scope)[2],
              scope: e.scope,
              text: e.body['text'] as String?,
              ts: e.ts,
            ),
          );
          _notify(
            at: e.ts,
            id: 'act:${e.id}',
            title: nameOf(e.author),
            body: (e.body['text'] as String?)?.trim().isNotEmpty == true
                ? e.body['text'] as String
                : 'Replied to your post',
            route: '/activity',
            scope: e.scope,
            category: 'reply',
          );
          _emit({Ch.activity});
        }
      case K.like when e.body['sub'] == true:
        final target = e.target;
        final chan = target == null ? null : db.item(target);
        if (Scope.postAuthor(e.scope) == me.id && chan != null && chan.owned && chan.e.kind == K.chan && e.body['on'] != false) {
          db.addActivity(Activity(
            id: 'sub:${e.author}:$target',
            kind: 'subscribe',
            actor: e.author,
            ref: target,
            scope: e.scope,
            text: chan.body['name'] as String?,
            ts: e.ts,
          ));
          _notify(
            at: e.ts,
            id: 'sub:${e.author}:$target',
            title: nameOf(e.author),
            body: 'Subscribed to ${chan.body['name'] ?? 'your channel'}',
            route: '/ch/${me.id}/$target',
            category: 'follow',
          );
          _emit({Ch.activity, Ch.channels});
        }
      case K.like:
        if (Scope.postAuthor(e.scope) == me.id && e.body['on'] != false) {
          final target = e.target;
          final targetItem = target == null ? null : db.item(target);
          if (targetItem != null && targetItem.owned) {
            db.addActivity(
              Activity(
                id: 'like:${e.author}:$target',
                kind: 'like',
                actor: e.author,
                ref: target,
                scope: e.scope,
                ts: e.ts,
              ),
            );
            _notify(
              at: e.ts,
              id: 'like:${e.author}:$target',
              title: nameOf(e.author),
              body: 'Liked your post',
              route: '/activity',
              scope: e.scope,
            );
            _emit({Ch.activity});
          }
        }
      case K.react when type == 'story':
        final target = e.target;
        if (target != null && Scope.parts(e.scope).elementAtOrNull(1) == me.id && e.body['on'] != false) {
          final emoji = e.body['emoji'] is String ? e.body['emoji'] as String : '';
          db.addActivity(Activity(
            id: 'sreact:${e.author}:$target',
            kind: 'react',
            actor: e.author,
            ref: target,
            scope: e.scope,
            text: emoji,
            ts: e.ts,
          ));
          _notify(
            at: e.ts,
            id: 'sreact:${e.author}:$target:$emoji',
            title: nameOf(e.author),
            body: 'Reacted $emoji to your story',
            route: '/story/${me.id}',
            category: 'like',
          );
          _emit({Ch.activity, Ch.stories});
        }
      case K.react:
        final target = e.target;
        if (target != null &&
            type == 'dm' &&
            db.item(target)?.owned == true &&
            e.body['on'] != false) {
          db.addActivity(
            Activity(
              id: 'react:${e.author}:$target',
              kind: 'react',
              actor: e.author,
              ref: target,
              scope: e.scope,
              text: e.body['emoji'] as String?,
              ts: e.ts,
            ),
          );
          _emit({Ch.activity});
        }
      case K.del:
        final target = e.target;
        if (target == null) break;
        final t = db.item(target) ?? _mem[target]?.item;
        if (t == null || t.owned) break;
        final s = Scope.spaceOf(t.e.scope);
        final mod =
            s != null &&
            (db.space(s)?.roleOf(e.author).index ?? 9) <= Role.mod.index;
        if (t.author == e.author || mod) {
          _tombstones.add(target);
          db.deleteItem(target);
          _mem.remove(target);
          for (final m in MediaRef.listFrom(t.body['media'])) {
            final f = db.file(m.hash);
            if (f != null && f.origin != 'mine') await media.deleteBlob(m.hash);
          }
        }
      case K.spaceMeta:
        final sid = Scope.spaceOf(e.scope)!;
        final s = db.space(sid);
        if (s != null && e.ts >= s.metaTs) {
          db.putSpace(s.withMeta(e));
          _emit({Ch.spaces});
        }
      case K.member:
        final sid = Scope.spaceOf(e.scope)!;
        final s = db.space(sid);
        if (s != null &&
            e.body['left'] == true &&
            s.owner == me.id &&
            e.author != me.id) {
          await _rotateSpaceKey(s);
        }
        if (s != null) _emit({Ch.spaces});
      case K.group:
        final gid = Scope.parts(e.scope)[1];
        var g = db.group(gid);
        if (g == null) {
          final members = [
            for (final x in (e.body['members'] as List?) ?? const [])
              if (x is String) x,
          ];
          final claimedOwner = e.body['owner'] as String? ?? '';
          if (claimedOwner != e.author && claimedOwner != me.id) break;
          if (!members.contains(me.id) && claimedOwner != me.id) break;
          g = GroupInfo(
            id: gid,
            name: (e.body['name'] as String?) ?? 'Group',
            owner: claimedOwner.isEmpty ? e.author : claimedOwner,
            key: e.body['key'] as String? ?? '',
            members: members,
            joined: nowMs(),
            metaTs: e.ts,
          );
          if (g.key.isEmpty) break;
          db.putGroup(g);
          unawaited(_joinGroupTopic(g));
        } else if (e.ts >= g.metaTs) {
          final updated = g.withMeta(e);
          db.putGroup(updated);
          final removed = g.members.toSet().difference(updated.members.toSet());
          if (removed.isNotEmpty &&
              updated.owner == me.id &&
              updated.members.contains(me.id)) {
            await _rotateGroupKey(updated);
          } else if (!updated.members.contains(updated.owner)) {
            final heir = _groupHeir(updated);
            final pending = _pendingGroupKey.remove(gid);
            if (heir == me.id) {
              await _rotateGroupKey(updated.copyWith(owner: me.id));
            } else if (pending != null &&
                pending.from == heir &&
                _sealKey(pending.key) != null) {
              _applyGroupKey(updated, pending.key, owner: heir);
            }
          }
        }
        _emit({Ch.groups, Ch.chats});
      case K.host:
        _emit({Ch.files});
    }
  }

  void _setTyping(String scope, String peer, bool on) {
    if (!_settings.typingIndicators) return;
    final m = _typing.putIfAbsent(scope, () => <String, int>{});
    final had = m.containsKey(peer);
    if (on) {
      m[peer] = nowMs() + 6000;
    } else {
      m.remove(peer);
    }
    if (had != on) _emit({Ch.typing(scope), Ch.chats});
  }

  // ---------------------------------------------------------------------------
  // custody

  Future<void> _onSync(String from, String op, String scope) async {
    if (!scope.startsWith('dm:') || Scope.dmPeer(scope, me.id) != from) return;
    switch (op) {
      case 'offer':
        if (db.grant(scope, from, GrantDir.inbound) == GrantState.active) {
          await _send(from, {'t': 'sync', 'op': 'accept', 'scope': scope});
          break;
        }
        db.setGrant(scope, from, GrantDir.inbound, GrantState.pending);
        db.addActivity(
          Activity(
            id: 'sync:$scope:${nowMs()}',
            kind: 'sync',
            actor: from,
            scope: scope,
            ts: nowMs(),
          ),
        );
        _notify(
          id: 'sync:$scope',
          title: nameOf(from),
          body: 'Wants to keep a copy of this chat',
          route: '/activity',
          scope: scope,
        );
        _emit({Ch.grants, Ch.activity, scope, Ch.chats});
        if (_settings.autoAcceptSync) await acceptSync(scope, from, true);
      case 'accept':
        if (db.grant(scope, from, GrantDir.out) != null) {
          db.setGrant(scope, from, GrantDir.out, GrantState.active);
          await _answer(from, null, scope, 0);
          _emit({Ch.grants, scope, Ch.chats});
        }
      case 'decline' || 'drop':
        db.setGrant(scope, from, GrantDir.out, null);
        _emit({Ch.grants, scope, Ch.chats});
      case 'revoke':
        await _onRevoke(from, scope);
    }
  }

  Future<void> _onRevoke(String author, String scope) async {
    var dropped = 0;
    if (scope.startsWith('dm:')) {
      db.setGrant(scope, author, GrantDir.inbound, null);
      dropped = db.dropKept(author, scope);
    } else if (scope == Scope.feed(author)) {
      dropped =
          db.dropKept(author, 'feed:$author') +
          db.dropKept(author, 'story:$author');
    }
    if (dropped > 0 || scope.startsWith('dm:')) {
      _emit({scope, Ch.grants, Ch.feed, Ch.chats});
      if (isOnline(author)) await query(author, scope);
    }
  }

  Future<void> _resendOffers(String peer) async {
    for (final g in db.grants().where(
      (g) =>
          g.peer == peer &&
          g.dir == GrantDir.out &&
          g.state == GrantState.pending,
    )) {
      await _send(peer, {'t': 'sync', 'op': 'offer', 'scope': g.scope});
    }
  }

  Future<void> _broadcastRevoke(String scope) async {
    await _feedSend({'t': 'revoke', 'scope': scope});
    for (final g in db.grants().where(
      (g) => g.scope == scope && g.dir == GrantDir.out,
    )) {
      await _send(g.peer, {'t': 'revoke', 'scope': scope});
      db.setGrant(scope, g.peer, GrantDir.out, null);
    }
    _emit({Ch.grants});
  }

  /// Promotes live items into the DB after consent was granted.
  void _promote(bool Function(Item i) match) {
    final moved = <String>{};
    _mem.removeWhere((id, m) {
      if (!match(m.item)) return false;
      db.putItem(m.item.e, owned: false);
      unawaited(
        _keepMedia(
          Item(m.item.e, owned: false, kept: true),
          m.sources.firstOrNull,
        ),
      );
      moved.add(m.item.e.scope);
      return true;
    });
    if (moved.isNotEmpty) _emit({...moved, Ch.feed, Ch.chats, Ch.files});
  }

  SyncState syncState(String scope) {
    final peer = Scope.dmPeer(scope, me.id);
    if (peer == null) {
      return const SyncState(mine: null, theirs: null, theirsOffered: false);
    }
    final theirs = db.grant(scope, peer, GrantDir.inbound);
    return SyncState(
      mine: db.grant(scope, peer, GrantDir.out),
      theirs: theirs,
      theirsOffered: theirs == GrantState.pending,
    );
  }

  /// Ask [peer] to keep my side of the chat, or withdraw that permission.
  Future<void> setShareMine(String scope, bool on) async {
    final peer = Scope.dmPeer(scope, me.id);
    if (peer == null) return;
    if (on) {
      db.setGrant(scope, peer, GrantDir.out, GrantState.pending);
      await _send(peer, {'t': 'sync', 'op': 'offer', 'scope': scope});
    } else {
      db.setGrant(scope, peer, GrantDir.out, null);
      await _send(peer, {'t': 'sync', 'op': 'revoke', 'scope': scope});
    }
    _emit({Ch.grants, scope, Ch.chats});
  }

  Future<void> acceptSync(String scope, String peer, bool accept) async {
    if (accept) {
      db.setGrant(scope, peer, GrantDir.inbound, GrantState.active);
      await _send(peer, {'t': 'sync', 'op': 'accept', 'scope': scope});
      _promote((i) => i.e.scope == scope && i.author == peer);
    } else {
      db.setGrant(scope, peer, GrantDir.inbound, null);
      await _send(peer, {'t': 'sync', 'op': 'decline', 'scope': scope});
    }
    _emit({Ch.grants, scope, Ch.chats});
  }

  /// Stop keeping [peer]'s side of the chat on this device.
  Future<void> dropTheirs(String scope) async {
    final peer = Scope.dmPeer(scope, me.id);
    if (peer == null) return;
    db.setGrant(scope, peer, GrantDir.inbound, null);
    db.dropKept(peer, scope);
    await _send(peer, {'t': 'sync', 'op': 'drop', 'scope': scope});
    if (isOnline(peer)) await query(peer, scope);
    _emit({Ch.grants, scope, Ch.chats});
  }

  Future<void> setPreserve(String author, bool on) async {
    db.updatePeer(author, {'preserve': on ? 1 : 0});
    if (on) {
      _promote(
        (i) =>
            i.author == author &&
                i.e.keep &&
                (i.e.scope == Scope.feed(author) ||
                    i.e.scope == Scope.story(author) ||
                    i.e.scope == Scope.files(author)) ||
            i.e.keep && Scope.postAuthor(i.e.scope) == author,
      );
    } else {
      db.dropKept(author, 'feed:$author');
      db.dropKept(author, 'story:$author');
      db.dropKept(author, 'files:$author');
      for (final i
          in db.itemsByScopePrefix('post:$author:').where((i) => !i.owned)) {
        db.deleteItem(i.id);
      }
    }
    await _send(author, {'t': 'preserve', 'on': on});
    _emit({Ch.peers, Ch.feed, Ch.grants, Ch.stories});
  }

  // ---------------------------------------------------------------------------
  // publishing

  Future<Envelope> _publish(
    String kind,
    String scope,
    Map<String, dynamic> body, {
    bool keep = false,
  }) async {
    final e = await Envelope.create(
      me,
      kind: kind,
      scope: scope,
      body: body,
      keep: keep,
    );
    if (kind == K.msg) {
      db.queueMessage(e, _messageRecipients(scope));
      _emit({scope, ..._derivedKeys(e)});
      unawaited(flushDeliveries());
      return e;
    }
    db.putItem(e, owned: true);
    if (kind == K.del && e.target != null) _tombstones.add(e.target!);
    _emit({scope, ..._derivedKeys(e)});
    unawaited(_distribute(e));
    return e;
  }

  Future<void> _distribute(Envelope e) async {
    final parts = Scope.parts(e.scope);
    final wire = {'t': 'item', 'e': e.toWire()};
    switch (parts.first) {
      case 'dm':
        final peer = Scope.dmPeer(e.scope, me.id);
        if (peer == null) return;
        await _sendOrQueue(e.id, peer, wire);
      case 'story' when parts.length > 1 && parts[1] != me.id:
        // Likes, views and reactions on someone else's story go to that
        // author, not to this person's own followers.
        await _sendOrQueue(e.id, parts[1], wire);
      case 'feed' || 'story' || 'profile' || 'files' || 'bcast':
        if (!_settings.discoverable) {
          await _queueFanout(
            e.id,
            'quiet:${me.id}',
            wire,
            () => _sendQuiet(wire),
          );
        } else {
          await _queueFanout(
            e.id,
            'feed:${me.id}',
            wire,
            () => _feedSend(wire),
          );
        }
      case 'post':
        if (parts.length < 2) return;
        final pa = parts[1];
        if (pa == me.id) {
          if (!_settings.discoverable) {
            await _queueFanout(
              e.id,
              'quiet:${me.id}',
              wire,
              () => _sendQuiet(wire),
            );
          } else {
            await _queueFanout(
              e.id,
              'feed:${me.id}',
              wire,
              () => _feedSend(wire),
            );
          }
        } else {
          await _sendOrQueue(e.id, pa, wire);
          if (_settings.discoverable) unawaited(_feedSend(wire, author: pa));
        }
      case 'chan' || 'sfeed' || 'space' || 'forum':
        if (parts.length < 2) return;
        final s = db.space(parts[1]);
        if (s != null) {
          await _queueFanout(
            e.id,
            'space:${s.id}',
            wire,
            () => _spaceSend(s, wire),
          );
        }
      case 'gdm' || 'gmeta':
        if (parts.length < 2) return;
        final g = db.group(parts[1]);
        if (g != null) {
          await _queueFanout(
            e.id,
            'gdm:${g.id}',
            wire,
            () => _groupSend(g, wire),
          );
        }
    }
  }

  Envelope? _myProfileEnvelope() =>
      db.itemsInScope(Scope.profile(me.id)).where((i) => i.owned).lastOrNull?.e;

  Future<void> _ensureProfile() async {
    if (_myProfileEnvelope() == null) {
      await updateProfile(name: '', bio: '');
    }
  }

  Profile get myProfile {
    final e = _myProfileEnvelope();
    return e == null ? Profile(id: me.id) : Profile.fromEnvelope(e);
  }

  Future<void> updateProfile({
    required String name,
    required String bio,
    MediaRef? avatar,
  }) async {
    for (final old
        in db.itemsInScope(Scope.profile(me.id)).where((i) => i.owned)) {
      db.deleteItem(old.id);
    }
    final e = await _publish(K.profile, Scope.profile(me.id), {
      'name': name.trim(),
      'bio': bio.trim(),
      'avatar': ?avatar?.toJson(),
      'keepPosts': _settings.keepPosts,
      'discoverable': _settings.discoverable,
    }, keep: _settings.keepProfile);
    for (final p in onlinePeers) {
      await _send(p, {'t': 'item', 'e': e.toWire()});
    }
    _emit({Ch.peers});
  }

  Future<Envelope> createPost({
    required String text,
    List<MediaRef> media = const [],
    Poll? poll,
    bool? keep,
    String? spaceId,
    String? boardId,
    String title = '',
    Map<String, dynamic>? repost,
    bool ai = false,
    bool nsfw = false,
    String? channelId,
    String? bcastId,
    bool silent = false,
    Map<String, Object?>? live,
  }) {
    final scope = bcastId != null
        ? Scope.bcast(me.id, bcastId)
        : channelId != null && spaceId != null
        ? Scope.channel(spaceId, channelId)
        : boardId != null && spaceId != null
        ? Scope.forum(spaceId, boardId)
        : spaceId == null
        ? Scope.feed(me.id)
        : Scope.spaceFeed(spaceId);
    final k = spaceId == null
        ? (keep ?? _settings.keepPosts)
        : (db.space(spaceId)?.shareMine ?? true);
    return _publish(K.post, scope, {
      'text': text,
      if (title.isNotEmpty) 'title': title,
      'board': ?boardId,
      'channel': ?channelId,
      if (media.isNotEmpty) 'media': media.map((m) => m.toJson()).toList(),
      'poll': ?poll?.toJson(),
      'repost': ?repost,
      if (ai) 'ai': true,
      if (nsfw) 'nsfw': true,
      if (silent) 'silent': true,
      'live': ?live,
    }, keep: k);
  }

  Future<void> closePoll(Item post) => _publish(K.edit, post.e.scope, {
    'target': post.id,
    'text': post.body['text'],
    'closePoll': true,
  }, keep: true);

  ({
    int likes,
    bool liked,
    int views,
    List<String> viewers,
    Map<String, String> reactions,
  })
  storyStats(Item s) {
    final f = fold(_mutationsFor([s.id]), {s.id: s});
    final likes = f.likes[s.id] ?? const <String>{};
    final views = f.views[s.id] ?? const <String>{};
    return (
      likes: likes.length,
      liked: likes.contains(me.id),
      views: views.length,
      viewers: views.toList(),
      reactions: f.reactions[s.id] ?? const {},
    );
  }

  /// Replies to a story land in the author's DMs, like Instagram, with a
  /// reference to the story so the chat can show what was answered.
  Future<void> storyReply(Item s, String text, {String? prompt}) => sendMessage(
    Scope.dm(me.id, s.author),
    text: text.trim(),
    story: {
      'id': s.id,
      'a': s.author,
      if (s.body['text'] is String) 'text': _clip(s.body['text'] as String, 120),
      'prompt': ?prompt,
    },
  );

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  Future<void> recordView(Item item) async {
    if (item.author == me.id) return;
    final key = 'view:${item.id}';
    if (db.getKv(key) == '1') return;
    db.setKv(key, '1');
    await _publish(
      K.view,
      item.e.scope.startsWith('story:')
          ? item.e.scope
          : Scope.post(item.author, item.id),
      {'target': item.id},
      // Same consent as likes: lets the author keep the count across restarts.
      keep: _settings.keepReplies,
    );
  }

  Future<void> comment(PostView post, String text, {String? replyTo}) =>
      _publish(K.comment, post.scope, {
        'text': text,
        'replyTo': ?replyTo,
      }, keep: _settings.keepReplies);

  Future<void> like(String scope, String target, bool on) => _publish(
    K.like,
    scope,
    {'target': target, 'on': on},
    keep: _settings.keepReplies,
  );

  Future<void> vote(String scope, String target, int? option) => _publish(
    K.vote,
    scope,
    {'target': target, 'option': option},
    keep: _settings.keepReplies,
  );

  Future<void> createStory({
    String? text,
    MediaRef? media,
    int color = 0,
    bool nsfw = false,
    List<StorySticker> stickers = const [],
  }) => _publish(K.story, Scope.story(me.id), {
    'text': ?text,
    if (media != null) 'media': [media.toJson()],
    if (stickers.isNotEmpty) 'stk': [for (final s in stickers) s.toJson()],
    'color': color,
    if (nsfw) 'nsfw': true,
    'exp': nowMs() + const Duration(hours: 24).inMilliseconds,
  }, keep: _settings.keepPosts);

  Future<Envelope> sendMessage(
    String scope, {
    String text = '',
    List<MediaRef> media = const [],
    String? replyTo,
    Poll? poll,
    bool forwarded = false,
    bool nsfw = false,
    Map<String, dynamic>? story,
  }) {
    final keep = switch (Scope.type(scope)) {
      'dm' => true,
      'gdm' => db.group(Scope.parts(scope)[1])?.shareMine ?? true,
      _ => db.space(Scope.spaceOf(scope) ?? '')?.shareMine ?? true,
    };
    if (scope.startsWith('dm:') || scope.startsWith('gdm:')) {
      db.ensureChat(scope, defaultTtl: _settings.defaultTtl);
    }
    final ttl = (db.chat(scope)['ttl'] as int?) ?? 0;
    _setTypingSelf(scope, false);
    return _publish(K.msg, scope, {
      'text': text,
      if (media.isNotEmpty) 'media': media.map((m) => m.toJson()).toList(),
      'replyTo': ?replyTo,
      'poll': ?poll?.toJson(),
      if (forwarded) 'fwd': true,
      if (nsfw) 'nsfw': true,
      'story': ?story,
      if (ttl > 0) 'exp': nowMs() + ttl * 1000,
    }, keep: keep);
  }

  Future<void> react(String scope, String target, String? emoji) => _publish(
    K.react,
    scope,
    {'target': target, 'emoji': emoji ?? '', 'on': emoji != null},
    keep: true,
  );

  Future<void> edit(String scope, String target, String text) =>
      _publish(K.edit, scope, {'target': target, 'text': text}, keep: true);

  /// Deletes an item everywhere it was shared. Own items are removed
  /// physically; moderators can remove others' items in spaces.
  Future<void> deleteItem(Item item) async {
    if (item.owned) {
      db.deleteItem(item.id);
      for (final m in MediaRef.listFrom(item.body['media'])) {
        await media.deleteBlob(m.hash);
      }
    } else {
      db.deleteItem(item.id);
      _mem.remove(item.id);
    }
    await _publish(K.del, item.e.scope, {'target': item.id}, keep: true);
    _emit({item.e.scope, Ch.feed, Ch.chats, Ch.files});
  }

  /// Deletes a message only on this device.
  void deleteLocal(Item item) {
    _tombstones.add(item.id);
    db.deleteItem(item.id);
    _mem.remove(item.id);
    _emit({item.e.scope, Ch.chats, Ch.feed});
  }

  DateTime _lastTypingSent = DateTime(0);

  void _setTypingSelf(String scope, bool on) {
    if (!_settings.typingIndicators) return;
    if (on && DateTime.now().difference(_lastTypingSent).inSeconds < 3) return;
    _lastTypingSent = on ? DateTime.now() : DateTime(0);
    if (scope.startsWith('dm:')) {
      final peer = Scope.dmPeer(scope, me.id);
      if (peer == null) return;
      unawaited(
        _send(peer, {
          't': 'typing',
          'scope': scope,
          'on': on,
        }),
      );
    } else if (scope.startsWith('gdm:')) {
      final g = db.group(Scope.parts(scope)[1]);
      if (g != null) {
        unawaited(
          _groupSend(g, {'t': 'typing', 'scope': scope, 'a': me.id, 'on': on}),
        );
      }
    } else {
      final s = db.space(Scope.spaceOf(scope) ?? '');
      if (s != null) {
        unawaited(
          _spaceSend(s, {'t': 'typing', 'scope': scope, 'a': me.id, 'on': on}),
        );
      }
    }
  }

  void typing(String scope, bool on) => _setTypingSelf(scope, on);

  void markActivitySeen() {
    db.markActivitySeen();
    _emit({Ch.activity});
  }

  void clearActivity() {
    db.clearActivity();
    _emit({Ch.activity});
  }

  void notifyFiles() => _emit({Ch.files});

  void updateChat(String scope, Map<String, Object?> fields) {
    db.updateChat(scope, fields);
    _emit({Ch.chats, scope});
  }

  void clearChat(String scope) {
    db.deleteChat(scope);
    _mem.removeWhere((_, m) => m.item.e.scope == scope);
    _emit({Ch.chats, scope});
  }

  void markRead(String scope) {
    final c = db.chat(scope);
    final incoming = items(scope)
        .where((i) => i.author != me.id && i.e.kind == K.msg)
        .toList();
    final latest = incoming.map((i) => i.ts).maxOrNull;
    if (latest == null) return;
    final unread = incoming.where((i) => !db.wasMessageRead(i.id)).toList();
    if (unread.isEmpty) return;
    db.updateChat(scope, {
      'last_read': latest > (c['last_read'] as int? ?? 0)
          ? latest
          : c['last_read'],
    });
    db.transaction(() {
      for (final item in unread) {
        db.recordMessageRead(item.e);
        if (_settings.readReceipts) {
          db.enqueueOutbox(
            'seen:${item.id}',
            item.author,
            jsonEncode({
              't': 'seen',
              'scope': scope,
              'ids': [item.id],
              'ts': item.ts,
            }),
          );
        }
      }
    });
    unawaited(_flushOutbox());
    _emit({Ch.chats});
  }

  // ---------------------------------------------------------------------------
  // people

  Profile? profileOf(String id) {
    if (id == me.id) return myProfile;
    return _liveProfiles[id] ?? db.keptProfile(id);
  }

  Peer peerOf(String id) {
    final stored = db.peer(id);
    final profile = profileOf(id);
    if (stored == null) return Peer(id: id, profile: profile);
    return Peer(
      id: id,
      profile: profile,
      nickname: stored.nickname,
      lastSeen: isOnline(id) ? nowMs() : stored.lastSeen,
      iFollow: stored.iFollow,
      followsMe: stored.followsMe,
      blocked: stored.blocked,
      preserve: stored.preserve,
      addr: stored.addr,
    );
  }

  String nameOf(String id) => id == me.id ? 'You' : peerOf(id).name;

  List<Peer> people() => db.peers().map((p) => peerOf(p.id)).toList();

  Future<void> follow(String id, bool on) async {
    db.updatePeer(id, {'i_follow': on ? 1 : 0});
    if (on) {
      await _joinFeedTopic(id, [id]);
      await _send(id, {'t': 'follow', 'on': true});
      unawaited(query(id, Scope.feed(id)));
      unawaited(query(id, Scope.story(id)));
      unawaited(query(id, Scope.files(id)));
    } else {
      await _leaveFeedTopic(id);
      await _send(id, {'t': 'follow', 'on': false});
      if (db.peer(id)?.preserve ?? false) await setPreserve(id, false);
    }
    _emit({Ch.peers, Ch.feed, Ch.stories});
  }

  Future<void> block(String id, bool on) async {
    db.updatePeer(id, {'blocked': on ? 1 : 0, if (on) 'i_follow': 0});
    if (on) {
      _mem.removeWhere((_, m) => m.item.author == id);
      db.dropKept(id, '%');
      await _leaveFeedTopic(id);
    }
    _emit({Ch.peers, Ch.feed, Ch.chats, Ch.stories});
  }

  void setNickname(String id, String? name) {
    db.updatePeer(id, {'nickname': name});
    _emit({Ch.peers, Ch.chats});
  }

  // ---------------------------------------------------------------------------
  // tickets

  Future<String> contactTicket() async {
    final st = await net.status();
    // Keep QR small: node id + home relay is enough for iroh to dial.
    final j = {
      'i': me.id,
      'n': myProfile.name,
      if (st.relayUrl != null) 'r': st.relayUrl,
    };
    return 'mentos://u/${base64Url.encode(utf8.encode(jsonEncode(j))).replaceAll('=', '')}';
  }

  /// A just-added contact isn't a [_dialContacts] target yet, so a first dial
  /// that lands before either node is reachable would never be retried.
  Future<void> _reach(String peer) async {
    for (var i = 0; i < 5 && _running && !_held; i++) {
      if (_links.contains(peer)) return;
      await net.connect(peer).catchError((_) => false);
      await Future<void>.delayed(const Duration(seconds: 4));
    }
  }

  /// Accepts a contact ticket, a space invite or a bare 64-char key.
  /// Returns ('peer', id) or ('space', id).
  Future<(String, String)?> openTicket(String raw) async {
    final s = raw.trim();
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(s)) {
      if (s == me.id) return null;
      db.ensurePeer(s);
      unawaited(_reach(s));
      _emit({Ch.peers});
      return ('peer', s);
    }
    final m = RegExp(
      r'mentos://([us])/([A-Za-z0-9_\-]+)',
      caseSensitive: false,
    ).firstMatch(s);
    if (m == null) return null;
    final Map j;
    try {
      j = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(m.group(2)!))),
      ) as Map;
    } catch (_) {
      return null;
    }
    if (m.group(1) == 'u') {
      final id = j['i'];
      if (id is! String ||
          id == me.id ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) {
        return null;
      }
      final a = j['a'] is String ? j['a'] as String : null;
      final relay = j['r'] is String ? j['r'] as String : null;
      if (a != null) await net.addTicket(a);
      if (a == null && relay != null) await net.addTicket('$id|$relay');
      db.updatePeer(id, {'addr': ?(a ?? relay)});
      unawaited(_reach(id));
      _emit({Ch.peers});
      return ('peer', id);
    }
    final e = Envelope.fromWire(j['e']);
    if (e == null || e.kind != K.invite || !await e.verify()) return null;
    final id = e.body['id'] as String?;
    final owner = e.body['owner'] as String?;
    final key = e.body['key'] as String?;
    if (id == null || owner == null || key == null || key.isEmpty) return null;
    if (owner != e.author ||
        e.scope != Scope.spaceMeta(id) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(owner)) {
      return null;
    }
    final addrs = ((j['a'] as Map?) ?? {}).map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    );
    for (final a in addrs.values) {
      await net.addTicket(a);
    }
    await joinSpace(
      SpaceInfo(
        id: id,
        name: ((e.body['name'] as String?) ?? '').trim().isEmpty
            ? 'Space'
            : (e.body['name'] as String).trim(),
        owner: owner,
        key: key,
        channels: const [Channel('general', 'general')],
        forums: const [Channel('general', 'general')],
        joined: nowMs(),
      ),
      addrs.keys.toList(),
    );
    return ('space', id);
  }

  // ---------------------------------------------------------------------------
  // spaces

  List<SpaceInfo> spaces() =>
      db.spaces()..sort((a, b) => b.joined.compareTo(a.joined));
  SpaceInfo? space(String id) => db.space(id);

  Future<SpaceInfo> createSpace(String name, String about) async {
    final s = SpaceInfo(
      id: toHex(randomBytes(16)),
      name: name.trim(),
      about: about.trim(),
      owner: me.id,
      key: base64Encode(randomBytes(32)),
      channels: const [
        Channel('general', 'general'),
        Channel('random', 'random'),
      ],
      forums: const [Channel('general', 'general')],
      joined: nowMs(),
      preserve: true,
    );
    db.putSpace(s);
    await _joinSpaceTopic(s);
    await _publish(
      K.spaceMeta,
      Scope.spaceMeta(s.id),
      s.metaJson(),
      keep: true,
    );
    await _publish(K.member, Scope.spaceMeta(s.id), {
      'name': myProfile.name,
    }, keep: true);
    _emit({Ch.spaces});
    return db.space(s.id)!;
  }

  Future<void> joinSpace(SpaceInfo s, List<String> bootstrap) async {
    if (db.space(s.id) == null) db.putSpace(s);
    await _joinSpaceTopic(s, bootstrap);
    await _publish(K.member, Scope.spaceMeta(s.id), {
      'name': myProfile.name,
    }, keep: true);
    _emit({Ch.spaces});
    unawaited(
      Future.delayed(const Duration(seconds: 2), () => refreshSpace(s.id)),
    );
  }

  /// Asks members for history of [scope] (or the whole space).
  Future<void> refreshSpace(String spaceId, {String? scope}) async {
    final s = db.space(spaceId);
    if (s == null) return;
    final scopes = scope != null
        ? [scope]
        : [
            Scope.spaceMeta(spaceId),
            Scope.spaceFeed(spaceId),
            ...s.channels.map((c) => Scope.channel(spaceId, c.id)),
            ...s.forums.map((c) => Scope.forum(spaceId, c.id)),
          ];
    for (final sc in scopes) {
      await _spaceSend(s, {'t': 'q', 'scope': sc, 'a': me.id, 'since': 0});
    }
    for (final peer in {s.owner, ..._knownMembers(spaceId)}..remove(me.id)) {
      if (_links.contains(peer)) {
        for (final sc in scopes) {
          unawaited(query(peer, sc));
        }
      }
    }
  }

  Future<String> spaceInvite(String spaceId) async {
    final s = db.space(spaceId)!;
    if (s.owner != me.id) {
      throw StateError('Only the owner can share a space invite');
    }
    final addr = await net.ticket();
    final signed = await Envelope.create(
      me,
      kind: K.invite,
      scope: Scope.spaceMeta(s.id),
      body: {'id': s.id, 'owner': me.id, 'key': s.key, 'name': s.name},
    );
    final j = {
      'e': signed.toWire(),
      'a': {if (addr.isNotEmpty) me.id: addr},
    };
    return 'mentos://s/${base64Url.encode(utf8.encode(jsonEncode(j))).replaceAll('=', '')}';
  }

  Future<void> updateSpace(
    String spaceId,
    SpaceInfo Function(SpaceInfo) change,
  ) async {
    final s = db.space(spaceId);
    if (s == null) return;
    final next = change(s);
    db.putSpace(next);
    final newlyBanned = next.roles.entries
        .where((e) => e.value == Role.banned && s.roles[e.key] != Role.banned)
        .map((e) => e.key)
        .toList();
    if (newlyBanned.isNotEmpty && s.owner == me.id) {
      await _rotateSpaceKey(db.space(spaceId)!);
    }
    final role = next.roleOf(me.id);
    final metaChanged = jsonEncode(next.metaJson()) != jsonEncode(s.metaJson());
    if (metaChanged && role == Role.owner) {
      await _publish(
        K.spaceMeta,
        Scope.spaceMeta(spaceId),
        next.metaJson(),
        keep: true,
      );
    }
    if (s.preserve != next.preserve) {
      if (next.preserve) {
        _promote(
          (i) =>
              Scope.spaceOf(i.e.scope) == spaceId && i.e.keep && next.archive,
        );
      } else {
        for (final i
            in db.itemsByScopePrefix('chan:$spaceId:').where((i) => !i.owned)) {
          db.deleteItem(i.id);
        }
        for (final i
            in db.itemsByScopePrefix('sfeed:$spaceId').where((i) => !i.owned)) {
          db.deleteItem(i.id);
        }
      }
    }
    _emit({Ch.spaces, Ch.feed});
  }

  Future<void> leaveSpace(String spaceId) async {
    final s = db.space(spaceId);
    if (s == null) return;
    await _publish(K.member, Scope.spaceMeta(spaceId), {
      'left': true,
    }, keep: true);
    await net.leave(_topicFor('mentos-space:$spaceId'));
    _spaceTopics.remove(_topicFor('mentos-space:$spaceId'));
    db.deleteSpace(spaceId);
    for (final i in db.itemsByScopePrefix('chan:$spaceId:')) {
      db.deleteItem(i.id);
    }
    _mem.removeWhere((_, m) => Scope.spaceOf(m.item.e.scope) == spaceId);
    _emit({Ch.spaces, Ch.feed});
  }

  /// Members announced in the space, with their latest state.
  List<({String id, Role role, bool online})> members(String spaceId) {
    final s = db.space(spaceId);
    if (s == null) return const [];
    final announced = <String, bool>{};
    final all = [
      ...db.itemsInScope(Scope.spaceMeta(spaceId)),
      ..._memIn(Scope.spaceMeta(spaceId)),
    ]..sort((a, b) => a.ts.compareTo(b.ts));
    for (final i in all.where((i) => i.e.kind == K.member)) {
      announced[i.author] = i.body['left'] != true;
    }
    announced[s.owner] = true;
    announced[me.id] = true;
    final out = announced.entries
        .where((e) => e.value && s.roleOf(e.key) != Role.banned)
        .map((e) => (id: e.key, role: s.roleOf(e.key), online: isOnline(e.key)))
        .toList();
    out.sort((a, b) {
      final r = a.role.index.compareTo(b.role.index);
      if (r != 0) return r;
      if (a.online != b.online) return a.online ? -1 : 1;
      return nameOf(a.id).compareTo(nameOf(b.id));
    });
    return out;
  }

  // ---------------------------------------------------------------------------
  // read models

  Iterable<Item> _memIn(String scope) =>
      _mem.values.where((m) => m.item.e.scope == scope).map((m) => m.item);

  /// All items in a scope across tiers, oldest first.
  List<Item> items(String scope) {
    final byId = <String, Item>{
      for (final i in db.itemsInScope(scope)) i.id: i,
    };
    for (final i in _memIn(scope)) {
      byId.putIfAbsent(i.id, () => i);
    }
    return byId.values
        .where((i) => !_tombstones.contains(i.id))
        .sorted((a, b) => a.ts.compareTo(b.ts));
  }

  List<Item> _mutationsFor(Iterable<String> targets) {
    final t = targets.toSet();
    final out = <String, Item>{
      for (final i in db.mutationsFor(t.toList())) i.id: i,
    };
    for (final m in _mem.values) {
      final tg = m.item.e.target;
      if (tg != null && t.contains(tg)) {
        out.putIfAbsent(m.item.id, () => m.item);
      }
    }
    return out.values.toList();
  }

  bool _canModerate(String actor, Item target) {
    final sid = Scope.spaceOf(target.e.scope);
    if (sid == null) return false;
    final s = db.space(sid);
    return s != null && s.roleOf(actor).index <= Role.mod.index;
  }

  List<PostView> feed({
    String? author,
    String? spaceId,
    String? boardId,
    bool bookmarksOnly = false,
    int limit = 300,
  }) {
    final scopes = <String>{};
    if (boardId != null && spaceId != null) {
      scopes.add(Scope.forum(spaceId, boardId));
    } else if (spaceId != null) {
      scopes.add(Scope.spaceFeed(spaceId));
    } else if (author != null) {
      scopes.add(Scope.feed(author));
    } else {
      scopes.add(Scope.feed(me.id));
      for (final p in db.peers().where((p) => !p.blocked)) {
        final known = p.iFollow || p.preserve;
        final open =
            !_settings.hideStrangers &&
            (profileOf(p.id)?.discoverable ?? false);
        if (known || open) scopes.add(Scope.feed(p.id));
      }
      if (!_settings.hideStrangers) {
        for (final id in _links) {
          scopes.add(Scope.feed(id));
        }
      }
    }
    final byId = <String, Item>{
      for (final i in db.itemsInScopes(scopes.toList(), limit: limit)) i.id: i,
    };
    for (final m in _mem.values) {
      if (scopes.contains(m.item.e.scope)) {
        byId.putIfAbsent(m.item.id, () => m.item);
      }
    }
    var posts = byId.values
        .where((i) => i.e.kind == K.post && !_tombstones.contains(i.id))
        .toList();
    final marks = db.bookmarkIds();
    if (bookmarksOnly) {
      posts = posts.where((p) => marks.contains(p.id)).toList();
    }
    posts.sort((a, b) => b.ts.compareTo(a.ts));
    return _postViews(posts.take(limit).toList(), marks);
  }

  List<PostView> bookmarked() {
    final marks = db.bookmarks();
    final out = <Item>[];
    for (final b in marks) {
      final i = db.item(b.id) ?? _mem[b.id]?.item;
      if (i != null && !_tombstones.contains(i.id)) out.add(i);
    }
    return _postViews(out, marks.map((m) => m.id).toSet());
  }

  List<int> hiddenBookmarks() => [
    db
        .bookmarks()
        .where((b) => db.item(b.id) == null && _mem[b.id] == null)
        .length,
  ];

  List<PostView> _postViews(List<Item> posts, Set<String> marks) {
    if (posts.isEmpty) return const [];
    final targets = {for (final p in posts) p.id: p};
    final f = fold(
      _mutationsFor(targets.keys),
      targets,
      canModerate: _canModerate,
    );
    final commentCounts = <String, int>{};
    for (final p in posts) {
      commentCounts[p.id] = items(Scope.post(p.author, p.id))
          .where((i) => i.e.kind == K.comment && !f.deleted.contains(i.id))
          .length;
    }
    return posts.where((p) => !f.deleted.contains(p.id)).map((p) {
      final likes = f.likes[p.id] ?? const <String>{};
      final ed = f.edited[p.id];
      return PostView(
        item: p,
        text: ed?.text ?? (p.body['text'] as String? ?? ''),
        media: MediaRef.listFrom(p.body['media']),
        likes: likes.length,
        liked: likes.contains(me.id),
        comments: commentCounts[p.id] ?? 0,
        bookmarked: marks.contains(p.id),
        edited: ed != null,
        poll: pollState(p, f, me.id),
        repost: p.body['repost'] is Map
            ? Map<String, dynamic>.from(p.body['repost'] as Map)
            : null,
        spaceId: Scope.spaceOf(p.e.scope),
        title: p.body['title'] is String ? p.body['title'] as String : '',
        boardId: p.body['board'] is String ? p.body['board'] as String : null,
        ai: p.body['ai'] == true,
        nsfw: p.body['nsfw'] == true,
        views: (f.views[p.id] ?? const <String>{}).length,
        viewers: p.author == me.id ? (f.views[p.id] ?? const <String>{}).toList() : const [],
        channelId:
            (p.body['channel'] is String ? p.body['channel'] as String : null) ??
            (const {'bcast', 'chan'}.contains(Scope.type(p.e.scope))
                ? Scope.parts(p.e.scope).last
                : null),
      );
    }).toList();
  }

  PostView? post(String id) {
    final i = db.item(id) ?? _mem[id]?.item;
    if (i == null ||
        (i.e.kind != K.post && i.e.kind != K.host) ||
        _tombstones.contains(id)) {
      return null;
    }
    if (i.e.kind == K.host) return null;
    return _postViews([i], db.bookmarkIds()).firstOrNull;
  }

  /// False when the post is in a personal channel whose owner turned
  /// comments off.
  bool commentsOpen(PostView post) {
    final owner = Scope.bcastOwner(post.item.e.scope);
    final chan = post.channelId;
    if (owner == null || chan == null) return true;
    final c = broadcasts(owner: owner).where((b) => b.id == chan).firstOrNull;
    return c == null || channelState(c).comments;
  }

  List<CommentView> comments(PostView post) {
    if (!commentsOpen(post)) return const [];
    final all = items(post.scope).where((i) => i.e.kind == K.comment).toList();
    final targets = {for (final c in all) c.id: c};
    final f = fold(
      _mutationsFor(targets.keys),
      targets,
      canModerate: _canModerate,
    );
    return all.where((c) => !f.deleted.contains(c.id)).map((c) {
      final likes = f.likes[c.id] ?? const <String>{};
      final ed = f.edited[c.id];
      return CommentView(
        item: c,
        text: ed?.text ?? (c.body['text'] as String? ?? ''),
        likes: likes.length,
        liked: likes.contains(me.id),
        edited: ed != null,
        replyTo: c.body['replyTo'] is String ? c.body['replyTo'] as String : null,
      );
    }).toList();
  }

  void setBookmark(PostView p, bool on) {
    db.setBookmark(p.item.e, on);
    _emit({Ch.bookmarks, Ch.feed, 'item:${p.id}'});
  }

  List<MessageView> messages(String scope) {
    final tracked = db.deliveriesInScope(scope);
    final all = items(scope);
    final base = all.where((i) => i.e.kind == K.msg).toList();
    final targets = {for (final m in base) m.id: m};
    final muts = all.where((i) => K.mutations.contains(i.e.kind));
    final f = fold(muts, targets, canModerate: _canModerate);
    final peer = Scope.dmPeer(scope, me.id);
    final rc = peer == null ? null : db.receipt(scope, peer);
    final pending = db.outboxIds();
    final failed = db.failedOutbox();
    final views = <String, MessageView>{};
    final out = <MessageView>[];
    for (final m in base) {
      if (f.deleted.contains(m.id)) continue;
      final mine = m.author == me.id;
      var d = Delivery.sent;
      final recipients = tracked[m.id] ?? const <RecipientDelivery>[];
      if (mine && recipients.isNotEmpty) {
        d = aggregateDelivery(recipients);
      } else if (mine && failed.contains(m.id)) {
        d = Delivery.failed;
      } else if (mine && pending.contains(m.id)) {
        d = Delivery.sending;
      } else if (mine && rc != null) {
        if (rc.read >= m.ts) {
          d = Delivery.read;
        } else if (rc.delivered >= m.ts) {
          d = Delivery.delivered;
        }
      }
      final ed = f.edited[m.id];
      final replyId = m.body['replyTo'] is String
          ? m.body['replyTo'] as String
          : null;
      final rawText = m.body['text'];
      final v = MessageView(
        item: m,
        text: ed?.text ?? (rawText is String ? rawText : ''),
        media: MediaRef.listFrom(m.body['media']),
        reactions: f.reactions[m.id] ?? const {},
        edited: ed != null,
        mine: mine,
        replyTo: replyId == null ? null : views[replyId],
        delivery: d,
        recipients: recipients,
        poll: pollState(m, f, me.id),
        expires: m.e.expires,
        forwarded: m.body['fwd'] == true,
        nsfw: m.body['nsfw'] == true,
      );
      views[m.id] = v;
      out.add(v);
    }
    return out;
  }

  Set<String> typingIn(String scope) =>
      (_typing[scope] ?? const {}).keys.toSet();

  List<ChatSummary> chats() {
    final out = <ChatSummary>[];
    final scopes = <String>{
      ...db.dmScopes(),
      ..._mem.values
          .map((m) => m.item.e.scope)
          .where((s) => s.startsWith('dm:')),
    };
    for (final g in db.groups()) {
      scopes.add(Scope.gdm(g.id));
    }
    for (final scope in scopes) {
      final msgs = messages(scope);
      final c = db.chat(scope);
      final lastRead = c['last_read'] as int? ?? 0;
      if (scope.startsWith('gdm:')) {
        final g = db.group(Scope.parts(scope)[1]);
        if (g == null) continue;
        final online =
            g.members.where(isOnline).length + (isOnline(g.owner) ? 1 : 0);
        out.add(
          ChatSummary(
            scope: scope,
            peer: g.id,
            last: msgs.lastOrNull,
            unread: msgs.where((m) => !m.mine && m.ts > lastRead).length,
            pinned: c['pinned'] == 1,
            muted: c['muted'] == 1,
            archived: c['archived'] == 1,
            online: online > 0,
            typing: typingIn(scope).isNotEmpty,
            syncMine: null,
            syncTheirs: null,
            pendingOffer: false,
            group: true,
            title: g.name,
            memberCount: ({g.owner, ...g.members}).length,
            membersOnline: online,
          ),
        );
        continue;
      }
      final peer = Scope.dmPeer(scope, me.id);
      if (peer == null || (db.peer(peer)?.blocked ?? false)) continue;
      final sync = syncState(scope);
      out.add(
        ChatSummary(
          scope: scope,
          peer: peer,
          last: msgs.lastOrNull,
          unread: msgs.where((m) => !m.mine && m.ts > lastRead).length,
          pinned: c['pinned'] == 1,
          muted: c['muted'] == 1,
          archived: c['archived'] == 1,
          online: isOnline(peer),
          typing: typingIn(scope).contains(peer),
          syncMine: sync.mine,
          syncTheirs: sync.theirs,
          pendingOffer: sync.theirsOffered,
        ),
      );
    }
    out.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.sortTs.compareTo(a.sortTs);
    });
    return out;
  }

  int unreadChats() =>
      chats().where((c) => c.unread > 0 && !c.muted && !c.archived).length;

  List<StoryGroup> stories() {
    final authors = <String>{
      me.id,
      ..._links,
      ...db
          .peers()
          .where(
            (p) =>
                !p.blocked &&
                (p.iFollow ||
                    p.preserve ||
                    p.followsMe ||
                    !_settings.hideStrangers),
          )
          .map((p) => p.id),
      ...db.dmScopes().map((s) => Scope.dmPeer(s, me.id)).whereType<String>(),
    };
    final seen = _storySeen();
    final out = <StoryGroup>[];
    final now = nowMs();
    for (final a in authors) {
      final list = items(Scope.story(a))
          .where((i) => i.e.kind == K.story && (i.e.expires ?? 0) > now)
          .toList();
      if (list.isEmpty) continue;
      out.add(StoryGroup(a, list, list.every((s) => seen.contains(s.id))));
    }
    out.sort((a, b) {
      if (a.author == me.id) return -1;
      if (b.author == me.id) return 1;
      if (a.allSeen != b.allSeen) return a.allSeen ? 1 : -1;
      return b.stories.last.ts.compareTo(a.stories.last.ts);
    });
    return out;
  }

  Set<String> _storySeen() {
    try {
      final raw = jsonDecode(db.getKv('seenStories') ?? '[]');
      if (raw is! List) return {};
      return raw.whereType<String>().toSet();
    } catch (_) {
      return {};
    }
  }

  void markStorySeen(String id) {
    final seen = _storySeen().toList();
    if (seen.contains(id)) return;
    seen.add(id);
    if (seen.length > 500) seen.removeRange(0, seen.length - 500);
    db.setKv('seenStories', jsonEncode(seen));
    _emit({Ch.stories});
  }

  /// Peers worth asking for a blob: the author, whoever relayed the item,
  /// and a few connected peers.
  List<String> sourcesFor(Item item) => [
    item.author,
    ...?_mem[item.id]?.sources,
    ..._links.take(4),
  ].where((p) => p != me.id).toList();

  Future<File?> openMedia(MediaRef ref, Item item) => media.open(
    ref,
    sources: sourcesFor(item),
    origin: item.owned ? 'mine' : (item.kept ? 'kept' : 'cache'),
    scope: item.e.scope,
  );

  // ---------------------------------------------------------------------------
  // network page

  Future<NetStatus> netStatus() async {
    try {
      return await net.status();
    } catch (_) {
      return NetStatus(nodeId: me.id, running: false, engine: 'offline');
    }
  }

  ({int owned, int kept, int live}) tierCounts() {
    final c = db.storageCounts();
    return (owned: c['owned']!, kept: c['kept']!, live: _mem.length);
  }

  /// Items held only in memory: visible while their author is reachable,
  /// never written to disk.
  List<Item> liveItems() => [for (final m in _mem.values) m.item];

  int liveItemsFrom(String peer) =>
      _mem.values.where((m) => m.item.author == peer).length;
  Map<String, int> keptByAuthor() => db.keptByAuthor();

  /// Who keeps my data, by scope.
  List<Grant> custodians() =>
      db.grants().where((g) => g.dir == GrantDir.out).toList();

  /// Whose data I keep, by scope.
  List<Grant> custody() =>
      db.grants().where((g) => g.dir == GrantDir.inbound).toList();

  Map<String, Set<String>> get neighbors => _neighbors;

  /// Gossip topic id -> what it carries, for the explorers.
  Map<String, String> topicLabels() => {
        for (final e in _spaceTopics.entries) e.key: 'space · ${db.space(e.value)?.name ?? shortId(e.value)}',
        for (final e in _feedTopics.entries) e.key: 'posts · ${nameOf(e.value)}',
        for (final e in _groupTopics.entries) e.key: 'group · ${db.group(e.value)?.name ?? shortId(e.value)}',
      };

  /// When [peer] was last heard from on any path, ms since epoch.
  int lastHeardFrom(String peer) => _lastHeard[peer] ?? 0;
  int get topicCount =>
      _spaceTopics.length + _feedTopics.length + _groupTopics.length;

  List<FileTransfer> transfers() =>
      _xfers.values.toList()..sort((a, b) => b.started.compareTo(a.started));

  List<Item> hosted(String author) =>
      items(Scope.files(author))
          .where((i) => i.e.kind == K.host && !_tombstones.contains(i.id))
          .toList()
          .reversed
          .toList();

  List<Item> searchHosted(String q) {
    final needle = q.trim().toLowerCase();
    final authors = <String>{me.id, ...db.peers().map((p) => p.id)};
    final out = <Item>[];
    for (final a in authors) {
      for (final i in hosted(a)) {
        final refs = MediaRef.listFrom(i.body['media']);
        final name = refs.firstOrNull?.name ?? '';
        final meta = HostMeta.of(i);
        if (needle.isEmpty ||
            name.toLowerCase().contains(needle) ||
            meta.note.toLowerCase().contains(needle) ||
            meta.folder.toLowerCase().contains(needle) ||
            meta.tags.any((t) => t.contains(needle.replaceFirst('#', '')))) {
          out.add(i);
        }
      }
    }
    return out;
  }

  Future<Item> hostFile(
    MediaRef ref, {
    String note = '',
    String folder = '',
    List<String> tags = const [],
    bool keep = true,
  }) async {
    final cleanTags = HostMeta.cleanTags(tags);
    final e = await _publish(K.host, Scope.files(me.id), {
      'media': [ref.toJson()],
      if (note.trim().isNotEmpty) 'note': note.trim(),
      if (folder.trim().isNotEmpty) 'folder': folder.trim(),
      if (cleanTags.isNotEmpty) 'tags': cleanTags,
    }, keep: keep);
    _emit({Ch.files, Scope.files(me.id)});
    return Item(e, owned: true, kept: false);
  }

  Future<void> refreshHosted(String author) async {
    if (author != me.id) await query(author, Scope.files(author));
  }

  Future<File?> takeHosted(
    Item item, {
    void Function(int done, int total)? onProgress,
  }) async {
    final refs = MediaRef.listFrom(item.body['media']);
    if (refs.isEmpty) return null;
    final f = await media.open(
      refs.first,
      sources: sourcesFor(item),
      origin: 'cache',
      scope: item.e.scope,
      onProgress: onProgress,
    );
    // A completed download counts once for the host, like a view.
    if (f != null) unawaited(recordView(item));
    return f;
  }

  /// How many people downloaded a hosted file, as far as this device knows.
  /// Exact for your own files.
  int hostDownloads(Item item) => (fold(_mutationsFor([item.id]), {item.id: item}).views[item.id] ?? const {}).length;

  Future<GroupInfo> createGroup(String name, List<String> memberIds) async {
    final g = GroupInfo(
      id: toHex(randomBytes(16)),
      name: name.trim().isEmpty ? 'Group' : name.trim(),
      owner: me.id,
      key: base64Encode(randomBytes(32)),
      members: [me.id],
      joined: nowMs(),
      preserve: true,
    );
    db.putGroup(g);
    db.ensureChat(Scope.gdm(g.id));
    await _joinGroupTopic(g);
    await _publish(K.group, Scope.gmeta(g.id), g.metaJson(), keep: true);
    await inviteToGroup(g.id, memberIds);
    _emit({Ch.groups, Ch.chats});
    return g;
  }

  Future<void> leaveGroup(String id) async {
    final g = db.group(id);
    if (g == null) return;
    // A key minted here would still be known to the person walking out.
    // The owner rotates when someone else leaves. When the owner leaves,
    // the next member mints the replacement.
    await _publish(K.group, Scope.gmeta(id), {
      ...g.metaJson(),
      'members': g.members.where((m) => m != me.id).toList(),
    }, keep: true);
    await net.leave(_topicFor('mentos-gdm:$id'));
    _groupTopics.remove(_topicFor('mentos-gdm:$id'));
    db.deleteGroup(id);
    clearChat(Scope.gdm(id));
    _emit({Ch.groups, Ch.chats});
  }

  Future<void> updateGroup(
    String id,
    GroupInfo Function(GroupInfo) change,
  ) async {
    final g = db.group(id);
    if (g == null) return;
    final next = change(g);
    if (g.owner != me.id) {
      final onlyLeft =
          next.owner == g.owner &&
          next.key == g.key &&
          next.roles.length == g.roles.length &&
          g.members.toSet().difference(next.members.toSet()).length == 1 &&
          g.members.toSet().difference(next.members.toSet()).contains(me.id);
      if (!onlyLeft) return;
    }
    if (next.owner != g.owner &&
        g.owner == me.id &&
        !next.members.contains(next.owner) &&
        next.owner != me.id) {
      return;
    }
    db.putGroup(next);
    final removed = g.members.toSet().difference(next.members.toSet());
    if (g.name != next.name ||
        g.members.toSet() != next.members.toSet() ||
        g.roles.length != next.roles.length) {
      // Sent with the key members already have. Rotation happens after this
      // returns, and the fan-out closure keeps this copy of the group.
      await _publish(K.group, Scope.gmeta(id), next.metaJson(), keep: true);
    }
    if (g.owner == me.id && removed.isNotEmpty && next.members.contains(me.id)) {
      await _rotateGroupKey(db.group(id) ?? next);
    }
    _emit({Ch.groups, Ch.chats});
  }

  GroupInfo? group(String id) => db.group(id);

  Future<FileTransfer> offerTransfer(String peer, MediaRef ref) async {
    final x = FileTransfer(
      id: newId(),
      peer: peer,
      media: ref,
      dir: XferDir.out,
      state: XferState.offer,
      started: nowMs(),
      done: 0,
    );
    _xfers[x.id] = x;
    final ok = await _send(peer, {
      't': 'xfer',
      'op': 'offer',
      'id': x.id,
      'media': ref.toJson(),
    });
    if (!ok && x.state == XferState.offer) {
      x.state = XferState.failed;
      x.error = 'could not reach them';
    }
    _emit({Ch.xfers});
    return x;
  }

  Future<void> respondTransfer(String id, bool accept) async {
    final x = _xfers[id];
    if (x == null || x.dir != XferDir.inbound) return;
    if (!accept) {
      x.state = XferState.declined;
      await _send(x.peer, {'t': 'xfer', 'op': 'decline', 'id': id});
      _emit({Ch.xfers});
      return;
    }
    x.state = XferState.queued;
    x.error = null;
    _emit({Ch.xfers});
    final ok = await _send(x.peer, {'t': 'xfer', 'op': 'accept', 'id': id});
    if (!ok) {
      if (x.state == XferState.queued) {
        x.state = XferState.failed;
        x.error = 'could not reach them';
        _emit({Ch.xfers});
      }
      return;
    }
    _pumpInbound();
  }

  /// Starts queued downloads while fewer than the configured number run.
  void _pumpInbound() {
    final limit = _settings.xferParallel.clamp(1, 8);
    var running = _xfers.values.where((x) => x.dir == XferDir.inbound && x.state == XferState.active).length;
    final waiting = _xfers.values.where((x) => x.dir == XferDir.inbound && x.state == XferState.queued).toList()
      ..sort((a, b) => a.started.compareTo(b.started));
    for (final x in waiting) {
      if (running >= limit) break;
      running++;
      x.state = XferState.active;
      unawaited(_runInbound(x).whenComplete(_pumpInbound));
    }
    _emit({Ch.xfers});
  }

  /// Tries a failed or cancelled transfer again: downloads restart, and an
  /// offer that never reached them is sent again.
  Future<void> retryTransfer(String id) async {
    final x = _xfers[id];
    if (x == null || !{XferState.failed, XferState.cancelled}.contains(x.state)) return;
    x.error = null;
    x.done = 0;
    if (x.dir == XferDir.inbound) {
      x.state = XferState.offer;
      await respondTransfer(id, true);
      return;
    }
    x.state = XferState.offer;
    _emit({Ch.xfers});
    final ok = await _send(x.peer, {'t': 'xfer', 'op': 'offer', 'id': x.id, 'media': x.media.toJson()});
    if (!ok && x.state == XferState.offer) {
      x.state = XferState.failed;
      x.error = 'could not reach them';
    }
    _emit({Ch.xfers});
  }

  /// Forgets finished, failed, declined and cancelled transfers.
  void clearFinishedTransfers() {
    _xfers.removeWhere((_, x) => !x.moving);
    _emit({Ch.xfers});
  }

  Future<void> cancelTransfer(String id) async {
    final x = _xfers[id];
    if (x == null) return;
    x.state = XferState.cancelled;
    x.error = 'cancelled';
    dismissAlert('xfer:$id');
    await net.cancelFetch(x.media.hash);
    await _send(x.peer, {'t': 'xfer', 'op': 'cancel', 'id': id});
    _emit({Ch.xfers, Ch.alerts});
  }

  Future<void> _onXfer(String from, Map<String, dynamic> m) async {
    final op = m['op'] as String? ?? '';
    final id = m['id'] as String? ?? '';
    switch (op) {
      case 'offer':
        final media = MediaRef.fromJson(m['media']);
        if (media == null || id.isEmpty || id.length > 80) return;
        if (db.peer(from)?.blocked ?? false) return;
        // A re-sent offer for a transfer already moving here is ignored.
        final prior = _xfers[id];
        if (prior != null && (prior.peer != from || prior.moving)) return;
        _xfers[id] = FileTransfer(
          id: id,
          peer: from,
          media: media,
          dir: XferDir.inbound,
          state: XferState.offer,
          started: nowMs(),
        );
        db.addActivity(
          Activity(
            id: 'xfer:$id',
            kind: 'xfer',
            actor: from,
            text: media.name,
            ts: nowMs(),
          ),
        );
        final auto = _settings.xferAutoAccept &&
            (db.peer(from)?.iFollow ?? false) &&
            media.size <= _settings.xferAutoMaxMb * 1024 * 1024;
        if (auto) {
          _emit({Ch.xfers, Ch.activity});
          unawaited(respondTransfer(id, true));
          return;
        }
        pushAlert(
          Alert(
            id: 'xfer:$id',
            kind: 'xfer',
            title: '${nameOf(from)} is sending a file',
            body: media.name,
            route: '/transfer/$from',
          ),
        );
        _emit({Ch.xfers, Ch.activity});
      case 'accept':
        final x = _xfers[id];
        if (x == null || x.peer != from || x.dir != XferDir.out) return;
        if (x.state == XferState.cancelled || x.state == XferState.declined) return;
        x.state = XferState.active;
        _emit({Ch.xfers});
      case 'prog':
        final x = _xfers[id];
        if (x == null || x.peer != from) return;
        if (x.state == XferState.cancelled || x.state == XferState.declined) return;
        x.bump((m['done'] as num?)?.toInt() ?? x.done);
        _peerBps[x.peer] = x.bps;
        if (x.done >= x.total && x.total > 0) x.state = XferState.done;
        _emit({Ch.xfers, Ch.alerts});
      case 'done':
        final x = _xfers[id];
        if (x == null || x.peer != from) return;
        if (x.state == XferState.cancelled || x.state == XferState.declined) return;
        x.done = x.total;
        x.state = XferState.done;
        _emit({Ch.xfers});
      case 'fail':
        final x = _xfers[id];
        if (x == null || x.peer != from) return;
        if (x.state == XferState.cancelled || x.state == XferState.done) return;
        x.state = XferState.failed;
        x.error = (m['error'] as String?) ?? 'failed';
        _emit({Ch.xfers});
      case 'decline' || 'cancel':
        final x = _xfers[id];
        if (x == null || x.peer != from) return;
        x.state = op == 'decline' ? XferState.declined : XferState.cancelled;
        x.error = op;
        dismissAlert('xfer:$id');
        _emit({Ch.xfers, Ch.alerts});
    }
  }

  Future<void> _runInbound(FileTransfer x) async {
    try {
      final file = await media.open(
        x.media,
        sources: [x.peer],
        origin: 'cache',
        onProgress: (done, total) {
          if (x.state == XferState.cancelled) return;
          x.bump(done);
          _peerBps[x.peer] = x.bps;
          _emit({Ch.xfers, Ch.alerts});
          unawaited(
            _send(x.peer, {
              't': 'xfer',
              'op': 'prog',
              'id': x.id,
              'done': done,
              'total': total,
            }),
          );
        },
      );
      if (x.state != XferState.cancelled) {
        if (file == null) {
          x.state = XferState.failed;
          x.error = 'unreachable';
          await _send(x.peer, {'t': 'xfer', 'op': 'fail', 'id': x.id, 'error': x.error});
        } else {
          x.done = x.total;
          x.state = XferState.done;
          await _send(x.peer, {'t': 'xfer', 'op': 'done', 'id': x.id});
        }
      }
    } catch (e) {
      if (x.state != XferState.cancelled) {
        x.state = XferState.failed;
        x.error = '$e';
        await _send(x.peer, {'t': 'xfer', 'op': 'fail', 'id': x.id, 'error': x.error});
      }
    }
    if (x.state == XferState.cancelled &&
        !db.referencedHashes().contains(x.media.hash)) {
      await media.deleteBlob(x.media.hash);
    }
    dismissAlert('xfer:${x.id}');
    _emit({Ch.xfers, Ch.files, Ch.alerts});
  }

  List<Alert> alerts() => _alerts.values.toList();
  void dismissAlert(String id) {
    if (_alerts.remove(id) != null) _emit({Ch.alerts});
  }

  void pushAlert(Alert a) => _notify(
    id: a.id,
    title: a.title,
    body: a.body,
    route: a.route,
    kind: a.kind,
    scope: a.scope,
    progress: a.progress,
    cancelId: a.cancelId,
  );

  /// Banners are only for a file someone is sending you. Follows, messages,
  /// likes and invites stay in Activity and do not cover the screen.
  void _notify({
    required String id,
    required String title,
    required String body,
    String? route,
    String kind = 'note',
    String? scope,
    double? progress,
    String? cancelId,
    String? category,
    int? at,
  }) {
    _notes.add(OsNote(
      id: id,
      at: at ?? nowMs(),
      category: category ?? _categoryOf(id, kind),
      title: title,
      body: body,
      route: route,
      scope: scope,
    ));
    if (kind != 'xfer') return;
    if (!_settings.systemNotify) return;
    if (scope != null && db.chat(scope)['muted'] == 1) return;
    if (scope != null) {
      final spaceId = Scope.spaceOf(scope);
      if (spaceId != null && (db.space(spaceId)?.muted ?? false)) return;
    }
    _alerts[id] = Alert(
      id: id,
      kind: kind,
      title: title,
      body: body,
      route: route,
      scope: scope,
      progress: progress,
      cancelId: cancelId,
    );
    _emit({Ch.alerts});
  }

  static String _categoryOf(String id, String kind) {
    if (kind == 'xfer' || kind == 'invite') return kind;
    final prefix = id.split(':').first;
    return switch (prefix) {
      'follow' => 'follow',
      'like' => 'like',
      'act' => 'reply',
      'sync' => 'invite',
      'ginvite' => 'invite',
      _ => 'other',
    };
  }

  /// True when [text] names this person with an @, by display name or alias.
  bool mentionsMe(String text) {
    if (!text.contains('@')) return false;
    final lower = text.toLowerCase();
    final names = {myProfile.name.trim().toLowerCase(), alias(me.id)}..remove('');
    return names.any((n) => lower.contains('@$n') || lower.contains('@${n.replaceAll(' ', '')}'));
  }

  int peerBps(String id) => _peerBps[id] ?? 0;

  List<Job> jobs() => _jobs.values.toList();

  Future<Bcast> createBroadcast(String name, {String about = ''}) async {
    final e = await _publish(K.chan, Scope.feed(me.id), {
      'name': name.trim().isEmpty ? 'Channel' : name.trim(),
      'about': about.trim(),
    }, keep: true);
    _emit({Ch.channels, Ch.chats, Ch.feed});
    return Bcast(id: e.id, owner: me.id, name: name, about: about);
  }

  List<Bcast> broadcasts({String? owner}) {
    final authors = owner != null
        ? {owner}
        : {
            me.id,
            ...db
                .peers()
                .where((p) => p.iFollow && !p.blocked)
                .map((p) => p.id),
          };
    final out = <Bcast>[];
    for (final a in authors) {
      for (final i in items(Scope.feed(a)).where((i) => i.e.kind == K.chan)) {
        final b = Bcast.fromItem(i);
        if (b != null) out.add(b);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // channels

  Set<String> _chanSubs() {
    try {
      final raw = db.getKv('chansubs');
      return raw == null ? <String>{} : {for (final x in jsonDecode(raw) as List) if (x is String) x};
    } catch (_) {
      return <String>{};
    }
  }

  /// Your own channels count as subscribed.
  bool isSubscribed(String owner, String channelId) => owner == me.id || _chanSubs().contains('$owner/$channelId');

  /// Subscribing follows the owner (their posts travel on their feed topic)
  /// and sends them a signed subscription they can count.
  Future<void> subscribe(Bcast c, bool on) async {
    final subs = _chanSubs();
    on ? subs.add('${c.owner}/${c.id}') : subs.remove('${c.owner}/${c.id}');
    db.setKv('chansubs', jsonEncode(subs.toList()));
    if (on && !(db.peer(c.owner)?.iFollow ?? false)) await follow(c.owner, true);
    await _publish(K.like, Scope.post(c.owner, c.id), {'target': c.id, 'on': on, 'sub': true}, keep: true);
    _emit({Ch.channels, Ch.chats});
  }

  /// People whose latest subscription to [c] is on. Exact for your own
  /// channels; for others it is what has reached this device.
  Set<String> subscribers(Bcast c) {
    final latest = <String, Item>{};
    for (final m in _mutationsFor([c.id])) {
      if (m.e.kind != K.like || m.body['sub'] != true) continue;
      final prev = latest[m.author];
      if (prev == null || m.ts >= prev.ts) latest[m.author] = m;
    }
    return {for (final x in latest.entries) if (x.value.body['on'] != false) x.key};
  }

  /// Owner-controlled state: pinned post and whether comments are open.
  ({String? pinned, bool comments}) channelState(Bcast c) {
    Item? last;
    for (final m in _mutationsFor([c.id])) {
      if (m.e.kind != K.edit || m.author != c.owner || m.body['chan'] != true) continue;
      if (last == null || m.ts >= last.ts) last = m;
    }
    final b = last?.body ?? const <String, dynamic>{};
    return (pinned: b['pin'] is String ? b['pin'] as String : null, comments: b['comments'] != false);
  }

  Future<void> setChannelState(Bcast c, {String? pinned, required bool comments}) async {
    if (c.owner != me.id) throw StateError('Only the owner changes a channel');
    await _publish(K.edit, Scope.feed(me.id), {
      'target': c.id,
      'chan': true,
      'text': '',
      'pin': ?pinned,
      'comments': comments,
    }, keep: true);
    _emit({Ch.channels, Scope.bcast(me.id, c.id)});
  }

  List<PostView> channelFeed({
    required String owner,
    required String channelId,
  }) {
    final scopes = {
      Scope.bcast(owner, channelId),
      Scope.channel(owner, channelId),
    };
    // space channels use Scope.channel(spaceId, channelId) — owner param is space or person
    scopes.add(Scope.channel(owner, channelId));
    final byId = <String, Item>{};
    for (final s in scopes) {
      for (final i in items(s)) {
        if (i.e.kind == K.post) byId[i.id] = i;
      }
    }
    final posts = byId.values.toList()..sort((a, b) => b.ts.compareTo(a.ts));
    return _postViews(posts, db.bookmarkIds());
  }

  Future<void> inviteToGroup(String groupId, List<String> ids) async {
    final g = db.group(groupId);
    if (g == null || g.owner != me.id) return;
    for (final id in ids.where((id) => id != me.id && !g.has(id))) {
      (_outgoingInvites[g.id] ??= {})[id] = nowMs();
      _saveOutgoingInvites();
      await _sendOrQueue('ginvite:${g.id}:$id', id, {
        't': 'ginvite',
        'id': g.id,
        'name': g.name,
        'owner': g.owner,
        'about': '',
        'members': g.members,
      });
    }
  }

  Future<void> _onGroupInvite(String from, Map<String, dynamic> m) async {
    final id = m['id'] as String? ?? '';
    final owner = m['owner'] as String? ?? '';
    if (id.isEmpty || owner != from || db.group(id) != null) {
      return;
    }
    _invites[id] = {...m, 'from': from}..remove('key');
    _saveInvites();
    db.addActivity(
      Activity(
        id: 'ginvite:$id',
        kind: 'invite',
        actor: from,
        ref: id,
        text: m['name'] as String?,
        ts: nowMs(),
      ),
    );
    pushAlert(
      Alert(
        id: 'ginvite:$id',
        kind: 'invite',
        title: '${nameOf(from)} invited you to a group',
        body: (m['name'] as String?) ?? 'Group',
        route: '/activity',
      ),
    );
    _emit({Ch.activity, Ch.groups});
  }

  Map<String, dynamic>? groupInvite(String id) => _invites[id];

  void _loadInvites() {
    final raw = db.getKv('ginvites');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        if (entry.value is! Map) continue;
        final invite = Map<String, dynamic>.from(entry.value as Map)
          ..remove('key');
        _invites[entry.key.toString()] = invite;
      }
    } catch (_) {}
  }

  void _saveInvites() {
    db.setKv('ginvites', jsonEncode(_invites));
  }

  void _loadOutgoingInvites() {
    try {
      final raw = db.getKv('goutvites');
      if (raw == null) return;
      final cutoff = nowMs() - _inviteTtl.inMilliseconds;
      for (final g in (jsonDecode(raw) as Map).entries) {
        if (g.value is! Map) continue;
        final peers = <String, int>{
          for (final p in (g.value as Map).entries)
            if (p.value is num && (p.value as num) > cutoff) '${p.key}': (p.value as num).toInt(),
        };
        if (peers.isNotEmpty) _outgoingInvites['${g.key}'] = peers;
      }
    } catch (_) {}
  }

  void _saveOutgoingInvites() {
    _outgoingInvites.removeWhere((_, v) => v.isEmpty);
    db.setKv('goutvites', jsonEncode(_outgoingInvites));
  }

  /// People invited to [groupId] who have not answered yet.
  List<String> pendingInvites(String groupId) => (_outgoingInvites[groupId] ?? const {}).keys.toList();

  /// Withdraws an invitation; a later acceptance is ignored.
  void revokeGroupInvite(String groupId, String peer) {
    _outgoingInvites[groupId]?.remove(peer);
    _saveOutgoingInvites();
    db.deleteOutbox('ginvite:$groupId:$peer');
    _emit({Ch.groups});
  }

  Future<void> respondGroupInvite(String id, bool accept) async {
    final m = _invites.remove(id);
    _saveInvites();
    dismissAlert('ginvite:$id');
    if (m == null) return;
    if (!accept) {
      _emit({Ch.activity, Ch.groups});
      return;
    }
    final owner = m['owner'] as String? ?? m['from'] as String? ?? '';
    if (owner.isEmpty) {
      _emit({Ch.activity, Ch.groups});
      return;
    }
    final members = <String>[
      for (final x in (m['members'] as List?) ?? const [])
        if (x is String && x.isNotEmpty) x,
    ];
    if (!members.contains(me.id)) members.add(me.id);
    final rawKey = m['key'] as String? ?? '';
    final g = GroupInfo(
      id: id,
      name: (m['name'] as String?) ?? 'Group',
      owner: owner,
      key: _sealKey(rawKey) != null ? rawKey : 'pending',
      members: members,
      joined: nowMs(),
    );
    db.putGroup(g);
    db.ensureChat(Scope.gdm(g.id));
    await _joinGroupTopic(g);
    await _sendOrQueue('gaccept:${g.id}:${me.id}', g.owner, {
      't': 'gaccept',
      'id': g.id,
    });
    _emit({Ch.groups, Ch.chats});
  }

  List<({int ts, int views, int likes, int comments})> insightSeries({
    int days = 30,
  }) {
    final since = nowMs() - Duration(days: days).inMilliseconds;
    final posts = feed(
      author: me.id,
      limit: 2000,
    ).where((p) => p.item.ts >= since);
    final byDay = <int, ({int views, int likes, int comments})>{};
    for (final p in posts) {
      final day = DateTime.fromMillisecondsSinceEpoch(p.item.ts);
      final k = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
      final prev = byDay[k] ?? (views: 0, likes: 0, comments: 0);
      byDay[k] = (
        views: prev.views + p.views,
        likes: prev.likes + p.likes,
        comments: prev.comments + p.comments,
      );
    }
    return [
      for (final e
          in (byDay.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
        (
          ts: e.key,
          views: e.value.views,
          likes: e.value.likes,
          comments: e.value.comments,
        ),
    ];
  }

  ({int views, int viewers, int followers}) insightTotals({int days = 30}) {
    final series = insightSeries(days: days);
    var views = 0;
    for (final s in series) {
      views += s.views;
    }
    final viewers = <String>{};
    for (final p in feed(author: me.id, limit: 500)) {
      // view actors aren't listed on PostView; use likes+comments as a stand-in for unique
      viewers.add(p.author);
    }
    return (
      views: views,
      viewers: viewers.length,
      followers: db.peers().where((p) => p.followsMe).length,
    );
  }

  Future<void> reconnect() async {
    if (_held) return;
    _helloAt.clear();
    await _dialContacts();
    for (final p in _links.toList()) {
      db.reviveDeliveries(p);
      await _hello(p);
    }
    await flushDeliveries();
  }

  /// Stops the node. The app stays open; contacts are not dialed until [connectNode].
  Future<void> disconnectNode() async {
    if (_stopping != null) return;
    _held = true;
    _meshJoined = false;
    _sawStatus = false;
    _runningPolls = 0;
    _bindStarted = null;
    _status = 'offline';
    _links.clear();
    _neighbors.clear();
    _emit({Ch.net, Ch.presence});
    final job = net.stop();
    _stopping = job;
    try {
      await job;
    } catch (_) {}
    if (identical(_stopping, job)) _stopping = null;
    _emit({Ch.net, Ch.presence});
  }

  /// Starts the node if it is down, rejoins topics, and reaches out to contacts.
  Future<void> connectNode() async {
    if (_connecting) return;
    final stopping = _stopping;
    if (stopping != null) await stopping;
    if (_connecting) return;
    _connecting = true;
    _held = false;
    _emit({Ch.net});
    try {
      final current = await netStatus();
      if (!current.running && _dataDir != null && !_bindInFlight) {
        _bindStarted = DateTime.now();
        _meshJoined = false;
        _applyNetOptions();
        try {
          await net.start(
            secret: me.seed,
            dataDir: _dataDir!,
            blobDir: media.blobs.path,
          );
          _status = 'online';
        } catch (_) {
          _status = 'offline';
        }
      }
      for (var i = 0; i < 24 && !_held; i++) {
        if ((await netStatus()).running) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (_held) return;
      _meshJoined = false;
      await _bringUpWhenReady();
    } finally {
      _connecting = false;
      _emit({Ch.net});
    }
  }
}
