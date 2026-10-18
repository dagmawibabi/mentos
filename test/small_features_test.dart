import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/features/feed/post_screen.dart';
import 'package:mentos/net/atlas.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/market/market.dart';
import 'package:mentos/net/views.dart';
import 'package:mentos/widgets/invite_card.dart';

import 'support/fake_net.dart';

Future<CommentView> _c(Identity me, String id, {String? replyTo}) async {
  await Future<void>.delayed(const Duration(milliseconds: 3));
  final e = await Envelope.create(me, kind: K.comment, scope: 'post:x:y', body: {'text': id});
  return CommentView(
    item: Item(e, owned: true, kept: false),
    text: id,
    likes: 0,
    liked: false,
    edited: false,
    replyTo: replyTo,
  );
}

void main() {
  test('comments form a tree with depth, reply counts and collapsing', () async {
    final me = await Identity.generate();
    final r1 = await _c(me, 'r1');
    final r2 = await _c(me, 'r2');
    final a = await _c(me, 'a', replyTo: r1.item.id);
    final b = await _c(me, 'b', replyTo: a.item.id);
    final c = await _c(me, 'c', replyTo: b.item.id);
    final d = await _c(me, 'd', replyTo: r1.item.id);
    final lost = await _c(me, 'lost', replyTo: 'missing');
    final list = [lost, d, c, b, a, r2, r1];
    final rows = threadComments(list, {});
    expect(rows.map((r) => r.c.text), ['r1', 'a', 'b', 'c', 'd', 'r2', 'lost']);
    expect(rows.map((r) => r.depth), [0, 1, 2, 3, 1, 0, 0]);
    expect(rows.first.replies, 4);
    expect(rows.last.orphan, isTrue);
    final folded = threadComments(list, {a.item.id});
    expect(folded.map((r) => r.c.text), ['r1', 'a', 'd', 'r2', 'lost']);
    expect(folded[1].replies, 2);
  });

  test('hashtags are found in any script, and invite links are stripped from text', () {
    expect(Engine.tagsIn('Fresh #Injera and #ቡና today #2026'), {'injera', 'ቡና', '2026'});
    expect(Engine.tagsIn('no tags # here'), isEmpty);
    const link = 'mentos://s/eyJ0ZXN0IjoxfQ';
    expect(firstInvite('join us $link now'), link);
    expect(withoutInvites('join us $link'), 'join us');
  });

  group('spaces', () {
    late Directory root;
    late TestNetwork network;
    late List<Engine> engines;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mentos-small-');
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

    Future<Engine> person() async {
      final e = await openEngine(root, network);
      engines.add(e);
      return e;
    }

    test('nodes announce signed beacons into the atlas, and opting out stops it', () async {
      final a = await person();
      final b = await person();
      final c = await person();
      await a.atlas!.announce(force: true);
      await b.atlas!.announce(force: true);
      await eventually(() => c.atlas!.nodes().map((x) => x.id).toSet().containsAll({a.me.id, b.me.id}));
      expect(c.atlas!.beacon(a.me.id)!.mode, 'standard');

      // A forged beacon for someone else is ignored.
      final real = c.atlas!.beacon(a.me.id)!;
      final forged = Beacon(id: real.id, relay: 'https://evil.example', mode: real.mode, links: 99, ts: real.ts + 1, sig: real.sig);
      await c.atlas!.onGossip(b.me.id, {'op': 'b', 'b': forged.toJson()});
      expect(c.atlas!.beacon(a.me.id)!.links, real.links);

      // A late joiner gets a snapshot when it links up.
      final late = await person();
      await a.atlas!.onPeer(late.me.id);
      await eventually(() => late.atlas!.beacon(b.me.id) != null);

      b.atlas!.announcing = false;
      expect(b.atlas!.announcing, isFalse);
    });

    test('a public space is listed network-wide and a stranger joins from the directory', () async {
      final owner = await person();
      final stranger = await person();
      final space = await owner.createSpace('Addis Makers', 'Builders and tinkerers');

      final link = await owner.spaceLink(space.id);
      final peek = await stranger.peekTicket(link);
      expect(peek!.kind, 'space');
      expect(peek.name, 'Addis Makers');
      expect(peek.known, isFalse);
      expect(stranger.db.space(space.id), isNull, reason: 'peeking must not join');

      await owner.updateSpace(space.id, (s) => s.copyWith(public: true));
      await eventually(() => stranger.market!.publicSpaces().any((l) => l.body['space'] == space.id));
      final entry = stranger.market!.publicSpaces().firstWhere((l) => l.body['space'] == space.id);
      expect(entry.title, 'Addis Makers');
      final joined = await stranger.openTicket(entry.body['invite'] as String);
      expect(joined, ('space', space.id));
      expect(stranger.db.space(space.id), isNotNull);
      expect(await stranger.spaceLink(space.id), entry.body['invite'], reason: 'members can pass on a public invite');

      await owner.updateSpace(space.id, (s) => s.copyWith(public: false));
      await eventually(() => stranger.market!.publicSpaces().every((l) => l.body['space'] != space.id));
      expect(stranger.market!.listing(entry.id)!.deleted, isTrue);
    });
  });
}
