import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/core/theme/app_theme.dart';
import 'package:mentos/core/theme/tokens.dart';
import 'package:mentos/data/db.dart';
import 'package:mentos/data/media_store.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/transport.dart';
import 'package:mentos/state/session.dart';
import 'package:mentos/state/settings.dart';

// Runs the real engine and encrypted SQLite store against an in-process
// authenticated transport. No external peers, app accounts or user data.
class TestNetwork {
  final nodes = <String, TestTransport>{};
  final messages = <({String from, String to, Map<String, dynamic> body})>[];
  bool dropAcks = false;

  /// Drop payment acceptances in flight, to test recovery.
  bool dropApp = false;

  /// Sender ids whose direct messages are refused, as if no QUIC link exists.
  final dropDirectFrom = <String>{};

  /// Report a topic broadcast as accepted even when nobody is listening.
  /// A real gossip subscribe can do this before it finds a neighbor.
  bool acceptBroadcastWithoutPeers = false;

  /// topic -> node ids that joined it, for in-process gossip.
  final topics = <String, Set<String>>{};

  /// Store and serve blobs from a folder per node, like the native node.
  bool blobs = false;
  Completer<bool>? sendGate;
  final sendGates = <String, Completer<bool>>{};
}

class TestTransport implements Transport, MediaLink {
  TestTransport(this.network, this.id) {
    network.nodes[id] = this;
  }
  final TestNetwork network;
  final String id;
  bool online = true;
  bool started = false;
  String _blobDir = '';
  final controller = StreamController<NetEvent>.broadcast();
  @override
  void setPreferredRelay(String? url) {}

  @override
  Stream<NetEvent> get events => controller.stream;
  @override
  Future<void> start({
    required Uint8List secret,
    required String dataDir,
    required String blobDir,
  }) async {
    _blobDir = blobDir;
    if (network.blobs) Directory(blobDir).createSync(recursive: true);
    started = true;
  }

  @override
  Future<void> stop() async {
    started = false;
  }

  @override
  Future<bool> send(String peer, Uint8List data) async {
    final body = (jsonDecode(utf8.decode(data)) as Map).cast<String, dynamic>();
    final receiver = network.nodes[peer];
    if (!online ||
        receiver == null ||
        !receiver.online ||
        !receiver.started ||
        network.dropDirectFrom.contains(id)) {
      return false;
    }
    network.messages.add((from: id, to: peer, body: body));
    final peerGate = network.sendGates[peer];
    if (body['t'] == 'item' && peerGate != null) {
      if (!await peerGate.future) return false;
    }
    if (body['t'] == 'item' &&
        Envelope.fromWire(body['e'])?.kind == K.msg &&
        network.sendGate != null) {
      if (!await network.sendGate!.future) return false;
    }
    final droppedPay = network.dropApp && body['t'] == 'app' && (body['b'] as Map?)?['op'] == 'accept';
    if (!(network.dropAcks && body['t'] == 'ack') && !droppedPay) {
      receiver.controller.add(DirectEvent(id, data));
    }
    return true;
  }

  // In-process call media: call id -> allowed peers, connected peers, inbox.
  final _calls = <String, ({Set<String> allowed, Set<String> conns, List<({String peer, Uint8List data})> inbox})>{};
  int mediaSent = 0;

  @override
  bool callListen(String call, List<String> peers) {
    final c = _calls.putIfAbsent(call, () => (allowed: <String>{}, conns: <String>{}, inbox: []));
    c.allowed.addAll(peers);
    return true;
  }

  @override
  bool callDial(String call, String peer) {
    final mine = _calls[call];
    final other = network.nodes[peer];
    final theirs = other?._calls[call];
    if (mine == null || !mine.allowed.contains(peer)) return false;
    scheduleMicrotask(() {
      final ok = online && other != null && other.online && theirs != null && theirs.allowed.contains(id);
      if (!ok) {
        controller.add(MediaEvent(call, peer, false));
        return;
      }
      mine.conns.add(peer);
      theirs.conns.add(id);
      controller.add(MediaEvent(call, peer, true));
      other.controller.add(MediaEvent(call, id, true));
    });
    return true;
  }

  @override
  int callSend(String call, Uint8List data) {
    final c = _calls[call];
    if (c == null) return -1;
    var n = 0;
    for (final p in c.conns) {
      final t = network.nodes[p]?._calls[call];
      if (t == null || !t.conns.contains(id) || !online) continue;
      t.inbox.add((peer: id, data: Uint8List.fromList(data)));
      n++;
    }
    mediaSent += n;
    return n;
  }

  @override
  ({String peer, Uint8List data})? callRecv(String call) {
    final c = _calls[call];
    if (c == null || c.inbox.isEmpty) return null;
    return c.inbox.removeAt(0);
  }

  @override
  int callMaxDatagram(String call) => (_calls[call]?.conns.isNotEmpty ?? false) ? 1200 : 0;

  @override
  void callDropPeer(String call, String peer) {
    _calls[call]?.allowed.remove(peer);
    _calls[call]?.conns.remove(peer);
  }

  @override
  void callClose(String call) {
    final c = _calls.remove(call);
    for (final p in c?.conns ?? const <String>{}) {
      final t = network.nodes[p];
      if (t?._calls[call]?.conns.remove(id) ?? false) t!.controller.add(MediaEvent(call, id, false));
    }
  }

  @override
  Map<String, dynamic>? callStats(String call) => {
        'id': call,
        'peers': [for (final p in _calls[call]?.conns ?? const <String>{}) {'peer': p, 'rttMs': 12.0}],
      };

  @override
  Future<NetStatus> status() async =>
      NetStatus(nodeId: id, running: online && started, engine: 'test');
  @override
  Future<bool> connect(String peer) async => false;
  @override
  Future<String> ticket() async => '';
  @override
  Future<String?> addTicket(String ticket) async => null;
  @override
  Future<void> join(String topic, List<String> bootstrap) async {
    network.topics.putIfAbsent(topic, () => <String>{}).add(id);
  }

  @override
  Future<void> leave(String topic) async {
    network.topics[topic]?.remove(id);
  }

  /// Delivers to every other online node on the topic, like a gossip swarm
  /// where everyone is a neighbour.
  @override
  Future<bool> broadcast(String topic, Uint8List data) async {
    if (!online || !started) return false;
    var any = false;
    for (final peer in network.topics[topic] ?? const <String>{}) {
      final n = network.nodes[peer];
      if (peer == id || n == null || !n.online || !n.started) continue;
      n.controller.add(GossipEvent(topic, id, data));
      any = true;
    }
    if (!any && network.acceptBroadcastWithoutPeers) return true;
    return any;
  }
  @override
  Future<String> importBlob(String path) async {
    if (!network.blobs) throw UnimplementedError();
    final bytes = await File(path).readAsBytes();
    final hash = toHex(sha256(bytes));
    final dest = File('$_blobDir/$hash');
    if (!dest.existsSync()) await dest.writeAsBytes(bytes, flush: true);
    await File(path).delete();
    return hash;
  }

  @override
  Future<bool> fetchBlob(String hash, String peer) async {
    if (!network.blobs || !online) return false;
    final other = network.nodes[peer];
    if (other == null || !other.online || !other.started) return false;
    final src = File(other.blobPath(hash));
    if (!src.existsSync()) return false;
    await src.copy(blobPath(hash));
    return true;
  }

  @override
  Future<void> cancelFetch(String hash) async {}
  @override
  String blobPath(String hash) => network.blobs ? '$_blobDir/$hash' : '';
}

Future<void> eventually(bool Function() predicate) async {
  for (var i = 0; i < 500; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue, reason: 'Condition did not become true');
}


/// A test transport that also answers the diagnostics tools.
class DiagTransport extends TestTransport implements NetTools {
  DiagTransport(super.network, super.id);
  Map<String, dynamic>? report;
  Map<String, Object?>? options;
  double? pingMs = 12.5;
  int networkChanges = 0;

  @override
  Future<Map<String, dynamic>?> diagnostics() async => report;
  @override
  Future<double?> ping(String peer) async => pingMs;
  @override
  String? setOptions(Map<String, Object?> o) {
    options = o;
    return null;
  }

  @override
  void networkChange() => networkChanges++;
}

/// Opens a real engine with an encrypted database under [root].
Future<Engine> openEngine(
  Directory root,
  TestNetwork network, {
  Identity? identity,
  Transport Function(String id)? transport,
  Settings settings = const Settings(),
}) async {
  final me = identity ?? await Identity.generate();
  final dir = Directory('${root.path}/${me.id}');
  await dir.create(recursive: true);
  final db = Db.open('${dir.path}/test.db', toHex(sha256(me.seed)));
  final net = transport?.call(me.id) ?? TestTransport(network, me.id);
  final media = MediaStore(dir.path, db, net);
  await media.init();
  final engine = Engine(me: me, db: db, net: net, media: media, settings: settings);
  await engine.start('${dir.path}/node');
  return engine;
}

class _ReadySession extends SessionNotifier {
  _ReadySession(this.engine);
  final Engine engine;
  @override
  Session build() => SessionReady(engine);
}

/// Pumps [child] at phone size with [engine] as the signed-in session.
Future<void> pumpScreen(WidgetTester tester, Engine engine, Widget child, {Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionProvider.overrideWith(() => _ReadySession(engine))],
      child: MaterialApp(theme: buildTheme(Palette.light), home: child),
    ),
  );
}
