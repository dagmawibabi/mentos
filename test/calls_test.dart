import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/call/calls.dart';
import 'package:mentos/net/call/media.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/transport.dart';

import 'support/fake_net.dart';

/// Stands in for microphone, camera and speaker.
class FakeDevices implements CallDevices {
  final micCtl = StreamController<Uint8List>.broadcast();
  final camCtl = StreamController<Uint8List>.broadcast();
  Uint8List Function()? puller;
  bool started = false;
  bool? video;

  @override
  Stream<Uint8List> get mic => micCtl.stream;
  @override
  Stream<Uint8List> get camera => camCtl.stream;
  @override
  Future<void> start({required bool video, required Uint8List Function() pull, bool capture = true}) async {
    started = true;
    this.video = video;
    puller = pull;
  }

  @override
  Future<void> setVideo(bool on) async => video = on;
  @override
  Future<void> switchCamera() async {}
  @override
  Future<void> stop() async => started = false;
}

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
  late List<CallManager> managers;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-calls-');
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

  Future<(Engine, CallManager, FakeDevices)> phone({Duration? ring}) async {
    final e = await openEngine(root, network);
    final d = FakeDevices();
    final m = CallManager(e, e.net as MediaLink, devices: d, ringFor: ring, connectFor: const Duration(seconds: 2));
    engines.add(e);
    managers.add(m);
    return (e, m, d);
  }

  test('a voice call rings, connects and carries audio both ways', () async {
    final (a, ma, da) = await phone();
    final (b, mb, db) = await phone();
    await ma.start([b.me.id]);
    await eventually(() => mb.current?.phase == CallPhase.incoming);
    expect(mb.current!.from, a.me.id);
    expect(b.db.activity().any((x) => x.kind == 'call'), isTrue);

    await mb.accept();
    await eventually(() => ma.current?.phase == CallPhase.active && mb.current?.phase == CallPhase.active);
    expect(da.started && db.started, isTrue);

    for (var i = 0; i < 4; i++) {
      da.micCtl.add(tone(1000));
      db.micCtl.add(tone(-500));
    }
    await eventually(() {
      ma.drain();
      mb.drain();
      return ma.jitterStats().isNotEmpty && mb.jitterStats().isNotEmpty;
    });
    final heardByB = ByteData.sublistView(db.puller!()).getInt16(0, Endian.little);
    final heardByA = ByteData.sublistView(da.puller!()).getInt16(0, Endian.little);
    expect(heardByB, 1000);
    expect(heardByA, -500);

    await ma.hangUp();
    await eventually(() => mb.current?.phase == CallPhase.ended);
    expect(ma.history().single.result, 'answered');
    expect(mb.history().single.result, 'answered');
  });

  test('muting stops audio from leaving the phone', () async {
    final (a, ma, da) = await phone();
    final (b, mb, _) = await phone();
    await ma.start([b.me.id]);
    await eventually(() => mb.current?.phase == CallPhase.incoming);
    await mb.accept();
    await eventually(() => ma.current?.phase == CallPhase.active);
    ma.setMic(false);
    await eventually(() => mb.current!.remote[a.me.id]?.mic == false);
    final before = (a.net as TestTransport).mediaSent;
    da.micCtl.add(tone(1));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect((a.net as TestTransport).mediaSent, before);
  });

  test('declined, busy and unanswered calls end with the right result', () async {
    final (_, ma, _) = await phone();
    final (b, mb, _) = await phone(ring: const Duration(milliseconds: 1500));
    final (c, mc, _) = await phone();

    await ma.start([b.me.id]);
    await eventually(() => mb.current?.phase == CallPhase.incoming);
    await mb.decline();
    await eventually(() => ma.current?.phase == CallPhase.ended);
    expect(ma.current!.reason, 'declined');

    // c is already in a call with b, so a hears busy.
    await mc.start([b.me.id]);
    await eventually(() => mb.current?.phase == CallPhase.incoming && mb.current!.from == c.me.id);
    await ma.start([b.me.id]);
    await eventually(() => ma.current?.phase == CallPhase.ended);
    expect(ma.current!.reason, 'busy');

    // b never answers c: missed on b's side after the ring time.
    await eventually(() => mb.current?.phase == CallPhase.ended);
    expect(mb.history().first.result, 'missed');
    expect(b.db.activity().where((x) => x.kind == 'call').isNotEmpty, isTrue);
  });

  test('a three-way call forms a full mesh and survives one person leaving', () async {
    final (a, ma, da) = await phone();
    final (b, mb, _) = await phone();
    final (c, mc, dc) = await phone();
    await ma.start([b.me.id, c.me.id]);
    await eventually(() => mb.current?.phase == CallPhase.incoming && mc.current?.phase == CallPhase.incoming);
    await mb.accept();
    await mc.accept();
    await eventually(() =>
        ma.current!.connected.length == 2 && mb.current!.connected.length == 2 && mc.current!.connected.length == 2);

    da.micCtl.add(tone(100));
    dc.micCtl.add(tone(200));
    da.micCtl.add(tone(100));
    dc.micCtl.add(tone(200));
    da.micCtl.add(tone(100));
    dc.micCtl.add(tone(200));
    await eventually(() {
      mb.drain();
      return mb.jitterStats().length == 2;
    });
    final mixed = ByteData.sublistView(mb.pull()).getInt16(0, Endian.little);
    expect(mixed, 300, reason: 'both speakers mixed');

    await mc.hangUp();
    await eventually(() => !ma.current!.connected.contains(c.me.id) && !mb.current!.connected.contains(c.me.id));
    expect(ma.current!.phase, CallPhase.active);
    expect(mb.current!.phase, CallPhase.active);
  });

  test('strangers cannot join, and bad offers are ignored', () async {
    final (a, ma, _) = await phone();
    final (b, mb, _) = await phone();
    final (eve, _, _) = await phone();
    await ma.start([b.me.id]);
    final id = ma.current!.id;
    // Eve learns the call id but was never allowed on either side.
    expect((eve.net as TestTransport).callListen(id, [a.me.id]), isTrue);
    (eve.net as TestTransport).callDial(id, a.me.id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ma.current!.connected, isEmpty);

    await eve.sendCallSignal(b.me.id, {'op': 'offer', 'id': 'x', 'members': [eve.me.id, b.me.id]});
    await eve.sendCallSignal(b.me.id, {'op': 'offer', 'id': 'abcdefgh123', 'members': [b.me.id]});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(mb.current?.from, isNot(eve.me.id));
    expect(() => ma.start([b.me.id]), throwsStateError);
  });
}
