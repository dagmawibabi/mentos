import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/features/network/diagnostics_screen.dart';
import 'package:mentos/features/network/node_screen.dart';
import 'package:mentos/features/network/privacy_screen.dart';
import 'package:mentos/net/diagnostics.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/engine_net.dart';
import 'package:mentos/state/settings.dart';

import 'support/fake_net.dart';

// Captured from a real node in tor mode, pinging a second node over a relay.
Map<String, dynamic> realReport(String me, String peer) => {
      'bound': <String>[],
      'connections': [
        {
          'alpn': 'mentos/0',
          'knownAddrs': [
            {'active': true, 'address': 'https://use1-1.relay.n0.iroh.link./', 'kind': 'relay'},
          ],
          'lostBytes': 0,
          'lostPackets': 0,
          'paths': [
            {
              'address': 'https://use1-1.relay.n0.iroh.link./',
              'congestionEvents': 0,
              'cwnd': 12000,
              'kind': 'relay',
              'lostPackets': 0,
              'rttMs': 78.7,
              'rxBytes': 6903,
              'selected': true,
              'txBytes': 9432,
            },
          ],
          'peer': peer,
          'rxBytes': 6903,
          'rxDatagrams': 11,
          'side': 'client',
          'txBytes': 9432,
          'txDatagrams': 14,
        },
      ],
      'net': {
        'captivePortal': true,
        'globalV4': null,
        'globalV6': null,
        'latencies': [
          {'ms': 1033.1, 'probe': 'https', 'relay': 'https://aps1-1.relay.n0.iroh.link./'},
          {'ms': 629.3, 'probe': 'https', 'relay': 'https://euc1-1.relay.n0.iroh.link./'},
          {'ms': 329.3, 'probe': 'https', 'relay': 'https://use1-1.relay.n0.iroh.link./'},
          {'ms': 589.6, 'probe': 'https', 'relay': 'https://usw1-1.relay.n0.iroh.link./'},
        ],
        'mappingVariesV4': null,
        'mappingVariesV6': null,
        'preferredRelay': 'https://use1-1.relay.n0.iroh.link./',
        'udpV4': false,
        'udpV6': false,
      },
      'nodeId': me,
      'privacy': 'tor',
      'proxy': 'http://127.0.0.1:8118',
      'relays': [
        {'connected': true, 'error': null, 'url': 'https://use1-1.relay.n0.iroh.link./'},
      ],
      'topics': 0,
    };

final peerId = 'b' * 64;

void main() {
  late Directory root;
  late TestNetwork network;
  late List<Engine> engines;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-net-tools-');
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

  Future<(Engine, DiagTransport)> diagNode({Settings settings = const Settings()}) async {
    late DiagTransport t;
    final e = await openEngine(root, network, settings: settings, transport: (id) => t = DiagTransport(network, id));
    engines.add(e);
    t.report = realReport(e.me.id, peerId);
    return (e, t);
  }

  test('parses a real native report and explains it', () {
    final d = NetDiagnostics.fromJson(realReport('a' * 64, peerId))!;
    expect(d.privacy, 'tor');
    expect(d.report!.nat, NatKind.blocked);
    expect(d.report!.bestLatency.length, 4);
    expect(relayName(d.report!.preferredRelay!), 'use1-1');
    final c = d.connection(peerId)!;
    expect(c.selected!.rttMs, 78.7);
    expect(c.knownAddrs.single.active, isTrue);
    final lines = explain(d);
    expect(lines.first, contains('Tor mode'));
    expect(lines.last, contains('use1-1'));
  });

  test('malformed reports never throw', () {
    expect(NetDiagnostics.fromJson(null), isNull);
    expect(NetDiagnostics.fromJson({'nodeId': 3}), isNull);
    final d = NetDiagnostics.fromJson({
      'nodeId': 'x',
      'connections': [1, 'a', {'peer': 'p', 'paths': [null, {'address': 4}]}],
      'net': {'latencies': 'nope'},
      'relays': {'a': 1},
    })!;
    expect(d.connections.single.paths, isEmpty);
    expect(d.report!.latencies, isEmpty);
    expect(explain(d), isNotEmpty);
  });

  test('privacy options reach the transport before bind and on change', () async {
    final (e, t) = await diagNode(settings: const Settings(privacy: 'relay'));
    expect(t.options, {'privacy': 'relay'});
    e.updateSettings(e.settings.copyWith(privacy: 'tor', proxyUrl: 'http://127.0.0.1:9999'));
    await eventually(() => t.options?['privacy'] == 'tor');
    expect(t.options!['proxy'], 'http://127.0.0.1:9999');
    expect(Settings.decode(e.settings.encode()).privacy, 'tor');
  });

  test('ping history and shareable report', () async {
    final (e, t) = await diagNode();
    expect(await e.ping(peerId), 12.5);
    t.pingMs = null;
    expect(await e.ping(peerId), isNull);
    expect(e.pingHistory(peerId).length, 2);
    final report = await e.diagnosticsReport();
    expect(report, isNot(contains(peerId)), reason: 'peer ids are shortened in shared reports');
    expect(report, contains('use1-1'));
  });

  testWidgets('diagnostics, privacy and node screens render at phone width', (tester) async {
    late Engine e;
    await tester.runAsync(() async => e = (await diagNode()).$1);

    await pumpScreen(tester, e, const DiagnosticsScreen());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('Reachable through iroh'), findsOneWidget);
    expect(find.text('use1-1'), findsWidgets);
    expect(find.text('329 ms'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Connections'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsWidgets);
    expect(tester.takeException(), isNull);

    await pumpScreen(tester, e, const PrivacyScreen());
    await tester.pump();
    expect(find.text('Hide my IP'), findsOneWidget);
    await tester.tap(find.text('Tor'));
    await tester.pump();
    expect(e.settings.privacy, 'tor');
    expect(tester.takeException(), isNull);

    await pumpScreen(tester, e, NodeScreen(id: peerId));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('via relay'), findsOneWidget);
    expect(find.textContaining('78.7 ms'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    // Let the restart triggered by the privacy change finish in fake time.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
