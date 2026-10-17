import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/pay/coin.dart';

import 'support/fake_net.dart';

// Escrow rules are walked from signed payments alone; these build pools by
// hand (the walk does not check signatures) so time can be controlled.
final _a = 'a' * 64, _b = 'b' * 64, _c = 'c' * 64;

CoinTx _mint(String id) => CoinTx(
  kind: 'mint', from: id, to: id, amount: Coin.grant, seq: 0,
  prev: Coin.genesis, memo: '', ts: 0, sig: '00',
);

class _Chain {
  _Chain(this.id) : tip = _mint(id), txs = [_mint(id)];
  final String id;
  CoinTx tip;
  final List<CoinTx> txs;

  CoinTx add(String kind, {String? to, int amount = 0, String memo = '', required int ts, Map<String, Object> x = const {}}) {
    final t = CoinTx(
      kind: kind, from: id, to: to ?? id, amount: amount, seq: tip.seq + 1,
      prev: tip.hash, memo: memo, ts: ts, sig: '00', x: x,
    );
    tip = t;
    txs.add(t);
    return t;
  }
}

int _total(CoinView v) =>
    v.balances.values.fold<int>(0, (s, x) => s + x) + v.escrowed;

/// Like `eventually`, with room for a busy machine running the whole suite.
Future<void> soon(bool Function() predicate) async {
  for (var i = 0; i < 1500; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(predicate(), isTrue, reason: 'Condition did not become true');
}

void main() {
  const day = 86400000;
  final t0 = DateTime(2026, 6, 1).millisecondsSinceEpoch;

  test('lock, accept, release pays the payee less the trade fee, and conserves supply', () {
    final a = _Chain(_a), b = _Chain(_b);
    final lock = a.add('lock', to: _b, amount: 400, memo: 'order:1', ts: t0, x: {'until': t0 + 7 * day, 'ack': t0 + day});
    b.add('ack', memo: 'order:1', ts: t0 + 10, x: {'esc': lock.hash});
    a.add('release', to: _b, amount: 400, memo: 'order:1', ts: t0 + 20, x: {'esc': lock.hash});
    final v = compileCoin([...a.txs, ...b.txs]);
    final fee = Coin.tradeFee(400, 'order:1');
    expect(fee, 8);
    expect(v.balanceOf(_a), Coin.grant - 400);
    expect(v.balanceOf(_b), Coin.grant + 400 - fee);
    expect(v.escrows[lock.hash]!.state, HoldState.settled);
    expect(_total(v), Coin.supply);
  });

  test('the payer can cancel only before the payee accepts', () {
    final a = _Chain(_a), b = _Chain(_b);
    final lock = a.add('lock', to: _b, amount: 300, memo: 'order:2', ts: t0, x: {'until': t0 + 7 * day});
    final cancel = a.add('cancel', memo: 'order:2', ts: t0 + 5, x: {'esc': lock.hash});
    final early = compileCoin([...a.txs]);
    expect(early.balanceOf(_a), Coin.grant);
    expect(early.escrows[lock.hash]!.state, HoldState.cancelled);

    b.add('ack', memo: 'order:2', ts: t0 + 2, x: {'esc': lock.hash});
    final raced = compileCoin([...a.txs, ...b.txs]);
    expect(raced.voided, contains(cancel.hash));
    expect(raced.balanceOf(_a), Coin.grant - 300);
    expect(raced.escrows[lock.hash]!.state, HoldState.accepted);
    expect(_total(raced), Coin.supply);
  });

  test('the payee can claim after the deadline unless the payer disputed in time', () {
    final a = _Chain(_a), b = _Chain(_b);
    final until = t0 + 3 * day;
    final lock = a.add('lock', to: _b, amount: 500, memo: 'task:x', ts: t0, x: {'until': until});
    b.add('ack', memo: 'task:x', ts: t0 + 1, x: {'esc': lock.hash});
    final soon = b.add('claim', memo: 'task:x', ts: until - 1, x: {'esc': lock.hash});
    final tooEarly = compileCoin([...a.txs, ...b.txs]);
    expect(tooEarly.voided, contains(soon.hash));
    expect(tooEarly.escrows[lock.hash]!.remaining, 500);

    b.add('claim', memo: 'task:x', ts: until, x: {'esc': lock.hash});
    final claimed = compileCoin([...a.txs, ...b.txs]);
    expect(claimed.balanceOf(_b), Coin.grant + 500 - Coin.tradeFee(500, 'task:x'));

    a.add('dispute', memo: 'task:x', ts: until - day, x: {'esc': lock.hash});
    final disputed = compileCoin([...a.txs, ...b.txs]);
    expect(disputed.escrows[lock.hash]!.state, HoldState.disputed);
    expect(disputed.balanceOf(_b), Coin.grant);
    expect(_total(disputed), Coin.supply);
  });

  test('an arbiter settles only a disputed hold, and can split it', () {
    final a = _Chain(_a), b = _Chain(_b), c = _Chain(_c);
    final lock = a.add('lock', to: _b, amount: 400, memo: 'order:9', ts: t0, x: {'until': t0 + 9 * day, 'arb': _c});
    b.add('ack', memo: 'order:9', ts: t0 + 1, x: {'esc': lock.hash});
    final meddle = c.add('release', to: _b, amount: 400, memo: 'order:9', ts: t0 + 2, x: {'esc': lock.hash});
    final calm = compileCoin([...a.txs, ...b.txs, ...c.txs]);
    expect(calm.voided, contains(meddle.hash));

    a.add('dispute', memo: 'order:9', ts: t0 + 3, x: {'esc': lock.hash});
    c.add('refund', to: _a, amount: 250, memo: 'order:9', ts: t0 + 4, x: {'esc': lock.hash});
    c.add('release', to: _b, amount: 150, memo: 'order:9', ts: t0 + 5, x: {'esc': lock.hash});
    final v = compileCoin([...a.txs, ...b.txs, ...c.txs]);
    final hold = v.escrows[lock.hash]!;
    expect(hold.state, HoldState.settled);
    expect(v.balanceOf(_a), Coin.grant - 150);
    expect(v.balanceOf(_b), Coin.grant + 150 - Coin.tradeFee(150, 'order:9'));
    expect(v.balanceOf(_c), Coin.grant);
    expect(_total(v), Coin.supply);
  });

  test('a void step does not stop the chain, and the payee can refund', () {
    final a = _Chain(_a), b = _Chain(_b);
    final lock = a.add('lock', to: _b, amount: 200, memo: 'resource:l', ts: t0, x: {'until': t0 + day});
    final bogus = b.add('release', to: _b, amount: 200, memo: 'resource:l', ts: t0 + 1, x: {'esc': lock.hash});
    b.add('refund', to: _a, amount: 50, memo: 'resource:l', ts: t0 + 2, x: {'esc': lock.hash});
    b.add('send', to: _a, amount: 100, memo: 'after', ts: t0 + 3);
    final v = compileCoin([...a.txs, ...b.txs]);
    expect(v.voided, contains(bogus.hash));
    expect(v.escrows[lock.hash]!.remaining, 150);
    expect(v.balanceOf(_a), Coin.grant - 200 + 50 + 100);
    expect(v.balanceOf(_b), Coin.grant - 100);
  });

  test('every ordering of the same pool gives the same ledger', () {
    final a = _Chain(_a), b = _Chain(_b), c = _Chain(_c);
    final lock = a.add('lock', to: _b, amount: 300, memo: 'order:o', ts: t0, x: {'until': t0 + day, 'arb': _c});
    b.add('ack', memo: 'order:o', ts: t0 + 1, x: {'esc': lock.hash});
    b.add('send', to: _c, amount: 250, memo: 'x', ts: t0 + 2);
    c.add('send', to: _a, amount: 700, memo: 'y', ts: t0 + 3);
    a.add('release', to: _b, amount: 100, memo: 'order:o', ts: t0 + 4, x: {'esc': lock.hash});
    final pool = [...a.txs, ...b.txs, ...c.txs];
    final reference = compileCoin(pool);
    final rnd = Random(7);
    for (var i = 0; i < 20; i++) {
      final shuffled = [...pool]..shuffle(rnd);
      final v = compileCoin(shuffled);
      expect(v.balances, reference.balances);
      expect(v.escrows[lock.hash]!.remaining, reference.escrows[lock.hash]!.remaining);
    }
    expect(_total(reference), Coin.supply);
  });

  test('malformed escrow steps are refused by shape', () {
    final lockNoDeadline = CoinTx(kind: 'lock', from: _a, to: _b, amount: 1, seq: 1, prev: _mint(_a).hash,
        memo: '', ts: t0, sig: '00');
    expect(lockNoDeadline.problem(now: t0), isNotNull);
    final selfArb = CoinTx(kind: 'lock', from: _a, to: _b, amount: 1, seq: 1, prev: _mint(_a).hash,
        memo: '', ts: t0, sig: '00', x: {'until': t0 + day, 'arb': _a});
    expect(selfArb.problem(now: t0), 'bad arbiter');
    final paidSignal = CoinTx(kind: 'ack', from: _b, to: _b, amount: 5, seq: 1, prev: _mint(_b).hash,
        memo: '', ts: t0, sig: '00', x: {'esc': _c});
    expect(paidSignal.problem(now: t0), 'signals move nothing');
  });

  group('between phones', () {
    late Directory root;
    late TestNetwork network;
    late List<Engine> engines;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mentos-escrow-');
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

    test('a hold travels with its bundle, is accepted and released, and witnesses confirm it', () async {
      final a = await person();
      final b = await person();
      final c = await person();
      await soon(() => a.coin!.accounts == 3 && b.coin!.accounts == 3 && c.coin!.accounts == 3);
      final lock = await a.coin!.lock(
        b.me.id, 300,
        memo: 'order:t1',
        until: DateTime.now().add(const Duration(days: 7)),
        ackBy: DateTime.now().add(const Duration(days: 1)),
      );
      await soon(() => b.coin!.escrow(lock.hash) != null);
      expect(a.coin!.balance(), Coin.grant - 300);
      expect(b.coin!.escrows().single.actionsFor(b.me.id, nowMs()), containsAll(['ack', 'refund']));

      final again = await a.coin!.lock(b.me.id, 300, memo: 'order:t1', until: DateTime.now().add(const Duration(days: 7)));
      expect(again.hash, lock.hash);

      await b.coin!.step(lock.hash, 'ack');
      await soon(() => a.coin!.escrow(lock.hash)?.acked == true);
      await expectLater(a.coin!.step(lock.hash, 'cancel'), throwsStateError);
      final release = await a.coin!.step(lock.hash, 'release');
      await soon(() => b.coin!.balance() == Coin.grant + 300 - Coin.tradeFee(300, 'order:t1'));
      await soon(() => a.coin!.confirmation(release.hash).state == Settle.final_);
      for (final e in [a, b, c]) {
        await soon(() => _total(e.coin!.view()) == Coin.supply && e.coin!.view().contains(release.hash));
      }
    });
  });
}
