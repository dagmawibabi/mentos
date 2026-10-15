import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/core/theme/app_theme.dart';
import 'package:mentos/core/theme/tokens.dart';
import 'package:mentos/data/delivery.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/features/chats/seen_by.dart';
import 'package:mentos/features/feed/post_card.dart';
import 'package:mentos/net/engine.dart';

import 'support/fake_net.dart';

void main() {
  late Directory root;
  late TestNetwork network;
  late List<Engine> engines;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-views-');
    network = TestNetwork();
    engines = [];
  });
  tearDown(() async {
    for (final e in engines) {
      await e.stop();
      e.db.close();
    }
    await root.delete(recursive: true);
  });

  Future<Engine> node() async {
    final e = await openEngine(root, network);
    engines.add(e);
    return e;
  }

  Future<void> viewBy(Engine author, Identity viewer, Envelope post) async {
    final v = await Envelope.create(viewer,
        kind: K.view, scope: Scope.post(author.me.id, post.id), body: {'target': post.id}, keep: true);
    expect(await author.ingest(v, via: viewer.id), isTrue);
  }

  test('views from others are counted once each and kept by the author', () async {
    final a = await node();
    final post = await a.createPost(text: 'hello world');
    final v1 = await Identity.generate();
    final v2 = await Identity.generate();
    await viewBy(a, v1, post);
    await viewBy(a, v2, post);
    await viewBy(a, v1, post); // a second view by the same person
    final pv = a.post(post.id)!;
    expect(pv.views, 2);
    expect(pv.viewers.toSet(), {v1.id, v2.id});
    expect(a.db.browseItems(kind: K.view).length, 3, reason: 'each signed view is kept with consent, so counts survive restart');
  });

  test('recording a view is signed once and carries reply consent', () async {
    final a = await node();
    final b = await node();
    final post = await a.createPost(text: 'x');
    final item = Item(post, owned: false, kept: false);
    await b.recordView(item);
    await b.recordView(item);
    final views = b.db.browseItems(kind: K.view);
    expect(views.length, 1);
    expect(views.single.e.keep, isTrue);
    expect(views.single.e.scope, Scope.post(a.me.id, post.id));
  });

  test('read receipts record when each recipient read', () async {
    final a = await node();
    final b = await node();
    final scope = Scope.dm(a.me.id, b.me.id);
    final msg = await a.sendMessage(scope, text: 'read me');
    await a.flushDeliveries();
    await eventually(() => a.db.deliveries(msg.id).single.state == Delivery.delivered);
    final delivered = a.db.deliveries(msg.id).single;
    expect(delivered.deliveredAt, isNotNull);
    expect(delivered.readAt, isNull);
    b.markRead(scope);
    await b.flushDeliveries();
    await eventually(() {
      unawaited(b.reconnect());
      return a.db.deliveries(msg.id).single.state == Delivery.read;
    });
    final read = a.db.deliveries(msg.id).single;
    expect(read.readAt, greaterThanOrEqualTo(read.deliveredAt!));
  });

  testWidgets('seen-by lists readers first with times', (tester) async {
    final now = nowMs();
    final list = [
      const RecipientDelivery(id: 'm', peer: 'c', state: Delivery.sent),
      RecipientDelivery(id: 'm', peer: 'b', state: Delivery.delivered, deliveredAt: now),
      RecipientDelivery(id: 'm', peer: 'a', state: Delivery.read, deliveredAt: now, readAt: now),
    ];
    expect(SeenBy.sorted(list).map((r) => r.peer), ['a', 'b', 'c']);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? picked;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Palette.light),
      home: Scaffold(body: SeenBy(recipients: list, nameOf: (id) => 'Person $id', onSelect: (id) => picked = id)),
    ));
    expect(find.text('Seen by 1 of 3 · 1 delivered · 1 waiting'), findsOneWidget);
    expect(find.text('read now'), findsOneWidget);
    await tester.tap(find.text('Person b'));
    expect(picked, 'b');
  });

  testWidgets('own post card shows views and opens the viewer list', (tester) async {
    late Engine a;
    late Identity v;
    late Envelope post;
    await tester.runAsync(() async {
      a = await node();
      post = await a.createPost(text: 'counted');
      v = await Identity.generate();
      await viewBy(a, v, post);
    });
    await pumpScreen(tester, a, Scaffold(body: Consumer(builder: (_, ref, _) => PostCard(post: a.post(post.id)!))));
    await tester.pump();
    expect(find.byIcon(Icons.bar_chart_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.bar_chart_rounded));
    await tester.pumpAndSettle();
    expect(find.text('1 view'), findsOneWidget);
    expect(find.text(alias(v.id)), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
