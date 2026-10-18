import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/crypto/crypto.dart';
import '../data/models.dart';
import 'engine.dart';

/// One node's signed announcement: who it is and where it can be reached.
/// It never carries IP addresses, only the relay that introduces it.
class Beacon {
  const Beacon({
    required this.id,
    required this.relay,
    required this.mode,
    required this.links,
    required this.ts,
    this.sig = '',
  });

  final String id;

  /// Home relay URL, or empty when the node has none yet.
  final String relay;

  /// standard | relay | tor
  final String mode;
  final int links;
  final int ts;
  final String sig;

  String get signed => 'mentos-atlas:v1|$id|$relay|$mode|$links|$ts';

  Map<String, Object> toJson() => {'id': id, 'r': relay, 'm': mode, 'l': links, 'ts': ts, 'sig': sig};

  static Beacon? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], r = j['r'], m = j['m'], l = j['l'], ts = j['ts'], sig = j['sig'];
    if (id is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) return null;
    if (r is! String || r.length > 200 || m is! String || m.length > 12) return null;
    if (l is! int || l < 0 || ts is! int || sig is! String || sig.length > 200) return null;
    if (r.isNotEmpty) {
      final u = Uri.tryParse(r);
      if (u == null || (u.scheme != 'https' && u.scheme != 'http') || u.host.isEmpty) return null;
    }
    return Beacon(id: id, relay: r, mode: m, links: l, ts: ts, sig: sig);
  }

  Future<bool> verify() => Identity.verify(id, utf8.encode(signed), sig);
}

/// A relay and what the atlas knows about it.
class AtlasRelay {
  AtlasRelay(this.url);
  final String url;
  final nodes = <String>{};
  int lastSeen = 0;
}

/// The network atlas: every node that announced itself, and the relays they
/// use. Built from signed beacons gossiped on one topic every node joins,
/// plus snapshots exchanged when two phones link up, so a newcomer sees the
/// whole network within a moment. Nodes can opt out of announcing.
class Atlas {
  Atlas(this.engine) {
    _sub = engine.appMessages.where((m) => m.app == app).listen((m) {
      unawaited(_onSnapshot(m.from, m.m));
    });
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => unawaited(announce()));
    _load();
  }

  static const app = 'atlas';
  static const topicLabel = 'mentos-atlas-v1';
  static final topic = toHex(sha256(utf8.encode(topicLabel)));

  /// Beacons older than this are dropped.
  static const ttl = Duration(hours: 24);
  static const maxNodes = 5000;

  final Engine engine;
  StreamSubscription<({String from, String app, Map<String, dynamic> m})>? _sub;
  Timer? _timer;
  final _beacons = <String, Beacon>{};
  final _changes = StreamController<void>.broadcast();
  int _lastAnnounce = 0;
  int _lastSaved = 0;
  bool _closed = false;

  Stream<void> get changes => _changes.stream;

  bool get announcing => engine.db.getKv('atlas:off') != '1';
  set announcing(bool on) {
    engine.db.setKv('atlas:off', on ? '0' : '1');
    if (on) unawaited(announce(force: true));
    _changed();
  }

  /// Fresh beacons from other nodes, newest first.
  List<Beacon> nodes() {
    final cutoff = nowMs() - ttl.inMilliseconds;
    return _beacons.values.where((b) => b.ts > cutoff && b.id != engine.me.id).toList()
      ..sort((a, b) => b.ts.compareTo(a.ts));
  }

  /// This node's last beacon, if it announced.
  Beacon? get own => _beacons[engine.me.id];

  Beacon? beacon(String id) => _beacons[id];

  /// Every relay a fresh beacon names, busiest first.
  List<AtlasRelay> relays() {
    final out = <String, AtlasRelay>{};
    for (final b in [...nodes(), ?own]) {
      if (b.relay.isEmpty) continue;
      final r = out.putIfAbsent(b.relay, () => AtlasRelay(b.relay));
      r.nodes.add(b.id);
      if (b.ts > r.lastSeen) r.lastSeen = b.ts;
    }
    return out.values.toList()..sort((a, b) => b.nodes.length.compareTo(a.nodes.length));
  }

  Future<void> join() async {
    try {
      await engine.net.join(topic, const []);
    } catch (_) {}
    await announce(force: true);
  }

  Future<void> dispose() async {
    _closed = true;
    _timer?.cancel();
    await _sub?.cancel();
    _save(force: true);
    await _changes.close();
  }

  void _changed() {
    if (!_closed && !_changes.isClosed) _changes.add(null);
  }

  Future<Beacon> _mine() async {
    final st = await engine.netStatus();
    final draft = Beacon(
      id: engine.me.id,
      relay: st.relayUrl ?? '',
      mode: engine.settings.privacy,
      links: engine.onlinePeers.length,
      ts: nowMs(),
    );
    return Beacon(
      id: draft.id,
      relay: draft.relay,
      mode: draft.mode,
      links: draft.links,
      ts: draft.ts,
      sig: await engine.me.sign(utf8.encode(draft.signed)),
    );
  }

  /// Tells the network this node exists. Skipped while opted out.
  Future<void> announce({bool force = false}) async {
    if (_closed || !engine.running || !announcing) return;
    if (!force && nowMs() - _lastAnnounce < 30000) return;
    _lastAnnounce = nowMs();
    try {
      final b = await _mine();
      _beacons[b.id] = b;
      _changed();
      await engine.net.broadcast(topic, Uint8List.fromList(utf8.encode(jsonEncode({'op': 'b', 'b': b.toJson()}))));
    } catch (_) {}
  }

  Future<void> onGossip(String from, Map<String, dynamic> m) async {
    if (m['op'] != 'b') return;
    final b = Beacon.fromJson(m['b']);
    if (b != null && await _accept(b)) _changed();
  }

  /// Sends a newly linked phone what this one knows, newest first.
  Future<void> onPeer(String peer) async {
    if (_closed) return;
    final list = [
      if (announcing && own != null) own!.toJson(),
      ...nodes().take(400).map((b) => b.toJson()),
    ];
    if (list.isEmpty) return;
    try {
      await engine.sendApp(peer, app, {'op': 'snap', 'list': list});
    } catch (_) {}
  }

  Future<void> _onSnapshot(String from, Map<String, dynamic> m) async {
    if (m['op'] != 'snap' || m['list'] is! List) return;
    var any = false;
    for (final raw in (m['list'] as List).take(400)) {
      final b = Beacon.fromJson(raw);
      if (b != null && await _accept(b)) any = true;
    }
    if (any) _changed();
  }

  Future<bool> _accept(Beacon b) async {
    final now = nowMs();
    if (b.ts > now + 600000 || b.ts < now - ttl.inMilliseconds) return false;
    if (b.id == engine.me.id) return false;
    final old = _beacons[b.id];
    if (old != null && old.ts >= b.ts) return false;
    if (engine.db.peer(b.id)?.blocked ?? false) return false;
    if (!await b.verify()) return false;
    _beacons[b.id] = b;
    if (_beacons.length > maxNodes) {
      final oldest = _beacons.values.toList()..sort((a, c) => a.ts.compareTo(c.ts));
      for (final x in oldest.take(_beacons.length - maxNodes)) {
        _beacons.remove(x.id);
      }
    }
    _save();
    return true;
  }

  void _load() {
    try {
      final raw = engine.db.getKv('atlas');
      if (raw == null) return;
      for (final j in jsonDecode(raw) as List) {
        final b = Beacon.fromJson(j);
        if (b != null) _beacons[b.id] = b;
      }
    } catch (_) {}
  }

  void _save({bool force = false}) {
    if (!force && nowMs() - _lastSaved < 30000) return;
    _lastSaved = nowMs();
    try {
      engine.db.setKv('atlas', jsonEncode([for (final b in nodes().take(maxNodes)) b.toJson()]));
    } catch (_) {}
  }
}
