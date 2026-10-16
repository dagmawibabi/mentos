import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/link_preview.dart';
import 'package:mentos/net/live_loc.dart';
import 'package:mentos/net/views.dart';

import 'support/fake_net.dart';

void main() {
  test('link text and html become a preview card', () {
    expect(firstHttpUrl('see https://example.com/a.'), 'https://example.com/a');
    expect(firstHttpUrl('no link here'), isNull);
    expect(isPublicHttpUrl(Uri.parse('https://example.com/a')), isTrue);
    expect(isPublicHttpUrl(Uri.parse('http://127.0.0.1/secret')), isFalse);
    expect(isPublicHttpUrl(Uri.parse('http://10.1.2.3/')), isFalse);
    expect(isPublicHttpUrl(Uri.parse('http://192.168.0.4/')), isFalse);
    expect(isPublicHttpUrl(Uri.parse('file:///tmp/x')), isFalse);

    final page = Uri.parse('https://example.com/news');
    final preview = parseLinkPreview('''
<html><head>
<meta property="og:title" content="Hello &amp; co">
<meta content="A short description" property="og:description">
<meta property="og:image" content="/cover.jpg">
<title>Ignored</title>
</head></html>
''', page);
    expect(preview.title, 'Hello & co');
    expect(preview.description, 'A short description');
    expect(preview.image, 'https://example.com/cover.jpg');
    expect(preview.site, 'example.com');
    expect(LinkPreview.fromJson(preview.toJson())!.title, 'Hello & co');
    expect(LinkPreview.fromJson({'u': 'http://127.0.0.1/', 'ti': 'nope'}), isNull);
  });

  test('a local page can be read when the caller allows it', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      req.response.headers.contentType = ContentType.html;
      req.response.write('<html><head><meta property="og:title" content="Local"></head></html>');
      req.response.close();
    });
    final blocked = await fetchLinkPreview('http://127.0.0.1:${server.port}/');
    expect(blocked, isNull);
    final preview = await fetchLinkPreview(
      'http://127.0.0.1:${server.port}/post',
      allow: (_) => true,
    );
    expect(preview!.title, 'Local');
    expect(preview.site, '127.0.0.1');
  });

  test('a newer fix wins, a stranger cannot move it, and a caption edit keeps it', () async {
    final me = await Identity.generate();
    final msg = await Envelope.create(me, kind: K.msg, scope: 'dm:a:b', body: {
      'text': '',
      'loc': {'lat': 1, 'lng': 2, 'ts': 10, 'until': 9 << 40},
    });
    Future<Item> edit(Identity who, Map<String, dynamic> body, int ts) async => Item(
          await Envelope.create(who, kind: K.edit, scope: 'dm:a:b', body: body, ts: ts),
          owned: who == me,
          kept: false,
        );
    final stranger = await Identity.generate();
    final base = Item(msg, owned: true, kept: false);
    final folded = fold([
      await edit(me, {'target': msg.id, 'loc': {'lat': 3, 'lng': 4, 'ts': 5, 'until': 9 << 40}}, 20),
      await edit(me, {
        'target': msg.id,
        'loc': {'lat': 9.1, 'lng': 38.7, 'ts': 30, 'until': 9 << 40, 'p': [[1.0, 2.0], [9.1, 38.7]]},
      }, 40),
      await edit(stranger, {'target': msg.id, 'loc': {'lat': 0, 'lng': 0, 'ts': 100, 'until': 9 << 40}}, 60),
      await edit(me, {'target': msg.id, 'text': 'on the way'}, 70),
    ], {msg.id: base});
    final fix = LiveFix.latest(base.body['loc'], folded.locs[msg.id])!;
    expect(fix.lat, closeTo(9.1, 0.0001));
    expect(fix.path.length, 2);
    expect(fix.path.last.$1, closeTo(9.1, 0.0001));
    expect(folded.edited[msg.id]!.text, 'on the way');
    expect(LiveFix.parse({'lat': 120, 'lng': 0, 'ts': 1, 'until': 2}), isNull);
  });

  test('live location and link previews reach the other person', () async {
    final root = await Directory.systemTemp.createTemp('mentos-preview-');
    final network = TestNetwork();
    final engines = <Engine>[];
    addTearDown(() async {
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

    final a = await node();
    final b = await node();
    final scope = Scope.dm(a.me.id, b.me.id);
    final until = nowMs() + 600000;
    final msg = await a.sendMessage(scope, loc: {
      'lat': 9.03,
      'lng': 38.74,
      'ts': nowMs(),
      'until': until,
      'p': [[9.03, 38.74]],
    }, preview: {
      'u': 'http://10.0.0.8/',
      'ti': 'private',
    });
    expect(a.messages(scope).single.loc!.lat, closeTo(9.03, 0.0001));
    expect(a.messages(scope).single.preview, isNull, reason: 'a private address is not a preview');

    final linked = await a.sendMessage(scope, text: 'see https://example.com/a', preview: {
      'u': 'https://example.com/a',
      'ti': 'Example',
      'd': 'A page',
      'h': 'example.com',
      'im': 'https://example.com/cover.jpg',
    });
    await a.flushDeliveries();
    await eventually(() => b.messages(scope).length >= 2);
    final theirs = b.messages(scope).singleWhere((m) => m.id == linked.id);
    expect(theirs.preview!.title, 'Example');
    expect(theirs.preview!.image, 'https://example.com/cover.jpg');

    await a.publishLiveFix(scope, msg.id, {
      'lat': 9.05,
      'lng': 38.76,
      'ts': nowMs() + 5000,
      'until': until,
      'acc': 12,
      'p': [[9.03, 38.74], [9.05, 38.76]],
    });
    await eventually(() {
      final found = b.messages(scope).where((m) => m.id == msg.id);
      if (found.length != 1) return false;
      final loc = found.single.loc;
      return loc != null && loc.lat > 9.04;
    });
    final moved = b.messages(scope).singleWhere((m) => m.id == msg.id);
    expect(moved.loc!.path.length, 2);
    expect(moved.edited, isFalse);
    expect(metersBetween(9.03, 38.74, 9.05, 38.76), greaterThan(1000));
  });
}
