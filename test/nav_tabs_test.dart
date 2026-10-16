import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mentos/core/theme/app_theme.dart';
import 'package:mentos/core/theme/tokens.dart';
import 'package:mentos/features/settings/settings_screen.dart';
import 'package:mentos/features/shell/home_shell.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/transport.dart';
import 'package:mentos/state/providers.dart';
import 'package:mentos/state/session.dart';
import 'package:mentos/state/settings.dart';

import 'support/fake_net.dart';

class _Ready extends SessionNotifier {
  _Ready(this.engine);
  final Engine engine;
  @override
  Session build() => SessionReady(engine);
}

class _SignedOut extends SessionNotifier {
  @override
  Session build() => const SessionSignedOut();
}

void main() {
  test('hidden tabs drop out of the bar and the landing tab moves', () {
    const both = Settings();
    expect(shellTabs(both, unread: 0, peers: 0).map((t) => t.label), ['Feed', 'Wallet', 'Spaces', 'Network', 'You']);
    expect(landingPath(both), '/feed');

    final feedOff = shellTabs(const Settings(showFeedTab: false), unread: 4, peers: 2);
    expect(feedOff.map((t) => t.label), ['Wallet', 'Spaces', 'Network', 'You']);
    expect(feedOff.first.branch, 1);
    expect(feedOff[1].badge, 4);
    expect(feedOff[2].live, isTrue);
    expect(landingPath(const Settings(showFeedTab: false)), '/wallet');
    expect(landingBranch(const Settings(showFeedTab: false, showWalletTab: false)), 2);
    expect(landingPath(const Settings(showFeedTab: false, showWalletTab: false)), '/chats');

    final saved = Settings.decode(const Settings(showFeedTab: false, showWalletTab: false).encode());
    expect(saved.showFeedTab, isFalse);
    expect(saved.showWalletTab, isFalse);
    expect(Settings.decode('{"theme":"system"}').showFeedTab, isTrue);
    expect(Settings.decode('{"theme":"system"}').showWalletTab, isTrue);
  });

  testWidgets('settings switches hide the feed and wallet tabs', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: '/settings',
      routes: [GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen())],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWith(_SignedOut.new)],
        child: MaterialApp.router(theme: buildTheme(Palette.light), routerConfig: router),
      ),
    );
    await tester.pump();

    expect(find.text('Feed tab'), findsOneWidget);
    expect(find.text('Wallet tab'), findsOneWidget);
    await tester.tap(find.text('Feed tab'));
    await tester.pump();
    await tester.tap(find.text('Wallet tab'));
    await tester.pump();

    final settings = ProviderScope.containerOf(tester.element(find.byType(SettingsScreen))).read(settingsProvider);
    expect(settings.showFeedTab, isFalse);
    expect(settings.showWalletTab, isFalse);
  });

  testWidgets('bottom bar drops a tab that was turned off and leaves that screen', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late Directory root;
    late Engine engine;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('mentos-nav-');
      engine = await openEngine(root, TestNetwork());
    });
    addTearDown(() async {
      await engine.stop();
      engine.db.close();
      await root.delete(recursive: true);
    });

    final router = GoRouter(
      initialLocation: '/feed',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, _, shell) => HomeShell(shell: shell),
          branches: [
            for (final (path, label) in [
              ('/feed', 'feed-page'),
              ('/wallet', 'wallet-page'),
              ('/chats', 'chats-page'),
              ('/network', 'network-page'),
              ('/me', 'me-page'),
            ])
              StatefulShellBranch(routes: [GoRoute(path: path, builder: (_, _) => Text(label))]),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(() => _Ready(engine)),
          netStatusProvider.overrideWith((ref) => Stream.value(const NetStatus(nodeId: 'me', running: false))),
          unreadChatsProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp.router(theme: buildTheme(Palette.light), routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Feed'), findsOneWidget);
    expect(find.text('Wallet'), findsOneWidget);
    expect(find.text('feed-page').hitTestable(), findsOneWidget);

    void update(Settings Function(Settings) change) {
      ProviderScope.containerOf(tester.element(find.byType(HomeShell))).read(settingsProvider.notifier).update(change);
    }

    update((s) => s.copyWith(showFeedTab: false));
    await tester.pump();
    await tester.pump();

    expect(find.text('Feed'), findsNothing);
    expect(find.text('Wallet'), findsOneWidget);
    expect(find.text('wallet-page').hitTestable(), findsOneWidget);
    expect(engine.settings.showFeedTab, isFalse);

    update((s) => s.copyWith(showWalletTab: false));
    await tester.pump();
    await tester.pump();

    expect(find.text('Wallet'), findsNothing);
    expect(find.text('Spaces'), findsOneWidget);
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('chats-page').hitTestable(), findsOneWidget);
    expect(engine.settings.showWalletTab, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
