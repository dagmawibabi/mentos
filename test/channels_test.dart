import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/features/spaces/broadcast_screen.dart';
import 'package:mentos/features/spaces/channels_screen.dart';
import 'package:mentos/net/engine.dart';

import 'support/fake_net.dart';

void main() {
  late Directory root;
  late TestNetwork network;
  late List<Engine> engines;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-chan-');
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

  test('subscriptions are signed, counted by the owner, and reversible', () async {
    final a = await openEngine(root, network);
    final b = await openEngine(root, network);
    engines.addAll([a, b]);
    final c = await a.createBroadcast('Dispatch', about: 'news');
    expect(a.isSubscribed(a.me.id, c.id), isTrue);
    expect(b.isSubscribed(a.me.id, c.id), isFalse);

    await b.subscribe(c, true);
    expect(b.isSubscribed(a.me.id, c.id), isTrue);
    expect(b.peerOf(a.me.id).iFollow, isTrue, reason: 'channel posts travel on the owner feed topic');
    await eventually(() => a.subscribers(c).contains(b.me.id));
    expect(a.db.activity().any((x) => x.kind == 'subscribe' && x.actor == b.me.id), isTrue);
    expect(a.db.activity().any((x) => x.kind == 'like'), isFalse, reason: 'a subscription is not a like');

    await b.subscribe(c, false);
    expect(b.isSubscribed(a.me.id, c.id), isFalse);
    await eventually(() => !a.subscribers(c).contains(b.me.id));
  });

  test('pin, comments and silent posts', () async {
    final a = await openEngine(root, network);
    engines.add(a);
    final c = await a.createBroadcast('Dispatch');
    final post = await a.createPost(text: 'first', bcastId: c.id, silent: true);
    expect(post.body['silent'], isTrue);
    expect(a.channelState(c), (pinned: null, comments: true));
    await a.setChannelState(c, pinned: post.id, comments: false);
    expect(a.channelState(c), (pinned: post.id, comments: false));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.setChannelState(c, comments: true);
    expect(a.channelState(c), (pinned: null, comments: true));
    expect(a.feed().where((p) => p.text.isEmpty), isEmpty, reason: 'channel edits do not show up as posts');
    final pv = a.post(post.id)!;
    expect(a.commentsOpen(pv), isTrue);
    await a.comment(pv, 'hi');
    expect(a.comments(pv).length, 1);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.setChannelState(c, comments: false);
    expect(a.commentsOpen(pv), isFalse);
    expect(a.comments(pv), isEmpty);
  });

  testWidgets('owner channel screen and directory render at phone width', (tester) async {
    late Engine a;
    late Bcast c;
    await tester.runAsync(() async {
      a = await openEngine(root, network);
      engines.add(a);
      c = await a.createBroadcast('Dispatch', about: 'what is new');
      final p = await a.createPost(text: 'pinned hello', bcastId: c.id);
      await a.setChannelState(c, pinned: p.id, comments: true);
    });
    await pumpScreen(tester, a, BroadcastScreen(owner: a.me.id, channelId: c.id));
    await tester.pump();
    expect(find.text('Dispatch'), findsOneWidget);
    expect(find.text('pinned hello'), findsNWidgets(2), reason: 'in the pinned bar and in the list');
    expect(find.byTooltip('Subscribers get notified'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pumpScreen(tester, a, const ChannelsScreen());
    await tester.pump();
    expect(find.text('YOURS'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
