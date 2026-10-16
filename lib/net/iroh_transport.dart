import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'iroh_native.dart';
import 'transport.dart';

class IrohTransport implements Transport, NetTools, MediaLink {
  IrohTransport(this._n);

  final IrohNative _n;
  final _events = StreamController<NetEvent>.broadcast();
  Timer? _poll;
  String _blobDir = '';

  static IrohTransport? tryOpen() {
    try {
      return IrohTransport(IrohNative.open());
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<NetEvent> get events => _events.stream;

  @override
  Future<void> start({
    required Uint8List secret,
    required String dataDir,
    required String blobDir,
  }) async {
    _blobDir = blobDir;
    // Native start must return immediately (Tokio spawn). Binding on the UI
    // isolate is what froze the splash on "opening your node".
    _n.start(secret: secret, dataDir: dataDir, blobDir: blobDir);
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) {
      try {
        _drain();
      } catch (_) {}
    });
  }

  void _drain() {
    for (var i = 0; i < 32; i++) {
      final m = _n.pollEvent();
      if (m == null) return;
      switch (m['t']) {
        case 'direct':
          final from = m['from'] as String?;
          if (from != null) _events.add(DirectEvent(from, _bytes(m['data'])));
        case 'gossip':
          final topic = m['topic'] as String?;
          final from = m['from'] as String?;
          if (topic != null && from != null) {
            _events.add(GossipEvent(topic, from, _bytes(m['data'])));
          }
        case 'link':
          final peer = m['peer'] as String?;
          if (peer != null) _events.add(LinkEvent(peer, m['up'] == true));
        case 'neighbor':
          final topic = m['topic'] as String?;
          final peer = m['peer'] as String?;
          if (topic != null && peer != null) {
            _events.add(NeighborEvent(topic, peer, m['up'] == true));
          }
        case 'status':
          _events.add(StatusEvent());
        case 'call':
          final call = m['id'] as String?;
          final peer = m['peer'] as String?;
          if (call != null && peer != null) _events.add(MediaEvent(call, peer, m['up'] == true));
      }
    }
  }

  String? preferredRelay;

  @override
  void setPreferredRelay(String? url) {
    final t = url?.trim();
    preferredRelay = (t == null || t.isEmpty) ? null : t;
  }

  String _dial(String peer) {
    final relay = preferredRelay;
    if (relay == null || peer.contains('|')) return peer;
    return '$peer|$relay';
  }

  Uint8List _bytes(Object? v) {
    try {
      if (v is String) return Uint8List.fromList(base64Decode(v));
      if (v is Uint8List) return v;
      if (v is List) {
        return Uint8List.fromList(v.map((e) => (e as num).toInt()).toList());
      }
    } catch (_) {}
    return Uint8List(0);
  }

  @override
  Future<void> stop() async {
    _poll?.cancel();
    try {
      _n.stop();
    } catch (_) {}
  }

  @override
  Future<bool> send(String peer, Uint8List data) async {
    final ok = await _call('send', _dial(peer), data);
    return ok == true;
  }

  @override
  Future<bool> connect(String peer) async {
    try {
      return _n.connect(_dial(peer));
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> ticket() async {
    try {
      return _n.ticket();
    } catch (_) {
      return '';
    }
  }

  @override
  Future<String?> addTicket(String ticket) async {
    try {
      return _n.addTicket(ticket);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> join(String topic, List<String> bootstrap) async {
    try {
      _n.join(topic, bootstrap);
    } catch (_) {}
  }

  @override
  Future<void> leave(String topic) async {
    try {
      _n.leave(topic);
    } catch (_) {}
  }

  @override
  Future<bool> broadcast(String topic, Uint8List data) async {
    final ok = await _call('broadcast', topic, data);
    return ok == true;
  }

  @override
  Future<String> importBlob(String path) async {
    // Hashing a large video on the UI isolate froze the app long enough for
    // Android to report it as not responding.
    final out = await _call('import', path, null, lane: _fileLane, timeout: const Duration(minutes: 5));
    if (out is String && out.isNotEmpty) return out;
    throw StateError(out is _Failure ? out.message : 'import failed');
  }

  bool _hashOk(String hash) => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash);

  @override
  Future<bool> fetchBlob(String hash, String peer) async {
    if (!_hashOk(hash)) return false;
    // Native fetch blocks until the blob arrives, times out, or is cancelled.
    // The worker isolate keeps that wait off the UI thread. Cancel is a
    // separate FFI call on this isolate so it is not stuck behind the fetch.
    // The native deadline grows with the file size (80 MiB over a slow relay
    // takes minutes); this only catches a lane that stopped answering.
    final ok = await _call('fetch', hash, peer, lane: _blobLane, timeout: const Duration(minutes: 25));
    return ok == true;
  }

  @override
  Future<void> cancelFetch(String hash) async {
    if (!_hashOk(hash)) return;
    try {
      _n.cancelFetch(hash);
    } catch (_) {}
  }

  @override
  Future<Map<String, dynamic>?> diagnostics() async {
    final out = await _call('diag', null, null, lane: _diagLane, timeout: const Duration(seconds: 20));
    return out is Map ? out.cast<String, dynamic>() : null;
  }

  @override
  Future<double?> ping(String peer) async {
    final out = await _call('ping', peer, null, lane: _diagLane, timeout: const Duration(seconds: 25));
    return out is int && out >= 0 ? out / 1000 : null;
  }

  @override
  String? setOptions(Map<String, Object?> options) {
    try {
      return _n.setOptions(jsonEncode(options));
    } catch (e) {
      return '$e';
    }
  }

  bool get supportsCalls => _n.hasCalls;

  @override
  bool callListen(String call, List<String> peers) => _n.callListen(call, peers);
  @override
  bool callDial(String call, String peer) => _n.callDial(call, peer);
  @override
  int callSend(String call, Uint8List data) => _n.callSend(call, data);
  @override
  ({String peer, Uint8List data})? callRecv(String call) => _n.callRecv(call);
  @override
  int callMaxDatagram(String call) => _n.callMaxDatagram(call);
  @override
  void callDropPeer(String call, String peer) => _n.callDropPeer(call, peer);
  @override
  void callClose(String call) => _n.callClose(call);
  @override
  Map<String, dynamic>? callStats(String call) => _n.callStats(call);

  @override
  void networkChange() {
    try {
      _n.networkChange();
    } catch (_) {}
  }

  // Each worker runs blocking FFI calls one at a time. A blob fetch can hold
  // its worker for minutes, so fetches and imports get their own lanes and
  // never delay messages.
  final _msgLane = _Lane();
  final _blobLane = _Lane();
  final _fileLane = _Lane();
  final _diagLane = _Lane();

  Future<Object?> _call(
    String op,
    Object? a,
    Object? b, {
    _Lane? lane,
    Duration timeout = const Duration(seconds: 50),
  }) async {
    final reply = ReceivePort();
    try {
      final port = await (lane ?? _msgLane).port().timeout(const Duration(seconds: 10));
      port.send([op, a, b, reply.sendPort]);
      return await reply.first.timeout(timeout, onTimeout: () => false);
    } catch (_) {
      return false;
    } finally {
      reply.close();
    }
  }

  @override
  String blobPath(String hash) {
    if (!_hashOk(hash)) return '';
    try {
      final p = _n.blobPath(hash);
      return p.isEmpty ? '$_blobDir/${hash.toLowerCase()}' : p;
    } catch (_) {
      return '$_blobDir/${hash.toLowerCase()}';
    }
  }

  @override
  Future<NetStatus> status() async {
    try {
      final m = _n.status();
      if (m.isEmpty) {
        return NetStatus(nodeId: '', running: false, engine: 'iroh');
      }
      final links = <LinkInfo>[];
      for (final l in (m['links'] as List?) ?? const []) {
        if (l is! Map) continue;
        final kind = switch (l['kind']) {
          'direct' => LinkKind.direct,
          'relay' => LinkKind.relay,
          'none' => LinkKind.none,
          _ => LinkKind.mixed,
        };
        final peer = l['peer'] as String?;
        if (peer == null) continue;
        final paths = <RoutePath>[];
        for (final path in (l['paths'] as List?) ?? const []) {
          if (path is! Map || path['address'] is! String) continue;
          paths.add(
            RoutePath(
              kind: path['kind'] == 'direct'
                  ? LinkKind.direct
                  : path['kind'] == 'relay'
                  ? LinkKind.relay
                  : LinkKind.none,
              address: path['address'] as String,
              selected: path['selected'] == true,
              latencyMs: (path['rtt'] as num?)?.toInt(),
            ),
          );
        }
        links.add(
          LinkInfo(
            peer: peer,
            kind: kind,
            latencyMs: (l['rtt'] as num?)?.toInt(),
            paths: paths,
          ),
        );
      }
      final relays = ((m['relays'] as List?) ?? const [])
          .map((e) => e.toString())
          .where((s) => s.isNotEmpty)
          .toList();
      final home = m['relayUrl'] as String?;
      return NetStatus(
        nodeId: m['nodeId'] as String? ?? '',
        running: m['running'] == true,
        relayUrl: home ?? (relays.isEmpty ? null : relays.first),
        directAddrs: ((m['directAddrs'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        relays: relays.isEmpty && home != null ? [home] : relays,
        links: links,
        engine: 'iroh',
        topics: (m['topics'] as num?)?.toInt() ?? 0,
        routeTelemetry: m['routeTelemetry'] == 1,
      );
    } catch (_) {
      return const NetStatus(nodeId: '', running: false, engine: 'iroh');
    }
  }
}

class _Failure {
  const _Failure(this.message);
  final String message;
}

class _Lane {
  SendPort? _worker;
  Future<SendPort>? _starting;

  Future<SendPort> port() {
    final existing = _worker;
    if (existing != null) return Future.value(existing);
    return _starting ??= () async {
      final ready = ReceivePort();
      final exit = ReceivePort();
      try {
        await Isolate.spawn(_nativeIo, ready.sendPort, onExit: exit.sendPort);
        // A worker that dies (library missing, uncaught error) is replaced on
        // the next call instead of swallowing every later request.
        exit.first.then((_) {
          _worker = null;
          _starting = null;
          exit.close();
        });
        final port = await ready.first.timeout(const Duration(seconds: 10)) as SendPort;
        _worker = port;
        return port;
      } catch (_) {
        _starting = null;
        exit.close();
        rethrow;
      } finally {
        ready.close();
      }
    }();
  }
}

void _nativeIo(SendPort parent) {
  final n = IrohNative.open();
  final incoming = ReceivePort();
  parent.send(incoming.sendPort);
  incoming.listen((msg) {
    if (msg is! List || msg.length < 4 || msg[3] is! SendPort) return;
    final reply = msg[3] as SendPort;
    try {
      switch (msg[0]) {
        case 'send':
          reply.send(n.send(msg[1] as String, msg[2] as Uint8List));
        case 'broadcast':
          reply.send(n.broadcast(msg[1] as String, msg[2] as Uint8List));
        case 'fetch':
          reply.send(n.fetchBlob(msg[1] as String, msg[2] as String));
        case 'import':
          try {
            reply.send(n.importBlob(msg[1] as String));
          } catch (e) {
            reply.send(_Failure(e is StateError ? e.message : '$e'));
          }
        case 'diag':
          reply.send(n.diagnostics());
        case 'ping':
          reply.send(n.ping(msg[1] as String));
        default:
          reply.send(false);
      }
    } catch (_) {
      reply.send(false);
    }
  });
}
