import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/features/data/data_explorer_screen.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/engine_data.dart';
import 'package:mentos/state/settings.dart';

import 'support/fake_net.dart';

void main() {
  late Directory root;
  late TestNetwork network;
  late List<Engine> engines;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-data-');
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

  Future<Engine> seeded() async {
    final e = await openEngine(root, network, settings: const Settings(lockHash: 'abc123'));
    engines.add(e);
    e.updateSettings(e.settings);
    expect(e.db.getKv('settings'), contains('abc123'));
    for (var i = 0; i < 7; i++) {
      await e.createPost(text: 'post number $i');
    }
    await e.createPost(text: '100% real_deal');
    final peer = await Identity.generate();
    await e.sendMessage(Scope.dm(e.me.id, peer.id), text: 'hello there');
    await e.createSpace('Garden', 'plants');
    return e;
  }

  test('browse pages are stable and complete', () async {
    final e = await seeded();
    final all = e.db.browseItems(kind: K.post, limit: 1000);
    expect(all.length, 8);
    final seen = <String>[];
    ({int ts, String id})? before;
    while (true) {
      final page = e.db.browseItems(kind: K.post, before: before, limit: 3);
      seen.addAll(page.map((i) => i.id));
      if (page.length < 3) break;
      before = (ts: page.last.ts, id: page.last.id);
    }
    expect(seen, all.map((i) => i.id).toList());
    expect(seen.toSet().length, seen.length);
  });

  test('search treats % and _ literally', () async {
    final e = await seeded();
    expect(e.db.browseItems(query: '100%').map(itemSummary), ['100% real_deal']);
    expect(e.db.browseItems(query: 'l_d'), isNotEmpty);
    expect(e.db.browseItems(query: '_x_'), isEmpty);
    expect(e.db.browseItems(query: 'post n').length, 7);
  });

  test('stats and tables', () async {
    final e = await seeded();
    final kinds = {for (final k in e.db.kindStats()) k.kind: k};
    expect(kinds[K.post]!.count, 8);
    expect(kinds[K.post]!.owned, 8);
    expect(e.db.tableCounts()['spaces'], 1);
    expect(() => e.db.tableRows('sqlite_master'), throwsArgumentError);
    expect(e.db.fileBytes(), greaterThan(0));
  });

  test('export redacts secrets unless asked and keeps signatures valid', () async {
    final e = await seeded();
    final plain = e.exportData();
    final text = jsonEncode(plain);
    expect(text, isNot(contains('abc123')), reason: 'PIN hash redacted');
    expect(jsonEncode(e.exportData(secrets: true)), contains('abc123'));
    final space = e.spaces().single;
    expect(text, isNot(contains(space.key)), reason: 'space key redacted');
    expect(jsonEncode(e.exportData(secrets: true)), contains(space.key));

    final items = (plain['items'] as List).cast<Map<String, Object?>>();
    expect(items.length, e.db.tableCounts()['items']);
    for (final i in items) {
      final env = Envelope.fromParts(i['signedPayload'] as String, i['sig'] as String)!;
      expect(await env.verify(), isTrue);
    }

    final narrow = e.exportData(kind: K.msg);
    expect((narrow['items'] as List).length, 1);
    expect(narrow.containsKey('tables'), isFalse);

    final f = await e.writeExport(Directory('${root.path}/out'));
    expect(jsonDecode(await f.readAsString())['format'], 'mentos-export');
  });

  testWidgets('explorer tabs, item inspector and tables render at phone width', (tester) async {
    late Engine e;
    await tester.runAsync(() async => e = await seeded());
    await pumpScreen(tester, e, const DataExplorerScreen());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('posts'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Items'));
    await tester.pumpAndSettle();
    expect(find.text('hello there'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '100%');
    await tester.pump();
    expect(find.text('100% real_deal'), findsOneWidget);
    await tester.tap(find.text('100% real_deal'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.textContaining('Signature valid'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tables'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(find.text('kv'), find.byType(ListView).last, const Offset(0, -200));
    await tester.drag(find.byType(ListView).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('kv'));
    await tester.pumpAndSettle();
    expect(find.textContaining('k=settings'), findsOneWidget);
    expect(find.textContaining('abc123'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
