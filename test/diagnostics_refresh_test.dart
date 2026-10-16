import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/features/network/diagnostics_screen.dart';
import 'package:mentos/net/engine.dart';

import 'support/fake_net.dart';

void main() {
  testWidgets('refresh recovers from a missing diagnostics measurement', (
    tester,
  ) async {
    late Directory root;
    late Engine engine;
    late DiagTransport transport;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp(
        'mentos-diagnostics-refresh-',
      );
      final network = TestNetwork();
      engine = await openEngine(
        root,
        network,
        transport: (id) => transport = DiagTransport(network, id),
      );
    });
    await pumpScreen(tester, engine, const DiagnosticsScreen());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(
      find.text('The measurement did not finish. Tap refresh to try again.'),
      findsOneWidget,
    );
    transport.report = {
      'nodeId': engine.me.id,
      'privacy': 'standard',
      'relays': [
        {'url': 'https://relay.example/', 'connected': true},
      ],
      'connections': <Object>[],
    };
    await tester.tap(find.byTooltip('Re-check network'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(transport.networkChanges, 1);
    expect(find.text('Reachable through iroh'), findsOneWidget);
    expect(
      find.text('The measurement did not finish. Tap refresh to try again.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await engine.stop();
      engine.db.close();
      await transport.controller.close();
      await root.delete(recursive: true);
    });
  });
}
