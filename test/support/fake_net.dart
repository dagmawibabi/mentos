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

  /// topic -> node ids that joined it, for in-process gossip.
  final topics = <String, Set<String>>{};
  Completer<bool>? sendGate;
}

class TestTransport implements Transport {
  TestTransport(this.network, this.id) {
    network.nodes[id] = this;
  }
  final TestNetwork network;
  final String id;
  bool online = true;
  bool started = false;
  final controller = StreamController<NetEvent>.broadcast();
  @override
  Stream<NetEvent> get events => controller.stream;
  @override
  Future<void> start({
    required Uint8List secret,
    required String dataDir,
    required String blobDir,
  }) async {
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
    if (!online || receiver == null || !receiver.online || !receiver.started) {
      return false;
    }
    network.messages.add((from: id, to: peer, body: body));
    if (body['t'] == 'item' &&
        Envelope.fromWire(body['e'])?.kind == K.msg &&
        network.sendGate != null) {
      if (!await network.sendGate!.future) return false;
    }
    if (!(network.dropAcks && body['t'] == 'ack')) {
      receiver.controller.add(DirectEvent(id, data));
    }
    return true;
  }

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
    return any;
  }
  @override
  Future<String> importBlob(String path) async => throw UnimplementedError();
  @override
  Future<bool> fetchBlob(String hash, String peer) async => false;
  @override
  Future<void> cancelFetch(String hash) async {}
  @override
  String blobPath(String hash) => '';
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
