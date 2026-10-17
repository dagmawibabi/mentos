import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/market/market.dart';
import 'package:mentos/net/pay/coin.dart';

import 'support/fake_net.dart';

Map<String, dynamic> itemBody({int price = 120, int stock = 3, String title = 'Handmade mug'}) => {
  'title': title,
  'about': 'Glazed stoneware',
  'price': price,
  'stock': stock,
  'category': 'art',
  'condition': 'handmade',
  'holdDays': 7,
  'delivery': [
    {'id': 'pick', 'label': 'Pickup in Bole', 'kind': 'pickup', 'price': 0, 'days': 0},
    {'id': 'ship', 'label': 'Courier', 'kind': 'ship', 'price': 30, 'days': 2},
  ],
  'tags': ['ceramics'],
};

/// Like `eventually`, with room for a busy machine running the whole suite.
Future<void> soon(bool Function() predicate) async {
  for (var i = 0; i < 1500; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(predicate(), isTrue, reason: 'Condition did not become true');
}

void main() {
  late Directory root;
  late TestNetwork network;
  late List<Engine> engines;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-market-');
    network = TestNetwork()..blobs = true;
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

  Future<List<Engine>> people(int n) async {
    final list = [for (var i = 0; i < n; i++) await person()];
    await soon(() => list.every((e) => e.coin!.accounts == n));
    return list;
  }

  test('listings are signed, reach everyone, and only their author can change them', () async {
    final [seller, buyer, stranger] = await people(3);
    final l = await seller.market!.publish(Kinds.item, itemBody());
    await soon(() => buyer.market!.listing(l.id) != null && stranger.market!.listing(l.id) != null);
    expect(stranger.market!.via(l.id), seller.me.id);

    final forged = Listing(
      id: l.id, kind: l.kind, author: l.author, rev: l.rev + 1, ts: nowMs(),
      body: {...l.body, 'price': 1}, sig: l.sig,
    );
    await buyer.market!.onGossip(stranger.me.id, {'op': 'l', 'l': forged.toJson()});
    await buyer.market!.idle();
    expect(buyer.market!.listing(l.id)!.price, 120);

    await expectLater(
      Listing.create(stranger.me, id: l.id, kind: l.kind, rev: l.rev + 5, body: l.body),
      throwsArgumentError,
      reason: 'an id must name its author',
    );

    await seller.market!.revise(l, {'price': 150});
    await soon(() => buyer.market!.listing(l.id)!.price == 150);
    await seller.market!.withdraw(l.id);
    await soon(() => buyer.market!.listings(kind: Kinds.item).isEmpty);

    // A phone that arrives later catches up by syncing with anyone.
    final late = await person();
    await late.market!.onPeer(buyer.me.id);
    await soon(() => late.market!.listing(l.id)?.deleted == true);
  });

  test('checkout pays into escrow; accept, ship and confirm pay the seller less the fee', () async {
    final [seller, buyer, _] = await people(3);
    final l = await seller.market!.publish(Kinds.item, itemBody(price: 100, stock: 2));
    await soon(() => buyer.market!.listing(l.id) != null);
    final listing = buyer.market!.listing(l.id)!;

    final order = await buyer.market!.placeOrder(
      lines: [(listing: listing, qty: 2, options: const <String, String>{})],
      deliveryId: 'ship',
      address: {'name': 'Abebe', 'line': 'Bole road', 'city': 'Addis', 'phone': ''},
    );
    final id = order['id'] as String;
    expect(order['total'], 230);
    expect(buyer.coin!.balance(), Coin.grant - 230);
    await soon(() => seller.market!.order(id) != null);
    final sold = seller.market!.order(id)!;
    expect(sold['address']['city'], 'Addis');
    expect(seller.market!.orderStage(sold), 'placed');

    await seller.market!.acceptOrder(id);
    await soon(() => buyer.market!.orderStage(buyer.market!.order(id)!) == 'accepted');
    await expectLater(buyer.market!.cancelOrder(id), throwsStateError);
    await soon(() => buyer.market!.listing(l.id)!.body['stock'] == 0);

    await seller.market!.shipOrder(id, 'Courier #42');
    await soon(() => buyer.market!.orderStage(buyer.market!.order(id)!) == 'shipped');
    await buyer.market!.confirmOrder(id);
    final fee = Coin.tradeFee(230, 'order:$id');
    await soon(() => seller.coin!.balance() == Coin.grant + 230 - fee);
    expect(seller.market!.orderStage(seller.market!.order(id)!), 'completed');

    final lock = order['lock'] as String;
    await buyer.market!.review(lock: lock, subject: seller.me.id, stars: 5, text: 'Lovely', role: 'buyer', listing: l.id);
    await expectLater(
      buyer.market!.review(lock: lock, subject: seller.me.id, stars: 1, role: 'buyer'),
      throwsStateError,
    );
    await soon(() => seller.market!.reviewsOf(seller.me.id).length == 1);
    final rep = buyer.market!.reputation(seller.me.id);
    expect(rep.sales, 1);
    expect(rep.stars, 5);
  });

  test('a buyer cancels before acceptance; a seller can decline', () async {
    final [seller, buyer] = await people(2);
    final l = await seller.market!.publish(Kinds.item, itemBody(price: 50));
    await soon(() => buyer.market!.listing(l.id) != null);
    final listing = buyer.market!.listing(l.id)!;
    final a = await buyer.market!.placeOrder(lines: [(listing: listing, qty: 1, options: const {})]);
    await soon(() => seller.market!.order(a['id'] as String) != null);
    await buyer.market!.cancelOrder(a['id'] as String);
    expect(buyer.coin!.balance(), Coin.grant);
    await soon(() => seller.market!.orderStage(seller.market!.order(a['id'] as String)!) == 'cancelled');

    final b = await buyer.market!.placeOrder(lines: [(listing: listing, qty: 1, options: const {})]);
    await soon(() => seller.market!.order(b['id'] as String) != null);
    await seller.market!.declineOrder(b['id'] as String, 'Out of stock');
    await soon(() => buyer.coin!.balance() == Coin.grant);
    expect(buyer.market!.orderStage(buyer.market!.order(b['id'] as String)!), 'declined');
  });

  test('task: apply, assign into escrow, submit evidence, ask for changes, approve', () async {
    final [owner, worker, other] = await people(3);
    final task = await owner.market!.publish(Kinds.task, {
      'title': 'Photograph the old post office',
      'about': 'Three angles in daylight',
      'reward': 200,
      'deadline': nowMs() + 86400000,
      'category': 'photo',
      'criteria': ['Three photos', 'Daylight'],
      'evidence': ['photo', 'text'],
      'reviewDays': 2,
    });
    await soon(() => worker.market!.listing(task.id) != null && other.market!.listing(task.id) != null);
    await worker.market!.apply(worker.market!.listing(task.id)!, 'I live next door');
    await other.market!.apply(other.market!.listing(task.id)!, 'I have a good camera');
    await soon(() => (owner.market!.taskRecord(task.id)?['applications'] as List?)?.length == 2);
    await expectLater(other.market!.submitWork(task.id, 'fake'), throwsStateError);

    await owner.market!.assign(task.id, worker.me.id);
    expect(owner.coin!.balance(), Coin.grant - 200);
    await soon(() => worker.market!.taskStage(worker.market!.taskRecord(task.id)!) == 'offered');
    await soon(() => other.market!.taskStage(other.market!.taskRecord(task.id)!) == 'not chosen');
    await worker.market!.acceptOffer(task.id);
    await worker.market!.submitWork(task.id, 'Two photos attached');
    await soon(() => owner.market!.taskStage(owner.market!.taskRecord(task.id)!) == 'in review');
    await owner.market!.requestChanges(task.id, 'Need a third angle');
    await soon(() => worker.market!.taskStage(worker.market!.taskRecord(task.id)!) == 'changes requested');
    await worker.market!.submitWork(task.id, 'Third photo added');
    await soon(() => owner.market!.taskStage(owner.market!.taskRecord(task.id)!) == 'in review');
    await owner.market!.approveWork(task.id);
    await soon(() => worker.coin!.balance() == Coin.grant + 200 - Coin.tradeFee(200, 'task:'));
    await soon(() => worker.market!.listing(task.id)!.status == 'completed');
    expect(owner.market!.reputation(worker.me.id).tasksDone, 1);
  });

  test('ads: an opted-in viewer earns per view, split with the carrier', () async {
    final [advertiser, viewer] = await people(2);
    final ad = await advertiser.market!.launchAd({
      'title': 'Fresh injera daily',
      'text': 'Delivered across Addis',
      'budget': 100,
      'perView': 4,
      'perClick': 6,
      'viewerShare': 50,
      'dailyCap': 100,
      'until': nowMs() + 86400000,
      'target': {'type': 'none'},
      'tags': ['food'],
    });
    await soon(() => viewer.market!.listing(ad.id) != null);
    expect(viewer.market!.nextAd(), isNull, reason: 'ads are off until the viewer opts in');
    viewer.market!.setAds(on: true, interests: ['food']);
    final shown = viewer.market!.nextAd()!;
    await viewer.market!.sawAd(shown);
    await viewer.market!.sawAd(shown);
    await viewer.market!.clickedAd(shown);
    await soon(() => advertiser.market!.campaign(ad.id)['spent'] == 10);
    expect(advertiser.market!.campaign(ad.id)['views'], 1);
    await advertiser.market!.tick();
    await soon(() => viewer.coin!.balance() == Coin.grant + 10);
    expect(viewer.market!.adEarnings, 10);
  });

  test('exchange: the seller locks Mentos, the buyer pays birr, the seller releases', () async {
    final [maker, taker] = await people(2);
    maker.market!.setPayoutDetails('Telebirr 0911 000000');
    final offer = await maker.market!.publish(Kinds.exchange, {
      'title': 'Selling Mentos',
      'side': 'sell',
      'rate': 1250,
      'min': 100,
      'max': 400,
      'methods': ['Telebirr'],
      'windowMins': 30,
    });
    await soon(() => taker.market!.listing(offer.id) != null);
    final t = await taker.market!.openTrade(taker.market!.listing(offer.id)!, 200, 'Telebirr');
    final tid = t['tid'] as String;
    expect(t['birr'], 2500);
    await soon(() => taker.market!.tradeStage(taker.market!.trade(tid)!) == 'locked');
    expect(taker.market!.trade(tid)!['details'], 'Telebirr 0911 000000');
    await taker.market!.acceptTrade(tid);
    await taker.market!.markPaid(tid, 'Ref 7781');
    await soon(() => maker.market!.tradeStage(maker.market!.trade(tid)!) == 'birr sent');
    await maker.market!.releaseTrade(tid);
    await soon(() => taker.coin!.balance() == Coin.grant + 200);
  });

  test('compute: a proof-of-work job runs, is checked, and is paid', () async {
    final [provider, renter] = await people(2);
    final offer = await provider.market!.publish(Kinds.resource, {
      'title': 'Spare cycles',
      'compute': {'jobs': ['pow', 'gzip'], 'perUnit': 3, 'maxMb': 8},
      'bench': {'score': 1000},
    });
    await soon(() => renter.market!.listing(offer.id) != null);
    final job = await renter.market!.submitJob(renter.market!.listing(offer.id)!, 'pow',
        params: {'challenge': 'mentos', 'bits': 12});
    final jid = job['jid'] as String;
    await soon(() => renter.market!.jobStage(renter.market!.job(jid)!) == 'paid');
    expect(renter.market!.job(jid)!['verified'], isTrue);
    await soon(() => provider.coin!.balance() == Coin.grant + 3 - Coin.tradeFee(3, 'resource:'));
  });

  test('storage: a lease stores an encrypted file, passes an audit and pays as it goes', () async {
    final [provider, renter] = await people(2);
    final offer = await provider.market!.publish(Kinds.resource, {
      'title': 'Backup space',
      'storage': {'gb': 5, 'perGbDay': 2},
      'bench': {'freeGb': 20},
    });
    await soon(() => renter.market!.listing(offer.id) != null);
    final lease = await renter.market!.rentStorage(renter.market!.listing(offer.id)!, gb: 1, days: 10);
    final lid = lease['lid'] as String;
    expect(renter.coin!.balance(), Coin.grant - 20);
    await soon(() => renter.market!.leaseStage(renter.market!.lease(lid)!) == 'active');

    final file = File('${root.path}/notes.txt')..writeAsStringSync('private notes ' * 200);
    await renter.market!.storeFile(lid, file);
    await soon(() =>
        (renter.market!.lease(lid)!['files'] as List).every((f) => (f as Map)['stored'] == true));
    final hash = ((renter.market!.lease(lid)!['files'] as List).first as Map)['h'] as String;
    expect(provider.media.hasBlob(hash), isTrue);
    expect(provider.db.file(hash)!.key, isEmpty, reason: 'the provider never gets the key');

    expect(await renter.market!.auditLease(lid), isTrue);
    await soon(() => (renter.market!.lease(lid)!['audits'] as List?)?.isNotEmpty == true);
    expect(((renter.market!.lease(lid)!['audits'] as List).last as Map)['ok'], isTrue);
    await soon(() => provider.coin!.escrow(lease['lock'] as String)!.released == 2);

    await renter.market!.offloadFile(lid, hash);
    expect(renter.media.hasBlob(hash), isFalse);
    final back = await renter.market!.retrieveFile(lid, hash);
    expect(back!.readAsStringSync(), startsWith('private notes'));
  });

  test('device diagnostics measure this machine', () async {
    final e = await person();
    final steps = await e.market!.runDiagnostics().toList();
    final bench = steps.last.result!;
    expect(bench['cores'], greaterThan(0));
    expect(bench['cpu1'], greaterThan(0));
    expect(bench['score'], greaterThan(0));
    expect(e.market!.lastBench, isNotNull);
    expect(jsonEncode(bench).length, lessThan(4000));
  });

  test('free packs install and executable packs are refused', () async {
    final owner = await person();
    final pack = Market.starterPacks.first;
    await owner.installPlugin({...pack, 'body': pack['pack'], 'minor': 0, 'from': ''});
    expect(owner.installedStickers(), contains('🙌'));
    owner.removePlugin('builtin:celebrate');
    expect(owner.installedStickers(), isEmpty);
    expect(
      () => owner.installPlugin({'id': 'bad', 'plugin': 'script', 'body': {'code': 'x'}}),
      throwsArgumentError,
    );
  });
}
