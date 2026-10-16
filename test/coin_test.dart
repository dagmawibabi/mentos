import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/features/chats/chats_screen.dart';
import 'package:mentos/features/wallet/coin_wallet_screen.dart';
import 'package:mentos/features/wallet/send_screen.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/pay/coin.dart';

import 'support/fake_net.dart';

void main() {
  group('mentos ledger', () {
    late Directory root;
    late TestNetwork network;
    late List<Engine> engines;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mentos-coin-');
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

    Future<CoinTx> spend(Identity who, CoinTx prev, String to, int amount, String memo) async {
      final draft = CoinTx(
        kind: 'send',
        from: who.id,
        to: to,
        amount: amount,
        seq: prev.seq + 1,
        prev: prev.hash,
        memo: memo,
        ts: nowMs(),
        sig: '',
      );
      return draft.withSig(await who.sign(utf8.encode(draft.body)));
    }

    test('a new identity is granted 5.00 once, and the grant is the same bytes every time', () async {
      final a = await person();
      final coin = a.coin!;
      expect(coin.balance(), Coin.grant);
      expect(coin.balance(Coin.treasury), Coin.supply - Coin.grant);
      expect(Coin.format(coin.balance()), '5.00');
      expect(coin.pool().single.isMint, isTrue);
      final first = coin.pool().single.hash;
      await coin.ensureGrant();
      expect(coin.pool(), hasLength(1));
      final again = CoinTx(
        kind: 'mint',
        from: a.me.id,
        to: a.me.id,
        amount: Coin.grant,
        seq: 0,
        prev: Coin.genesis,
        memo: '',
        ts: 0,
        sig: '',
      ).withSig(await a.me.sign(utf8.encode(CoinTx(
        kind: 'mint',
        from: a.me.id,
        to: a.me.id,
        amount: Coin.grant,
        seq: 0,
        prev: Coin.genesis,
        memo: '',
        ts: 0,
        sig: '',
      ).body)));
      expect(again.hash, first);
    });

    test('a payment moves coins on every phone that syncs', () async {
      final a = await person();
      final b = await person();
      await eventually(() => a.coin!.balance(b.me.id) == Coin.grant && b.coin!.balance(a.me.id) == Coin.grant);

      await a.coin!.pay(b.me.id, Coin.parse('1.50')!, memo: 'lunch');
      await eventually(() => b.coin!.balance() == Coin.grant + 150 && a.coin!.balance() == Coin.grant - 150);
      expect(b.coin!.balance(a.me.id), Coin.grant - 150);
      expect(b.db.activity().any((x) => x.kind == 'coin'), isTrue);

      final c = await person();
      await eventually(
        () => c.coin!.balance(a.me.id) == Coin.grant - 150 && c.coin!.balance(b.me.id) == Coin.grant + 150,
      );
      expect(c.coin!.history(a.me.id).first.memo, 'lunch');
    });

    test('two spends of the same coins keep the lower hash on every phone', () async {
      final a = await person();
      final b = await person();
      await eventually(() => b.coin!.balance(a.me.id) == Coin.grant);
      final mint = a.coin!.pool().firstWhere((t) => t.isMint && t.from == a.me.id);
      final first = await a.coin!.pay(b.me.id, 100, memo: 'one');
      final second = await spend(a.me, mint, b.me.id, 200, 'two');
      await a.coin!.onMessage(b.me.id, {'op': 'tx', 'tx': second.toJson()});
      await b.coin!.onMessage(a.me.id, {'op': 'tx', 'tx': second.toJson()});
      await eventually(() => a.coin!.pool().length >= 3 && b.coin!.pool().where((t) => t.from == a.me.id).length >= 3);

      final winner = first.hash.compareTo(second.hash) < 0 ? first : second;
      expect(a.coin!.balance(), Coin.grant - winner.amount);
      expect(b.coin!.balance(a.me.id), a.coin!.balance());
      expect(b.coin!.balance(), Coin.grant + winner.amount);
      expect(a.coin!.view().contains(winner.hash), isTrue);
      expect(a.coin!.view().contains(winner == first ? second.hash : first.hash), isFalse);
    });

    test('forged, overspent and second grants are refused', () async {
      final a = await person();
      final b = await person();
      final before = a.coin!.pool().length;
      final mallory = await Identity.generate();
      final mint = a.coin!.pool().firstWhere((t) => t.isMint && t.from == a.me.id);
      final forged = await spend(mallory, mint, b.me.id, 100, 'nope');
      final lied = CoinTx(
        kind: forged.kind,
        from: a.me.id,
        to: forged.to,
        amount: forged.amount,
        seq: forged.seq,
        prev: forged.prev,
        memo: forged.memo,
        ts: forged.ts,
        sig: forged.sig,
      );
      await b.coin!.onMessage(mallory.id, {'op': 'tx', 'tx': lied.toJson()});
      await b.coin!.idle();
      expect(b.coin!.pool().where((t) => t.memo == 'nope'), isEmpty);

      final fatBody = CoinTx(
        kind: 'mint',
        from: a.me.id,
        to: a.me.id,
        amount: Coin.grant * 2,
        seq: 0,
        prev: Coin.genesis,
        memo: '',
        ts: 0,
        sig: '',
      );
      final fat = fatBody.withSig(await a.me.sign(utf8.encode(fatBody.body)));
      await a.coin!.onMessage(b.me.id, {'op': 'tx', 'tx': fat.toJson()});
      await a.coin!.idle();
      expect(a.coin!.pool(), hasLength(before));

      await expectLater(a.coin!.pay(b.me.id, Coin.grant + 1), throwsA(isA<StateError>()));
      await expectLater(a.coin!.pay(a.me.id, 100), throwsA(isA<ArgumentError>()));
      await a.coin!.pay(b.me.id, Coin.grant);
      expect(a.coin!.balance(), 0);
      await expectLater(a.coin!.pay(b.me.id, 100), throwsA(isA<StateError>()));
    });
  });

  testWidgets('wallet shows the grant, and chats switches to channels and spaces', (tester) async {
    late Engine engine;
    final root = await tester.runAsync(() => Directory.systemTemp.createTemp('mentos-coin-ui-'));
    await tester.runAsync(() async {
      engine = await openEngine(root!, TestNetwork());
    });
    await pumpScreen(tester, engine, const CoinWalletScreen());
    await tester.pump();
    expect(find.text('5.00'), findsOneWidget);
    expect(find.text('MENTOS'), findsOneWidget);
    expect(find.text('Welcome grant'), findsOneWidget);
    expect(find.text('Network treasury'), findsNothing);
    expect(find.byTooltip('Explore ledger'), findsNothing);
    await tester.scrollUntilVisible(find.text('Explore the Mentos network'), 400);
    expect(
      tester.getTopLeft(find.text('Marketplace')).dy,
      lessThan(tester.getTopLeft(find.text('Explore the Mentos network')).dy),
    );
    expect(find.text('+5.00'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pumpScreen(tester, engine, const ChatsScreen());
    await tester.pump();
    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('Groups'), findsOneWidget);
    await tester.tap(find.text('Groups'));
    await tester.pump();
    expect(find.text('No groups'), findsOneWidget);
    await tester.tap(find.text('Channels'));
    await tester.pump();
    expect(find.text('No channels yet'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await engine.stop();
      engine.db.close();
      await root!.delete(recursive: true);
    });
  });

  testWidgets('send page checks the amount and address on the page', (tester) async {
    late Engine engine;
    final root = await tester.runAsync(() => Directory.systemTemp.createTemp('mentos-send-ui-'));
    await tester.runAsync(() async {
      engine = await openEngine(root!, TestNetwork());
    });
    await pumpScreen(tester, engine, const SendMentosScreen());
    await tester.pump();
    expect(find.text('PAY TO'), findsOneWidget);
    expect(find.text('NOTE'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send')).onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('send-amount')), '1.50');
    await tester.pump();
    expect(find.text('Send 1.50'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send 1.50')).onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('send-amount')), '9');
    await tester.pump();
    expect(find.text('You have 5.00'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('send-amount')), '1.00');
    await tester.enterText(find.byKey(const ValueKey('send-address')), engine.me.id);
    await tester.pump();
    expect(find.text('That address is this phone'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('send-address')), 'ab' * 32);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send 1.00')).onPressed, isNotNull);
    expect(find.text('How many Mentos?'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await engine.stop();
      engine.db.close();
      await root!.delete(recursive: true);
    });
  });

  test('grants stop when the treasury is empty and resume after a deposit', () {
    final a = 'a' * 64;
    final b = 'b' * 64;
    CoinTx mint(String id) => CoinTx(
      kind: 'mint',
      from: id,
      to: id,
      amount: Coin.grant,
      seq: 0,
      prev: Coin.genesis,
      memo: '',
      ts: 0,
      sig: '00',
    );
    final first = compileCoin([mint(a), mint(b)], supply: Coin.grant);
    expect(first.chains, hasLength(1));
    expect(first.balances.values.fold<int>(0, (s, v) => s + v), Coin.grant);
    final winner = first.chains.keys.single;
    final loser = winner == a ? b : a;
    expect(first.balanceOf(winner), Coin.grant);
    expect(first.balanceOf(loser), 0);
    expect(first.balanceOf(Coin.treasury), 0);

    final refill = CoinTx(
      kind: 'send',
      from: winner,
      to: Coin.treasury,
      amount: Coin.grant,
      seq: 1,
      prev: first.chains[winner]!.single.hash,
      memo: 'refill',
      ts: nowMs(),
      sig: '00',
    );
    final next = compileCoin([mint(a), mint(b), refill], supply: Coin.grant);
    expect(next.balanceOf(loser), Coin.grant);
    expect(next.balanceOf(winner), 0);
    expect(next.balanceOf(Coin.treasury), 0);
    expect(next.balances.values.fold<int>(0, (s, v) => s + v), Coin.grant);
  });

  test('checkmark price follows the treasury and a short payment does not mark', () {
    expect(Coin.badgePrice(Coin.supply), Coin.badgeBase);
    expect(Coin.badgePrice(Coin.supply - Coin.grant), Coin.badgeBase + 1);

    final a = 'a' * 64;
    final b = 'b' * 64;
    final c = 'c' * 64;
    CoinTx mint(String id) => CoinTx(
      kind: 'mint',
      from: id,
      to: id,
      amount: Coin.grant,
      seq: 0,
      prev: Coin.genesis,
      memo: '',
      ts: 0,
      sig: '00',
    );
    final mints = [mint(a), mint(b), mint(c)];
    final opened = compileCoin(mints);
    final price = Coin.badgePrice(opened.balanceOf(Coin.treasury));
    expect(price, Coin.badgeBase + 3);
    expect(opened.balanceOf(c), Coin.grant);

    CoinTx send(String from, String prev, int seq, String to, int amount, String memo) =>
        CoinTx(
          kind: 'send',
          from: from,
          to: to,
          amount: amount,
          seq: seq,
          prev: prev,
          memo: memo,
          ts: nowMs(),
          sig: '00',
        );
    final tipA = opened.chains[a]!.single;
    final tipB = opened.chains[b]!.single;
    final tipC = opened.chains[c]!.single;
    final funding = [
      send(a, tipA.hash, 1, c, Coin.grant, 'to-c'),
      send(b, tipB.hash, 1, c, Coin.grant, 'to-c'),
    ];
    final short = compileCoin([
      ...mints,
      ...funding,
      send(c, tipC.hash, 1, Coin.treasury, price - 1, 'badge'),
    ]);
    expect(short.badges, isEmpty);
    expect(short.balanceOf(c), Coin.grant * 3 - (price - 1));

    final paid = compileCoin([
      ...mints,
      ...funding,
      send(c, tipC.hash, 1, Coin.treasury, price, 'badge:$price'),
    ]);
    expect(paid.badges, contains(c));
    expect(paid.balanceOf(c), Coin.grant * 3 - price);
    expect(paid.balances.values.fold<int>(0, (s, v) => s + v), Coin.supply);
  });
}
