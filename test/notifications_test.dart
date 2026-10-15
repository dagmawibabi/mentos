import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/features/settings/notifications_screen.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/state/notifications.dart';
import 'package:mentos/state/settings.dart';

import 'support/fake_net.dart';

OsNote note(String category, {String id = 'n1', int? at, DateTime? now}) => OsNote(
      id: id,
      category: category,
      title: 'Ada',
      body: 'secret plans',
      at: at ?? (now ?? DateTime(2026, 10, 15, 12)).millisecondsSinceEpoch,
    );

void main() {
  final noon = DateTime(2026, 10, 15, 12);

  group('gate', () {
    test('respects master switch, categories, foreground and mute', () {
      const s = Settings();
      expect(NotifyGate().decide(note('dm'), s, now: noon, foreground: false, muted: false), isNotNull);
      expect(NotifyGate().decide(note('dm'), s, now: noon, foreground: true, muted: false), isNull);
      expect(NotifyGate().decide(note('dm'), s.copyWith(systemNotify: false), now: noon, foreground: false, muted: false), isNull);
      expect(NotifyGate().decide(note('like'), s, now: noon, foreground: false, muted: false), isNull, reason: 'likes default off');
      expect(NotifyGate().decide(note('group'), s, now: noon, foreground: false, muted: true), isNull);
      expect(NotifyGate().decide(note('mention'), s, now: noon, foreground: false, muted: true), isNotNull);
    });

    test('dedupes, ignores stale re-syncs and hides previews', () {
      const s = Settings();
      final g = NotifyGate();
      expect(g.decide(note('dm'), s, now: noon, foreground: false, muted: false), isNotNull);
      expect(g.decide(note('dm'), s, now: noon, foreground: false, muted: false), isNull);
      final old = note('dm', id: 'old', at: noon.subtract(const Duration(hours: 2)).millisecondsSinceEpoch);
      expect(g.decide(old, s, now: noon, foreground: false, muted: false), isNull);
      final hidden = g.decide(note('dm', id: 'n2'), s.copyWith(notify: const NotifyPrefs(preview: false)),
          now: noon, foreground: false, muted: false)!;
      expect(hidden.title, 'Mentos');
      expect(hidden.body, 'New message');
    });

    test('quiet hours, including across midnight', () {
      const night = NotifyPrefs(quietFrom: 22 * 60, quietTo: 7 * 60);
      expect(night.quietAt(DateTime(2026, 1, 1, 23, 30)), isTrue);
      expect(night.quietAt(DateTime(2026, 1, 1, 6, 59)), isTrue);
      expect(night.quietAt(DateTime(2026, 1, 1, 7)), isFalse);
      expect(night.quietAt(noon), isFalse);
      const lunch = NotifyPrefs(quietFrom: 12 * 60, quietTo: 13 * 60);
      expect(lunch.quietAt(noon), isTrue);
      final s = const Settings().copyWith(notify: lunch);
      expect(NotifyGate().decide(note('dm'), s, now: noon, foreground: false, muted: false), isNull);
    });

    test('preferences survive encode/decode', () {
      final s = const Settings().copyWith(
        notify: const NotifyPrefs(likes: true, dms: false, preview: false, quietFrom: 60, quietTo: 120),
        xferAutoAccept: true,
        xferAutoMaxMb: 200,
      );
      final back = Settings.decode(s.encode());
      expect(back.notify.likes, isTrue);
      expect(back.notify.dms, isFalse);
      expect(back.notify.preview, isFalse);
      expect(back.notify.quietTo, 120);
      expect(back.xferAutoMaxMb, 200);
      expect(Settings.decode('{"notify": {"qf": 99999}}').notify.quietFrom, -1);
    });
  });

  group('engine', () {
    late Directory root;
    late TestNetwork network;
    late List<Engine> engines;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('mentos-notify-');
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

    test('an incoming DM produces a dm note routed to the chat', () async {
      final a = await openEngine(root, network);
      final b = await openEngine(root, network);
      engines.addAll([a, b]);
      final notes = <OsNote>[];
      b.notes.listen(notes.add);
      await a.sendMessage(Scope.dm(a.me.id, b.me.id), text: 'hi @${alias(b.me.id)}');
      await a.flushDeliveries();
      await eventually(() => notes.any((n) => n.id.startsWith('msg:')));
      final n = notes.firstWhere((n) => n.id.startsWith('msg:'));
      expect(n.category, 'dm');
      expect(n.route, '/chat/${a.me.id}');
      expect(n.body, contains('hi'));
      expect(b.mentionsMe('hey @${alias(b.me.id).toUpperCase()}'), isTrue);
      expect(b.mentionsMe('no mention here'), isFalse);
    });
  });

  testWidgets('settings screen toggles categories at phone width', (tester) async {
    late Engine e;
    final root = await tester.runAsync(() => Directory.systemTemp.createTemp('mentos-notify-ui-'));
    await tester.runAsync(() async => e = await openEngine(root!, TestNetwork()));
    await pumpScreen(tester, e, const NotificationsScreen());
    await tester.pump();
    expect(find.text('Direct messages'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Likes'), 150, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Likes'));
    await tester.pump();
    expect(e.settings.notify.likes, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await e.stop();
      e.db.close();
      await root!.delete(recursive: true);
    });
  });
}
