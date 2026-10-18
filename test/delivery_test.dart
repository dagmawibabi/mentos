import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'support/fake_net.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mentos/core/theme/app_theme.dart';
import 'package:mentos/core/theme/tokens.dart';
import 'package:mentos/features/chats/bubble.dart';
import 'package:mentos/state/providers.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/db.dart';
import 'package:mentos/data/delivery.dart';
import 'package:mentos/data/media_store.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/transport.dart';
import 'package:mentos/state/settings.dart';

void main() {
  late Directory root;
  late TestNetwork network;
  late List<Engine> engines;

  Future<Engine> node({
    Identity? identity,
    String? path,
    bool online = true,
  }) async {
    final me = identity ?? await Identity.generate();
    final dir = Directory(path ?? '${root.path}/${me.id}');
    await dir.create(recursive: true);
    final db = Db.open('${dir.path}/test.db', toHex(sha256(me.seed)));
    final net = TestTransport(network, me.id)..online = online;
    final engine = Engine(
      me: me,
      db: db,
      net: net,
      media: MediaStore(dir.path, db, net),
      settings: const Settings(),
    );
    engines.add(engine);
    await engine.start('${dir.path}/node');
    return engine;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-delivery-test-');
    network = TestNetwork();
    engines = [];
  });
  tearDown(() async {
    for (final gate in network.sendGates.values) {
      if (!gate.isCompleted) gate.complete(false);
    }
    network.sendGate?.complete(false);
    for (final engine in engines) {
      await engine.stop();
      engine.db.close();
      await (engine.net as TestTransport).controller.close();
    }
    // Only delete the temporary tree created by this test.
    final parent = Directory.systemTemp.absolute.path;
    if (!root.absolute.path.startsWith('$parent${Platform.pathSeparator}') ||
        !root.path.contains('mentos-delivery-test-')) {
      throw StateError('Unexpected test directory');
    }
    await root.delete(recursive: true);
  });

  test(
    'offline messages survive restart and deliver after reconnect',
    () async {
      final a = await node(online: false);
      final b = await node();
      final scope = Scope.dm(a.me.id, b.me.id);
      final msg = await a.sendMessage(scope, text: 'persist me');
      expect(a.messages(scope).single.delivery, Delivery.queued);
      await a.stop();
      a.db.close();
      engines.remove(a);
      await (a.net as TestTransport).controller.close();
      final restored = await node(identity: a.me);
      await restored.flushDeliveries();
      await eventually(
        () => restored.db.deliveries(msg.id).single.state == Delivery.delivered,
      );
      expect(b.messages(scope).single.text, 'persist me');
    },
  );

  test(
    'cancelled jobs survive restart and are excluded from history',
    () async {
      final a = await node(online: false);
      final b = await node();
      final scope = Scope.dm(a.me.id, b.me.id);
      final msg = await a.sendMessage(scope, text: 'not for history');
      a.cancelMessage(msg.id);
      await a.stop();
      a.db.close();
      engines.remove(a);
      await (a.net as TestTransport).controller.close();
      final restored = await node(identity: a.me);
      (restored.net as TestTransport).controller.add(LinkEvent(b.me.id, true));
      await restored.flushDeliveries();
      await b.query(a.me.id, scope);
      expect(restored.db.deliveries(msg.id).single.state, Delivery.cancelled);
      expect(b.messages(scope), isEmpty);
    },
  );

  test('legacy queued messages migrate into durable recipient jobs', () async {
    final a = await node(online: false);
    final b = await node();
    final scope = Scope.dm(a.me.id, b.me.id);
    final msg = await Envelope.create(
      a.me,
      kind: K.msg,
      scope: scope,
      body: {'text': 'old queue'},
    );
    a.db.putItem(msg, owned: true);
    a.db.enqueueOutbox(
      msg.id,
      b.me.id,
      jsonEncode({'t': 'item', 'e': msg.toWire()}),
    );
    await a.stop();
    a.db.close();
    engines.remove(a);
    await (a.net as TestTransport).controller.close();
    final restored = await node(identity: a.me);
    await restored.flushDeliveries();
    await eventually(
      () => restored.db.deliveries(msg.id).single.state == Delivery.delivered,
    );
    expect(restored.db.outboxIds(), isNot(contains(msg.id)));
  });

  test('concurrent flush requests make only one in-flight attempt', () async {
    final a = await node();
    final b = await node();
    network.sendGate = Completer<bool>();
    final msg = await a.sendMessage(
      Scope.dm(a.me.id, b.me.id),
      text: 'one attempt',
    );
    await eventually(
      () => a.db.deliveries(msg.id).single.state == Delivery.sending,
    );
    final flushes = List.generate(8, (_) => a.flushDeliveries());
    final gate = network.sendGate!;
    network.sendGate = null;
    gate.complete(true);
    await Future.wait(flushes);
    await eventually(
      () => a.db.deliveries(msg.id).single.state == Delivery.delivered,
    );
    expect(
      network.messages.where(
        (m) => Envelope.fromWire(m.body['e'])?.id == msg.id,
      ),
      hasLength(1),
    );
  });

  test(
    'receipt does not confirm another message with the same timestamp',
    () async {
      final a = await node(online: false);
      final b = await node();
      final scope = Scope.dm(a.me.id, b.me.id);
      final ts = nowMs();
      final one = await Envelope.create(
        a.me,
        kind: K.msg,
        scope: scope,
        ts: ts,
        body: {'text': 'one'},
      );
      final two = await Envelope.create(
        a.me,
        kind: K.msg,
        scope: scope,
        ts: ts,
        body: {'text': 'two'},
      );
      a.db.queueMessage(one, [b.me.id]);
      a.db.queueMessage(two, [b.me.id]);
      a.db.acknowledgeMessage(one.id, b.me.id, scope);
      expect(a.db.deliveries(one.id).single.state, Delivery.delivered);
      expect(a.db.deliveries(two.id).single.state, Delivery.queued);
    },
  );

  testWidgets('bubble stop and retry controls work at phone width', (
    tester,
  ) async {
    late Engine a;
    late String scope;
    late String id;
    await tester.runAsync(() async {
      a = await node(online: false);
      final peer = await Identity.generate();
      scope = Scope.dm(a.me.id, peer.id);
      id = (await a.sendMessage(scope, text: 'offline message')).id;
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<void> render() => tester.pumpWidget(
      ProviderScope(
        overrides: [engineProvider.overrideWithValue(a)],
        child: MaterialApp(
          theme: buildTheme(Palette.light),
          home: Scaffold(
            body: Bubble(
              m: a.messages(scope).single,
              scope: scope,
              firstInGroup: true,
              lastInGroup: true,
              showAuthor: false,
              onLongPress: () {},
              onReply: () {},
            ),
          ),
        ),
      ),
    );
    await render();
    // The meter is bars and an arrow; its state is spoken, not printed.
    expect(find.text('Waiting to send'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith('Waiting to send')), findsWidgets);
    await tester.tap(find.byKey(ValueKey('delivery-progress:$id')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Stop retrying'));
    await tester.tap(find.byTooltip('Close delivery details'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await render();
    expect(a.db.deliveries(id).single.state, Delivery.cancelled);
    expect(find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith('Retries cancelled')), findsWidgets);
    await tester.tap(find.byKey(ValueKey('delivery-progress:$id')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Retry'));
    await tester.tap(find.byTooltip('Close delivery details'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await render();
    expect(a.db.deliveries(id).single.state, Delivery.queued);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('lost acknowledgment is repaired by an idempotent retry', () async {
    final a = await node();
    final b = await node();
    network.dropAcks = true;
    final scope = Scope.dm(a.me.id, b.me.id);
    final msg = await a.sendMessage(scope, text: 'only once');
    await a.flushDeliveries();
    await eventually(() => b.messages(scope).length == 1);
    expect(a.db.deliveries(msg.id).single.state, Delivery.sent);
    network.dropAcks = false;
    a.db.reviveDeliveries(b.me.id);
    await a.flushDeliveries();
    await eventually(
      () => a.db.deliveries(msg.id).single.state == Delivery.delivered,
    );
    expect(b.messages(scope), hasLength(1));
    b.markRead(scope);
    await eventually(
      () => a.db.deliveries(msg.id).single.state == Delivery.read,
    );
  });

  test('ACK must match both the message and authenticated recipient', () async {
    final a = await node(online: false);
    final b = await node();
    final stranger = await node();
    final scope = Scope.dm(a.me.id, b.me.id);
    final msg = await a.sendMessage(scope, text: 'private');
    final transport = a.net as TestTransport;
    transport.controller.add(
      DirectEvent(
        stranger.me.id,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              't': 'ack',
              'id': msg.id,
              'scope': scope,
              'ts': nowMs(),
            }),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(a.db.deliveries(msg.id).single.state, Delivery.queued);
    a.db.acknowledgeMessage(msg.id, b.me.id, 'wrong-scope');
    expect(a.db.deliveries(msg.id).single.state, Delivery.queued);
  });

  test(
    'cancel while sending cannot be overwritten by transport completion',
    () async {
      final a = await node();
      final b = await node();
      network.sendGate = Completer<bool>();
      final scope = Scope.dm(a.me.id, b.me.id);
      final msg = await a.sendMessage(scope, text: 'cancel');
      await eventually(
        () => a.db.deliveries(msg.id).single.state == Delivery.sending,
      );
      a.cancelMessage(msg.id);
      final gate = network.sendGate!;
      network.sendGate = null;
      gate.complete(false);
      await a.flushDeliveries();
      expect(a.db.deliveries(msg.id).single.state, Delivery.cancelled);
      a.db.reviveDeliveries(b.me.id);
      await a.flushDeliveries();
      expect(b.messages(scope), isEmpty);
      a.retryMessage(msg.id);
      await a.flushDeliveries();
      await eventually(
        () => a.db.deliveries(msg.id).single.state == Delivery.delivered,
      );
    },
  );

  test(
    'group retries preserve recipients that have already acknowledged',
    () async {
      final a = await node();
      final b = await node();
      final c = await node(online: false);
      final group = GroupInfo(
        id: newId(),
        name: 'group',
        owner: a.me.id,
        key: base64Encode(randomBytes(32)),
        members: [b.me.id, c.me.id],
      );
      for (final e in [a, b, c]) {
        e.db.putGroup(group);
      }
      final msg = await a.sendMessage(Scope.gdm(group.id), text: 'hello group');
      await a.flushDeliveries();
      await eventually(
        () => a.db
            .deliveries(msg.id)
            .any((r) => r.peer == b.me.id && r.state == Delivery.delivered),
      );
      final sentToB = network.messages
          .where(
            (m) =>
                m.to == b.me.id && Envelope.fromWire(m.body['e'])?.id == msg.id,
          )
          .length;
      a.cancelMessage(msg.id);
      (c.net as TestTransport).online = true;
      a.retryMessage(msg.id);
      await a.flushDeliveries();
      await eventually(
        () =>
            a.db.deliveries(msg.id).every((r) => r.state == Delivery.delivered),
      );
      expect(
        network.messages
            .where(
              (m) =>
                  m.to == b.me.id &&
                  Envelope.fromWire(m.body['e'])?.id == msg.id,
            )
            .length,
        sentToB,
      );
    },
  );

  test('delete and expiry remove every pending content job', () async {
    final a = await node(online: false);
    final b = await node();
    final scope = Scope.dm(a.me.id, b.me.id);
    final msg = await a.sendMessage(scope, text: 'delete');
    a.deleteLocal(a.db.item(msg.id)!);
    expect(a.db.deliveries(msg.id), isEmpty);
    final expired = await Envelope.create(
      a.me,
      kind: K.msg,
      scope: scope,
      body: {'text': 'expired', 'exp': nowMs() - 1},
    );
    a.db.queueMessage(expired, [b.me.id]);
    a.db.enqueueOutbox(
      expired.id,
      b.me.id,
      jsonEncode({'t': 'item', 'e': expired.toWire()}),
    );
    a.db.deleteExpired(nowMs());
    expect(a.db.deliveries(expired.id), isEmpty);
    expect(a.db.outboxIds(), isNot(contains(expired.id)));
    (a.net as TestTransport).online = true;
    await a.flushDeliveries();
    expect(b.messages(scope), isEmpty);
  });

  test(
    'failed recipients can retry and confirmed states never regress',
    () async {
      final a = await node(online: false);
      final b = await node();
      final scope = Scope.dm(a.me.id, b.me.id);
      final msg = await a.sendMessage(scope, text: 'failure');
      for (var i = 0; i < 6; i++) {
        final job = a.db.deliveries(msg.id).single;
        expect(a.db.beginDelivery(job), isTrue);
        a.db.finishDelivery(job, sent: false);
      }
      expect(a.messages(scope).single.canRetry, isTrue);
      expect(a.messages(scope).single.delivery, Delivery.failed);
      a.retryMessage(msg.id);
      final job = a.db.deliveries(msg.id).single;
      expect(a.db.beginDelivery(job), isTrue);
      a.db.acknowledgeMessage(msg.id, b.me.id, scope, read: true);
      a.db.finishDelivery(job, sent: false);
      a.db.acknowledgeMessage(msg.id, b.me.id, scope);
      expect(a.db.deliveries(msg.id).single.state, Delivery.read);
    },
  );

  test(
    'out-of-order unread message does not inherit an earlier read receipt',
    () async {
      final a = await node();
      final b = await node();
      final scope = Scope.dm(a.me.id, b.me.id);
      final first = await a.sendMessage(scope, text: 'newer');
      await a.flushDeliveries();
      await eventually(() => b.messages(scope).length == 1);
      b.markRead(scope);
      await eventually(
        () => a.db.deliveries(first.id).single.state == Delivery.read,
      );
      final older = await Envelope.create(
        a.me,
        kind: K.msg,
        scope: scope,
        ts: first.ts - 1000,
        body: {'text': 'arrived later'},
      );
      a.db.queueMessage(older, [b.me.id]);
      await a.flushDeliveries();
      await eventually(
        () => a.db.deliveries(older.id).single.state == Delivery.delivered,
      );
      expect(b.db.wasMessageRead(older.id), isFalse);
      b.markRead(scope);
      await eventually(
        () => a.db.deliveries(older.id).single.state == Delivery.read,
      );
    },
  );

  test(
    'a connected peer is sent while offline followers stay queued',
    () async {
      final a = await node();
      final b = await node();
      (a.net as TestTransport).controller.add(LinkEvent(b.me.id, true));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final parked = <String>[];
      for (var i = 0; i < 40; i++) {
        final peer = await Identity.generate();
        final env = await Envelope.create(
          a.me,
          kind: K.msg,
          scope: Scope.dm(a.me.id, peer.id),
          body: {'text': 'parked $i'},
        );
        a.db.queueMessage(env, [peer.id]);
        parked.add(env.id);
      }
      final scope = Scope.dm(a.me.id, b.me.id);
      final msg = await a.sendMessage(scope, text: 'live');
      await eventually(
        () => a.db.deliveries(msg.id).single.state == Delivery.delivered,
      );
      expect(b.messages(scope).map((m) => m.item.id), contains(msg.id));
      for (final id in parked) {
        final job = a.db.deliveries(id).single;
        expect(job.state, Delivery.queued);
        expect(job.attempts, 0);
      }
    },
  );

  test(
    'a stalled recipient does not block a newly connected recipient',
    () async {
      final a = await node();
      final b = await node();
      final c = await node();
      final gate = Completer<bool>();
      network.sendGates[b.me.id] = gate;
      final blocked = await a.sendMessage(
        Scope.dm(a.me.id, b.me.id),
        text: 'blocked',
      );
      await eventually(
        () => a.db.deliveries(blocked.id).single.state == Delivery.sending,
      );
      (a.net as TestTransport).controller.add(LinkEvent(c.me.id, true));
      final live = await a.sendMessage(
        Scope.dm(a.me.id, c.me.id),
        text: 'live',
      );
      await eventually(
        () => a.db.deliveries(live.id).single.state == Delivery.delivered,
      );
      expect(gate.isCompleted, isFalse);
      gate.complete(true);
      await a.flushDeliveries();
    },
  );

  test('a message queued during a send wakes the same recipient', () async {
    final a = await node();
    final b = await node();
    final scope = Scope.dm(a.me.id, b.me.id);
    final gate = Completer<bool>();
    network.sendGates[b.me.id] = gate;
    final first = await a.sendMessage(scope, text: 'first');
    await eventually(() => a.db.deliveries(first.id).single.state == Delivery.sending);
    final second = await a.sendMessage(scope, text: 'second');
    final flushed = a.flushDeliveries();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete(true);
    await flushed;
    await eventually(() => a.db.deliveries(second.id).single.state == Delivery.delivered);
    expect(b.messages(scope), hasLength(2));
  });
}
