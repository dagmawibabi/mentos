import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/features/wallet/wallet_screen.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/pay/ledger.dart';
import 'package:mentos/net/pay/payments.dart';

import 'support/fake_net.dart';

void main() {
  group('amounts', () {
    test('parse and format', () {
      expect(Credits.parse('12'), 1200);
      expect(Credits.parse('12.5'), 1250);
      expect(Credits.parse('0,07'), 7);
      expect(Credits.parse('0'), isNull);
      expect(Credits.parse('-3'), isNull);
      expect(Credits.parse('1.234'), isNull);
      expect(Credits.parse('abc'), isNull);
      expect(Credits.parse('99999999'), isNull);
      expect(Credits.format(1250), '12.50');
      expect(Credits.format(-7), '−0.07');
      expect(Credits.format(300, sign: true), '+3.00');
    });
  });

  group('ledger', () {
    late Directory root;
    late TestNetwork network;
    late List<Engine> engines;
    late List<Payments> wallets;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mentos-pay-');
      network = TestNetwork();
      engines = [];
      wallets = [];
    });
    tearDown(() async {
      for (final w in wallets) {
        await w.dispose();
      }
      for (final e in engines) {
        await e.stop();
        e.db.close();
      }
      await root.delete(recursive: true);
    });

    Future<(Engine, Payments)> person() async {
      final e = await openEngine(root, network);
      final w = Payments(e, resendEvery: const Duration(milliseconds: 200));
      engines.add(e);
      wallets.add(w);
      return (e, w);
    }

    test('within the limit a payment is countersigned at once; balances mirror', () async {
      final (a, wa) = await person();
      final (b, wb) = await person();
      wb.setLimit(a.me.id, Credits.parse('50')!);
      await wa.pay(b.me.id, Credits.parse('12.50')!, memo: 'lunch');
      await eventually(() => wa.outgoing(b.me.id) == null && wa.ledger(b.me.id).length == 1);
      expect(wa.balance(b.me.id), -1250);
      expect(wb.balance(a.me.id), 1250);
      expect(await wa.audit(b.me.id), isTrue);
      expect(await wb.audit(a.me.id), isTrue);
      expect(b.db.activity().any((x) => x.kind == 'pay'), isTrue);

      // Paying back reduces what is owed, whatever the limit.
      await wb.pay(a.me.id, 500);
      await eventually(() => wb.outgoing(a.me.id) == null && wb.ledger(a.me.id).length == 2);
      expect(wa.balance(b.me.id), -750);
      expect(wb.ledger(a.me.id).last.prev, wb.ledger(a.me.id).first.hash);
    });

    test('over the limit it waits for approval, and can be declined', () async {
      final (a, wa) = await person();
      final (b, wb) = await person();
      await wa.pay(b.me.id, 2000);
      await eventually(() => wb.approvals().length == 1);
      expect(wa.outgoing(b.me.id), isNotNull);
      expect(wb.balance(a.me.id), 0);
      await wb.approve(wb.approvals().single);
      await eventually(() => wa.outgoing(b.me.id) == null);
      expect(wb.balance(a.me.id), 2000);

      await wa.pay(b.me.id, 100);
      await eventually(() => wb.approvals().length == 1);
      await wb.decline(wb.approvals().single);
      await eventually(() => wa.outgoing(b.me.id) == null);
      expect(wa.balance(b.me.id), -2000, reason: 'declined payment never counted');
      expect(() async => wa.pay(a.me.id, 1), throwsArgumentError);
    });

    test('paying each other at the same moment settles in a fixed order', () async {
      final (a, wa) = await person();
      final (b, wb) = await person();
      wa.setLimit(b.me.id, 100000);
      wb.setLimit(a.me.id, 100000);
      await Future.wait([wa.pay(b.me.id, 300), wb.pay(a.me.id, 700)]);
      await eventually(() =>
          wa.outgoing(b.me.id) == null && wb.outgoing(a.me.id) == null && wa.ledger(b.me.id).length == 2 && wb.ledger(a.me.id).length == 2);
      expect(wa.balance(b.me.id), 400);
      expect(wb.balance(a.me.id), -400);
      expect(wa.ledger(b.me.id).map((e) => e.hash), wb.ledger(a.me.id).map((e) => e.hash), reason: 'identical chains');
      expect(await wa.audit(b.me.id), isTrue);
    });

    test('forged, replayed and tampered entries are refused', () async {
      final (a, wa) = await person();
      final (b, wb) = await person();
      wb.setLimit(a.me.id, 100000);
      await wa.pay(b.me.id, 100);
      await eventually(() => wb.ledger(a.me.id).length == 1);
      final first = wb.ledger(a.me.id).single;

      // Replay of an already settled entry changes nothing.
      await a.sendApp(b.me.id, Payments.app, {'op': 'propose', 'e': first.toJson()});
      // Someone else claims to be paying as `a`.
      final mallory = await Identity.generate();
      final forged = LedgerEntry(
        pair: Credits.pairId(a.me.id, b.me.id),
        seq: 2,
        prev: first.hash,
        from: a.me.id,
        to: b.me.id,
        amount: 99,
        memo: '',
        ts: DateTime.now().millisecondsSinceEpoch,
      );
      final signed = forged.copyWith(sigFrom: await mallory.sign(utf8.encode(forged.body)));
      await a.sendApp(b.me.id, Payments.app, {'op': 'propose', 'e': signed.toJson()});
      // A real signature but on a different amount than the body says.
      final real = forged.copyWith(sigFrom: await a.me.sign(utf8.encode(forged.body)));
      final tampered = LedgerEntry.fromJson({...real.toJson(), 'amt': 99999})!;
      await a.sendApp(b.me.id, Payments.app, {'op': 'propose', 'e': tampered.toJson()});
      // An entry that skips ahead in the chain.
      final skip = LedgerEntry.fromJson({...real.toJson(), 'seq': 5})!;
      await a.sendApp(b.me.id, Payments.app, {'op': 'propose', 'e': skip.toJson()});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await wb.idle();
      expect(wb.ledger(a.me.id).length, 1);
      expect(wb.balance(a.me.id), 100);
      expect(wb.approvals(), isEmpty);
    });

    test('a lost acceptance is recovered by re-sending', () async {
      final (a, wa) = await person();
      final (b, wb) = await person();
      wb.setLimit(a.me.id, 100000);
      network.dropApp = true;
      await wa.pay(b.me.id, 100);
      await eventually(() => wb.ledger(a.me.id).length == 1);
      expect(wa.outgoing(b.me.id), isNotNull, reason: 'the acceptance was lost');
      network.dropApp = false;
      await eventually(() => wa.outgoing(b.me.id) == null && wa.ledger(b.me.id).length == 1);
      expect(wa.ledger(b.me.id).single.hash, wb.ledger(a.me.id).single.hash);
    });

    test('requests show up and can be dismissed', () async {
      final (a, wa) = await person();
      final (b, wb) = await person();
      await wb.request(a.me.id, 450, memo: 'tickets');
      await eventually(() => wa.requests().isNotEmpty);
      expect(wa.requests().single.amount, 450);
      expect(wa.requests().single.peer, b.me.id);
      wa.dismissRequest(wa.requests().single.id);
      expect(wa.requests(), isEmpty);
    });
  });

  testWidgets('wallet and credit line screens render at phone width', (tester) async {
    late Engine b;
    late String aId;
    final root = await tester.runAsync(() => Directory.systemTemp.createTemp('mentos-pay-ui-'));
    await tester.runAsync(() async {
      final network = TestNetwork();
      final a = await openEngine(root!, network);
      b = await openEngine(root, network);
      aId = a.me.id;
      final wa = Payments(a);
      final wb = Payments(b);
      wb.setLimit(a.me.id, 100000);
      await wa.pay(b.me.id, 4250, memo: 'concert tickets');
      await eventually(() => wa.outgoing(b.me.id) == null);
      await wa.pay(b.me.id, 99999999 ~/ 100);
      await wa.dispose();
      await wb.dispose();
      await a.stop();
      a.db.close();
    });
    await pumpScreen(tester, b, const WalletScreen());
    await tester.pump();
    expect(find.text('owes you'), findsOneWidget);
    expect(find.text('42.50'), findsWidgets);
    expect(tester.takeException(), isNull);

    await pumpScreen(tester, b, PeerWalletScreen(peer: aId));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.textContaining('concert tickets'), findsOneWidget);
    expect(find.text('every entry signed by both'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() async {
      await b.stop();
      b.db.close();
      await root!.delete(recursive: true);
    });
  });
}
