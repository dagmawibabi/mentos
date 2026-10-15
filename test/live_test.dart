import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/call/live.dart';
import 'package:mentos/net/call/media.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/transport.dart';

import 'support/fake_net.dart';

Uint8List tone(int v) {
  final b = ByteData(MediaPacket.frameBytes);
  for (var i = 0; i < MediaPacket.samplesPerFrame; i++) {
    b.setInt16(i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  late Directory root;
  late TestNetwork network;
  late List<Engine> engines;
  late List<LiveManager> managers;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-live-');
    network = TestNetwork();
    engines = [];
    managers = [];
  });
  tearDown(() async {
    for (final m in managers) {
      await m.dispose();
    }
    for (final e in engines) {
      await e.stop();
      e.db.close();
    }
    await root.delete(recursive: true);
  });

  Future<(Engine, LiveManager)> node() async {
    final e = await openEngine(root, network);
    final m = LiveManager(e, e.net as MediaLink);
    engines.add(e);
    managers.add(m);
    return (e, m);
  }

  test('going live announces it; viewers join, hear, see and chat', () async {
    final (host, hm) = await node();
    final (v1, m1) = await node();
    final (v2, m2) = await node();
    final channel = await host.createBroadcast('Studio');
    final live = await hm.start(channel, title: 'Friday set');
    final post = host.db.item(live.postId!)!;
    expect((post.body['live'] as Map)['id'], live.id);
    expect(post.e.sane, isTrue);

    await m1.watch(host.me.id, channel.id, live.id);
    await m2.watch(host.me.id, channel.id, live.id);
    await eventually(() => live.viewers.length == 2 && m1.current!.joined && m2.current!.joined);

    for (var i = 0; i < 6; i++) {
      hm.sendAudio(tone(321));
    }
    hm.sendVideo(Uint8List.fromList(List.generate(2500, (i) => i % 200)));
    await eventually(() {
      m1.drain();
      return m1.current!.frame != null;
    });
    expect(m1.current!.frame!.length, 2500);
    expect(ByteData.sublistView(m1.pull()).getInt16(0, Endian.little), 321);

    m1.sendChat('hello from the front row');
    m2.sendHeart();
    await eventually(() {
      hm.drain();
      return live.chat.isNotEmpty && live.hearts == 1;
    });
    expect(live.chat.single.from, v1.me.id);
    await eventually(() {
      m2.drain();
      return m2.current!.chat.any((c) => c.text == 'hello from the front row' && c.from == v1.me.id);
    });

    await hm.stop();
    await eventually(() => !m1.current!.live && !m2.current!.live);
    expect(host.post(post.id)!.text, startsWith('Was live'));
    expect(v2.me.id, isNotEmpty);
  });

  test('a full stream turns viewers away and a stranger cannot inject chat', () async {
    final (host, hm) = await node();
    final channel = await host.createBroadcast('Studio');
    final live = await hm.start(channel);
    final watchers = <LiveManager>[];
    for (var i = 0; i < LiveManager.maxViewers; i++) {
      final (_, m) = await node();
      await m.watch(host.me.id, channel.id, live.id);
      watchers.add(m);
    }
    await eventually(() => live.viewers.length == LiveManager.maxViewers);
    final (_, late) = await node();
    await late.watch(host.me.id, channel.id, live.id);
    await eventually(() => late.current!.reason == 'full');

    // Someone outside the stream pushes a chat packet at the host.
    final (eve, _) = await node();
    (eve.net as TestTransport).callListen(live.id, [host.me.id]);
    (eve.net as TestTransport).callDial(live.id, host.me.id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    (eve.net as TestTransport).callSend(live.id, LivePacket.encode({'t': 'chat', 'text': 'spam'}));
    hm.drain();
    expect(live.chat, isEmpty);
  });

  test('live markers are validated', () async {
    final me = await Identity.generate();
    Future<bool> sane(String scope, Object? live) async =>
        (await Envelope.create(me, kind: K.post, scope: scope, body: {'text': 'x', 'live': live})).sane;
    expect(await sane(Scope.bcast(me.id, 'c1'), {'id': 'abcdef123456', 'video': true}), isTrue);
    expect(await sane(Scope.feed(me.id), {'id': 'abcdef123456'}), isFalse, reason: 'only on channel posts');
    expect(await sane(Scope.bcast(me.id, 'c1'), {'id': '../x'}), isFalse);
    expect(await sane(Scope.bcast(me.id, 'c1'), 'live'), isFalse);
  });
}
