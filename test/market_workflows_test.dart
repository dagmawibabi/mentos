import 'dart:io';
import 'dart:convert';
import 'package:mentos/data/models.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/pay/coin.dart';

import 'support/fake_net.dart';

void main() {
  late Directory root;
  late TestNetwork network;
  late Engine owner;
  late Engine worker;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-market-');
    network = TestNetwork();
    owner = await openEngine(root, network);
    worker = await openEngine(root, network);
    await eventually(() => owner.coin!.balance(worker.me.id) == Coin.grant);
  });
  tearDown(() async {
    for (final e in [owner, worker]) {
      await e.stop();
      e.db.close();
    }
    await root.delete(recursive: true);
  });

  test(
    'free packs install, provide content and uninstall; executable packs fail',
    () async {
      for (final pack in starterPlugins) {
        await owner.installPlugin(pack);
      }
      expect(owner.installedStickers(), contains('🙌'));
      expect(owner.installedPhrases(), isNotEmpty);
      owner.removePlugin('builtin:celebrate');
      expect(owner.installedStickers(), isEmpty);
      await expectLater(
        owner.installPlugin({
          'id': 'unsafe',
          'plugin': 'script',
          'body': {'code': 'run'},
        }),
        throwsArgumentError,
      );
      await expectLater(
        owner.installPlugin({
          ...starterPlugins.first,
          'id': 'paid',
          'from': worker.me.id,
          'minor': 100,
        }),
        throwsStateError,
      );
    },
  );

  test('task applications, assignment, evidence, revision and acceptance synchronize', () async {
    await owner.postMarket({
      'kind': 'task',
      'title': 'Test work',
      'about': 'Deliver evidence',
      'minor': 100,
      'status': 'open',
    });
    final id = owner.marketBoard().first['id'] as String;
    await eventually(() => worker.task(id) != null);
    await worker.taskAction(id, 'apply', text: 'I can help');
    await eventually(
      () => (owner.task(id)!['applications'] as List? ?? []).contains(
        worker.me.id,
      ),
    );
    await owner.taskAction(id, 'assign', worker: worker.me.id);
    await eventually(() => worker.task(id)!['status'] == 'in progress');
    await worker.taskAction(id, 'submit', text: 'Completed the brief');
    await eventually(() => owner.task(id)!['status'] == 'in review');
    await owner.taskAction(id, 'revise', text: 'Please add a detail');
    await eventually(() => worker.task(id)!['status'] == 'changes requested');
    await worker.taskAction(id, 'submit', text: 'Added the detail');
    await eventually(() => owner.task(id)!['status'] == 'in review');
    await owner.taskAction(id, 'accept');
    await eventually(() => worker.task(id)!['status'] == 'completed');
    expect(owner.coin!.balance(), Coin.grant - 105);
    expect(owner.coin!.balance(Coin.treasury), Coin.supply - Coin.grant * 2 + 5);
    expect(owner.task(id)!['receipt'], isNotEmpty);
    await expectLater(owner.taskAction(id, 'accept'), throwsStateError);
    expect(owner.coin!.balance(), Coin.grant - 105);
  });

  test('network rewards conserve supply and cannot be claimed twice', () async {
    final receipt = await owner.coin!.pay(
      worker.me.id,
      100,
      memo: 'resource:test',
    );
    await eventually(() => worker.coin!.view().contains(receipt.hash));
    expect(worker.coin!.balance(Coin.treasury), Coin.supply - Coin.grant * 2 + 5);
    final reward = await worker.coin!.claimReward(receipt.hash);
    expect(reward.kind, 'reward');
    expect(worker.coin!.balance(Coin.treasury), Coin.supply - Coin.grant * 2);
    expect(worker.coin!.balance(), Coin.grant + 105);
    await expectLater(worker.coin!.claimReward(receipt.hash), throwsStateError);
    await eventually(() => owner.coin!.view().contains(reward.hash));
    expect(
      owner.coin!.view().balances.values.fold<int>(0, (a, b) => a + b),
      Coin.supply,
    );
    final reversed = compileCoin(owner.coin!.pool().reversed.toList());
    expect(reversed.balances, owner.coin!.view().balances);
  });

  test('concurrent payment retries produce one receipt', () async {
    final receipts = await Future.wait([
      owner.coin!.payOnce(worker.me.id, 100, memo: 'task:retry'),
      owner.coin!.payOnce(worker.me.id, 100, memo: 'task:retry'),
    ]);
    expect(receipts.first.hash, receipts.last.hash);
    expect(owner.coin!.balance(), Coin.grant - 105);
  });

  test(
    'unassigned people cannot submit work and nonowners cannot assign',
    () async {
      await owner.postMarket({
        'kind': 'task',
        'title': 'Protected',
        'minor': 100,
      });
      final id = owner.marketBoard().first['id'] as String;
      await eventually(() => worker.task(id) != null);
      await expectLater(
        worker.taskAction(id, 'submit', text: 'Fake'),
        throwsStateError,
      );
      await expectLater(
        worker.taskAction(id, 'assign', worker: worker.me.id),
        throwsStateError,
      );
      expect(owner.task(id)!['status'], isNull);
    },
  );
  test('invalid reward amounts stay excluded and service fees cannot overdraft', () async {
    await expectLater(owner.coin!.pay(worker.me.id, Coin.grant, memo: 'task:too-much'), throwsStateError);
    final paid = await owner.coin!.pay(worker.me.id, 100, memo: 'task:proof');
    await eventually(() => worker.coin!.view().contains(paid.hash));
    final tip = worker.coin!.view().chains[worker.me.id]!.last;
    final invalid = CoinTx(kind: 'reward', from: worker.me.id, to: worker.me.id, amount: 6,
      seq: tip.seq + 1, prev: tip.hash, memo: 'reward:${paid.hash}', ts: nowMs(), sig: '');
    final signed = invalid.withSig(await worker.me.sign(utf8.encode(invalid.body)));
    await owner.coin!.onMessage(worker.me.id, {'op': 'tx', 'tx': signed.toJson()});
    expect(owner.coin!.view().contains(signed.hash), isFalse);
    expect(owner.coin!.balance(Coin.treasury), Coin.supply - Coin.grant * 2 + 5);
  });

  test('channel invitation reaches Activity and subscription stays recipient-controlled', () async {
    final channel = await owner.createBroadcast('Workshop');
    await owner.inviteToChannel(channel, worker.me.id);
    await eventually(() => worker.db.activity().any((a) => a.id == 'channel-invite:${channel.id}'));
    expect(worker.isSubscribed(owner.me.id, channel.id), isFalse);
    await worker.subscribe(channel, true);
    await eventually(() => owner.subscribers(channel).contains(worker.me.id));
  });

}
