import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/features/feed/stories.dart';
import 'package:mentos/net/engine.dart';

import 'support/fake_net.dart';

void main() {
  group('sticker validation', () {
    test('accepts good stickers and clamps positions', () {
      final s = StorySticker.fromJson({'t': 'link', 'v': 'https://iroh.computer', 'x': 4, 'y': -1, 's': 9})!;
      expect((s.x, s.y, s.scale), (1.0, 0.0, 3.0));
      expect(StorySticker.fromJson(const StorySticker(kind: StickerKind.ask, value: 'Q?').toJson())!.value, 'Q?');
    });

    test('rejects unsafe or malformed stickers', () {
      expect(StorySticker.fromJson({'t': 'link', 'v': 'javascript:alert(1)'}), isNull);
      expect(StorySticker.fromJson({'t': 'link', 'v': 'file:///etc/passwd'}), isNull);
      expect(StorySticker.fromJson({'t': 'mention', 'v': 'not-a-key'}), isNull);
      expect(StorySticker.fromJson({'t': 'emoji', 'v': 'x' * 40}), isNull);
      expect(StorySticker.fromJson({'t': 'nope', 'v': 'x'}), isNull);
      expect(StorySticker.fromJson({'t': 'text', 'v': 'hi', 'x': double.nan})!.x, .5);
      expect(StorySticker.listFrom([1, null, {'t': 'emoji', 'v': '🔥'}]).length, 1);
    });

    test('envelopes: stickers only on stories, reactions allowed on stories', () async {
      final me = await Identity.generate();
      final good = await Envelope.create(me, kind: K.story, scope: Scope.story(me.id), body: {
        'stk': [const StorySticker(kind: StickerKind.emoji, value: '🔥').toJson()],
      });
      expect(good.sane, isTrue);
      final bad = await Envelope.create(me, kind: K.story, scope: Scope.story(me.id), body: {
        'stk': [{'t': 'link', 'v': 'javascript:x'}],
      });
      expect(bad.sane, isFalse);
      final onMsg = await Envelope.create(me, kind: K.msg, scope: Scope.dm(me.id, 'a' * 64), body: {
        'stk': [const StorySticker(kind: StickerKind.emoji, value: '🔥').toJson()],
      });
      expect(onMsg.sane, isFalse);
      final react = await Envelope.create(me, kind: K.react, scope: Scope.story('b' * 64), body: {'target': 'x', 'emoji': '🔥'});
      expect(react.sane, isTrue);
      final reactOnFeed = await Envelope.create(me, kind: K.react, scope: Scope.feed('b' * 64), body: {'target': 'x', 'emoji': '🔥'});
      expect(reactOnFeed.sane, isFalse);
    });
  });

  group('engine', () {
    late Directory root;
    late TestNetwork network;
    late List<Engine> engines;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('mentos-stories-');
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

    test('a reaction reaches the story author, and a reply lands in their DMs', () async {
      final a = await openEngine(root, network);
      final b = await openEngine(root, network);
      engines.addAll([a, b]);
      await a.createStory(text: 'sunset', stickers: const [StorySticker(kind: StickerKind.ask, value: 'Best place?')]);
      final story = a.db.browseItems(kind: K.story).single;
      final notes = <OsNote>[];
      a.notes.listen(notes.add);

      await b.react(story.e.scope, story.id, '🔥');
      await eventually(() => a.storyStats(story).reactions[b.me.id] == '🔥');
      expect(a.db.activity().any((x) => x.kind == 'react' && x.actor == b.me.id), isTrue);
      await eventually(() => notes.any((n) => n.category == 'like' && n.body.contains('🔥')));

      final seen = Item(story.e, owned: false, kept: false);
      await b.storyReply(seen, 'the beach', prompt: 'Best place?');
      await b.flushDeliveries();
      final dm = Scope.dm(a.me.id, b.me.id);
      await eventually(() => a.messages(dm).isNotEmpty);
      final m = a.messages(dm).single;
      expect(m.text, 'the beach');
      expect((m.item.body['story'] as Map)['prompt'], 'Best place?');
      expect((m.item.body['story'] as Map)['id'], story.id);
    });
  });

  testWidgets('story viewer renders stickers and the composer opens', (tester) async {
    late Engine a;
    final root = await tester.runAsync(() => Directory.systemTemp.createTemp('mentos-stories-ui-'));
    await tester.runAsync(() async {
      a = await openEngine(root!, TestNetwork());
      await a.createStory(text: 'hello', stickers: [
        const StorySticker(kind: StickerKind.text, value: 'big news'),
        const StorySticker(kind: StickerKind.link, value: 'https://iroh.computer', label: 'iroh'),
        StorySticker(kind: StickerKind.mention, value: a.me.id),
      ]);
    });
    await pumpScreen(tester, a, StoryViewer(author: a.me.id));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('big news'), findsOneWidget);
    expect(find.text('iroh'), findsOneWidget);
    expect(find.text('@You'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pumpScreen(tester, a, const StoryComposer());
    await tester.pump();
    expect(find.byTooltip('Stickers'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 7));
    await tester.runAsync(() async {
      await a.stop();
      a.db.close();
      await root!.delete(recursive: true);
    });
  });
}
