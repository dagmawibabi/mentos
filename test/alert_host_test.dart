import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/state/providers.dart';
import 'package:mentos/widgets/xfer.dart';

void main() {
  testWidgets(
    'banner host survives the router notifying during its own build',
    (tester) async {
      final contentKey = GlobalKey(debugLabel: 'alert content');
      final router = GoRouter(
        initialLocation: '/a',
        routes: [
          GoRoute(path: '/a', builder: (_, _) => const Text('screen-a')),
          GoRoute(path: '/b', builder: (_, _) => const Text('screen-b')),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            alertsProvider.overrideWith((ref) => Stream.value(const <Alert>[])),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            builder: (context, child) => AlertHost(
              router: router,
              child: KeyedSubtree(
                key: contentKey,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('screen-a'), findsOneWidget);

      router.go('/b');
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('screen-b'), findsOneWidget);
    },
  );
}
