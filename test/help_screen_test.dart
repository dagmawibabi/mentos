import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mentos/core/theme/app_theme.dart';
import 'package:mentos/core/theme/tokens.dart';
import 'package:mentos/features/settings/help_screen.dart';
import 'package:mentos/features/settings/settings_screen.dart';
import 'package:mentos/state/session.dart';

class _SignedOut extends SessionNotifier {
  @override
  Session build() => const SessionSignedOut();
}

void main() {
  Future<void> settle(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('settings app bar opens help', (tester) async {
    await settle(tester, const Size(390, 844));
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
        GoRoute(path: '/help', builder: (_, _) => const HelpScreen()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWith(_SignedOut.new)],
        child: MaterialApp.router(theme: buildTheme(Palette.light), routerConfig: router),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Help'), findsOneWidget);
    await tester.tap(find.byTooltip('Help'));
    await tester.pumpAndSettle();
    expect(find.text('Your phone is the account.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final palette in [Palette.light, Palette.dark]) {
    testWidgets('help explains the platform, ${palette.isDark ? 'dark' : 'light'}', (tester) async {
      await settle(tester, const Size(390, 844));
      final router = GoRouter(
        initialLocation: '/help',
        routes: [
          GoRoute(path: '/help', builder: (_, _) => const HelpScreen()),
          GoRoute(path: '/privacy', builder: (_, _) => const Scaffold(body: Text('privacy-page'))),
          GoRoute(path: '/wallet', builder: (_, _) => const Scaffold(body: Text('wallet-page'))),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MaterialApp.router(theme: buildTheme(palette), routerConfig: router),
      );
      await tester.pumpAndSettle();

      expect(find.text('Your phone is the account.'), findsOneWidget);
      expect(find.text('yours'), findsOneWidget);
      expect(find.text('kept'), findsOneWidget);
      expect(find.text('live'), findsOneWidget);

      await tester.tap(find.text('Coins').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('The Mentos ledger'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('What is signed, sealed, and encrypted'), -400);
      expect(find.text('Ed25519. The public key is the id and the network address.'), findsOneWidget);
      expect(find.text('XChaCha20-Poly1305. A shared key on top of the link.'), findsOneWidget);
      expect(find.text('AES-256-GCM per file. SHA-256 checked on download.'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('github.com/dagmawibabi/mentos'), 400);
      expect(find.text('github.com/dagmawibabi/mentos'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Privacy and transports'), -400);
      await tester.tap(find.text('Privacy and transports').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('privacy-page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
