part of 'market.dart';

/// Shop orders. The buyer pays into escrow at checkout; the seller accepts,
/// ships or delivers; the buyer confirms and the hold pays out. The seller
/// can claim a hold the buyer never disputed once its deadline passes.
/// Delivery details travel only to the seller, over the encrypted direct
/// channel, and are stored in the encrypted local database.
extension Orders on Market {
  static final _orderId = RegExp(r'^o-[0-9a-f]{16}$');

  List<Rec> orders({String? role}) => [
    for (final r in records('order'))
      if (role == null || r['role'] == role) r,
  ];

  Rec? order(String id) {
    final r = record(id);
    return r != null && r['kind'] == 'order' ? r : null;
  }

  /// Where an order stands, read from the ledger first and the timeline second.
  String orderStage(Rec r) {
    final lock = r['lock'] as String?;
    final e = lock == null ? null : engine.coin?.escrow(lock);
    if (e == null) return r['invalid'] == true ? 'payment problem' : 'awaiting payment';
    switch (e.state) {
      case HoldState.cancelled:
        return 'cancelled';
      case HoldState.settled:
        if (e.released == 0) return r['declined'] == true ? 'declined' : 'refunded';
        return e.refunded > 0 ? 'partly refunded' : 'completed';
      case HoldState.disputed:
        return 'disputed';
      case HoldState.accepted:
        if (r['delivered'] != null) return 'delivered';
        if (r['shipped'] != null) return 'shipped';
        return 'accepted';
      case HoldState.open:
        return 'placed';
    }
  }

  /// Total due for [lines] (each `{listing, qty, options}`) with the chosen
  /// delivery, priced from the current listings.
  ({int subtotal, int shipping, int total, Map<String, dynamic>? delivery, String? problem}) quote(
    List<({Listing listing, int qty, Map<String, String> options})> lines,
    String? deliveryId,
  ) {
    if (lines.isEmpty) return (subtotal: 0, shipping: 0, total: 0, delivery: null, problem: 'Nothing to buy');
    final seller = lines.first.listing.author;
    var subtotal = 0;
    for (final line in lines) {
      final l = line.listing;
      if (l.author != seller) return (subtotal: 0, shipping: 0, total: 0, delivery: null, problem: 'One seller per order');
      if (!l.active) return (subtotal: 0, shipping: 0, total: 0, delivery: null, problem: '“${l.title}” is no longer available');
      final stock = l.body['stock'] as int? ?? -1;
      if (stock >= 0 && line.qty > stock) {
        return (subtotal: 0, shipping: 0, total: 0, delivery: null, problem: 'Only $stock of “${l.title}” left');
      }
      if (line.qty < 1 || line.qty > 1000) return (subtotal: 0, shipping: 0, total: 0, delivery: null, problem: 'Check the quantity');
      subtotal += l.price * line.qty;
    }
    final methods = (lines.first.listing.body['delivery'] as List).cast<Map>();
    final chosen = methods.where((d) => d['id'] == deliveryId).firstOrNull ?? methods.first;
    final shipping = chosen['price'] as int;
    final total = subtotal + shipping;
    if (total > Coin.maxAmount) {
      return (subtotal: subtotal, shipping: shipping, total: total, delivery: null, problem: 'Order too large');
    }
    return (
      subtotal: subtotal,
      shipping: shipping,
      total: total,
      delivery: chosen.cast<String, dynamic>(),
      problem: null,
    );
  }

  /// Pays into escrow and sends the order to the seller.
  Future<Rec> placeOrder({
    required List<({Listing listing, int qty, Map<String, String> options})> lines,
    String? deliveryId,
    Map<String, String> address = const {},
    String note = '',
    String? arbiter,
  }) async {
    final q = quote(lines, deliveryId);
    if (q.problem != null) throw StateError(q.problem!);
    final seller = lines.first.listing.author;
    if (seller == me) throw StateError('You cannot buy your own listing');
    final allowed = <String>{
      for (final line in lines) ...((line.listing.body['arbiters'] as List?)?.whereType<String>() ?? const []),
    };
    if (arbiter != null && !allowed.contains(arbiter)) {
      throw StateError('Choose one of the seller’s arbiters');
    }
    final digital = lines.every((l) => l.listing.body['condition'] == 'digital') ||
        q.delivery!['kind'] == 'digital';
    final holdDays = lines.map((l) => l.listing.body['holdDays'] as int).reduce(math.max) +
        (q.delivery!['days'] as int);
    final id = 'o-${toHex(randomBytes(8))}';
    final now = DateTime.now();
    final lock = await coin.lock(
      seller,
      q.total,
      memo: 'order:$id',
      until: now.add(Duration(days: holdDays)),
      ackBy: now.add(Duration(days: digital ? 1 : 3)),
      arbiter: arbiter,
    );
    final order = <String, dynamic>{
      'id': id,
      'kind': 'order',
      'buyer': me,
      'seller': seller,
      'arbiter': ?arbiter,
      'lines': [
        for (final line in lines)
          {
            'listing': line.listing.id,
            'title': line.listing.title,
            'unit': line.listing.price,
            'qty': line.qty,
            'options': line.options,
            if (line.listing.cover != null) 'cover': line.listing.cover!.toJson(),
          },
      ],
      'delivery': q.delivery,
      'subtotal': q.subtotal,
      'shipping': q.shipping,
      'total': q.total,
      if (note.trim().isNotEmpty) 'note': note.trim(),
      if (address.values.any((v) => v.trim().isNotEmpty)) 'address': address,
      'lock': lock.hash,
      'holdDays': holdDays,
      'digital': digital,
      'created': nowMs(),
    };
    final rec = <String, dynamic>{...order, 'role': 'buyer'};
    _event(rec, me, 'placed', text: 'Paid ${Coin.format(q.total)} into escrow');
    _save(rec);
    await _send(seller, 'order', {
      'order': order,
      'bundle': coin.bundle(lock.hash, depth: 6),
    }, queue: 'mk-order:$id');
    return rec;
  }

  Future<void> _onOrderMessage(String from, Map<String, dynamic> m) async {
    if (m['op'] == 'order') {
      await _receiveOrder(from, m);
      return;
    }
    final id = m['id'];
    final what = m['what'];
    if (id is! String || what is! String || !_orderId.hasMatch(id)) return;
    var r = order(id);
    if (what == 'case') {
      r ??= _openCase(from, m['order']);
      if (r == null) return;
    }
    if (r == null) return;
    final buyer = r['buyer'] as String, seller = r['seller'] as String;
    final arbiter = r['arbiter'] as String?;
    if (from != buyer && from != seller && from != arbiter) return;
    final text = m['text'] is String ? (m['text'] as String) : '';
    if (text.length > 1000) return;
    final bundle = m['bundle'];
    if (bundle is List) await coin.absorb(bundle);
    final eid = m['eid'] is String ? m['eid'] as String : null;
    final fromSeller = from == seller;
    switch (what) {
      case 'shipped' when fromSeller:
        r['shipped'] = {'ts': nowMs(), 'text': text};
      case 'delivered' when fromSeller:
        final files = refsFrom(m['files']);
        r['delivered'] = {'ts': nowMs(), 'text': text, 'files': [for (final f in files) f.toJson()]};
      case 'declined' when fromSeller:
        r['declined'] = true;
      case 'accepted' || 'refunded' || 'claimed' when fromSeller:
        break;
      case 'cancelled' || 'received' || 'disputed' when from == buyer:
        break;
      case 'ruling' when from == arbiter:
        break;
      case 'note' || 'case':
        break;
      default:
        return;
    }
    if (!_event(r, from, what, text: text, eid: eid)) return;
    _save(r);
    final label = switch (what) {
      'accepted' => 'accepted your order',
      'declined' => 'declined your order',
      'shipped' => 'shipped your order',
      'delivered' => 'delivered your order',
      'refunded' => 'refunded your order',
      'claimed' => 'collected payment for an order',
      'cancelled' => 'cancelled an order',
      'received' => 'confirmed delivery',
      'disputed' => 'opened a dispute',
      'ruling' => 'settled the dispute',
      'case' => 'asked you to settle a dispute',
      _ => 'sent a note about an order',
    };
    _notify(from, id, what, label, '/market/r/order/$id');
  }

  Rec? _openCase(String from, Object? raw) {
    if (raw is! Map) return null;
    final o = raw.cast<String, dynamic>();
    if (o['arbiter'] != me || !_orderId.hasMatch('${o['id']}')) return null;
    if (from != o['buyer'] && from != o['seller']) return null;
    final rec = <String, dynamic>{
      for (final k in ['id', 'buyer', 'seller', 'arbiter', 'lines', 'delivery', 'subtotal', 'shipping', 'total', 'lock', 'holdDays'])
        if (o[k] != null) k: o[k],
      'kind': 'order',
      'role': 'arbiter',
      'created': nowMs(),
    };
    if (!isId(rec['lock']) || !isId(rec['buyer']) || !isId(rec['seller'])) return null;
    return rec;
  }

  Future<void> _receiveOrder(String from, Map<String, dynamic> m) async {
    final raw = m['order'];
    if (raw is! Map) return;
    final o = raw.cast<String, dynamic>();
    final id = o['id'];
    if (id is! String || !_orderId.hasMatch(id)) return;
    if (o['buyer'] != from || o['seller'] != me || !isId(o['lock'])) return;
    if (order(id) != null) return;
    final lines = o['lines'];
    if (lines is! List || lines.isEmpty || lines.length > 20) return;
    if (jsonEncode(o).length > 40000) return;
    var expected = 0;
    var mismatch = false;
    for (final line in lines) {
      if (line is! Map) return;
      final l = listing('${line['listing']}');
      final qty = line['qty'];
      if (l == null || l.author != me || l.kind != Kinds.item || qty is! int || qty < 1) {
        mismatch = true;
        continue;
      }
      expected += l.price * qty;
      if (line['unit'] != l.price) mismatch = true;
    }
    final delivery = o['delivery'];
    if (delivery is Map && delivery['price'] is int) expected += delivery['price'] as int;
    if (expected != o['total']) mismatch = true;
    final rec = <String, dynamic>{...o, 'role': 'seller', 'created': nowMs()};
    if (mismatch) rec['priceChanged'] = true;
    _event(rec, from, 'placed', text: 'Paid ${Coin.format((o['total'] as int?) ?? 0)} into escrow');
    final e = await _escrowFrom(m['bundle'], o['lock'] as String);
    if (e == null) {
      rec['waiting'] = true;
    } else if (!_paysFor(e, rec)) {
      rec['invalid'] = true;
    }
    _save(rec);
    _notify(from, id, 'placed', 'placed an order', '/market/r/order/$id');
    if (e != null && rec['invalid'] != true && !mismatch) await _autoDeliver(rec);
  }

  bool _paysFor(Escrow e, Rec r) =>
      e.payer == r['buyer'] &&
      e.payee == r['seller'] &&
      e.amount == r['total'] &&
      e.memo == 'order:${r['id']}' &&
      e.arbiter == r['arbiter'];

  /// Files a seller attached to a digital listing, kept only on their phone.
  List<MediaRef> digitalFiles(String listingId) =>
      refsFrom(record('digital:$listingId')?['files']);

  void setDigitalFiles(String listingId, List<MediaRef> files) => _save({
    'id': 'digital:$listingId',
    'kind': 'digital',
    'files': [for (final f in files) f.toJson()],
  });

  Future<void> _autoDeliver(Rec r) async {
    if (r['digital'] != true) return;
    final files = <MediaRef>[
      for (final line in (r['lines'] as List).cast<Map>()) ...digitalFiles('${line['listing']}'),
    ];
    if (files.isEmpty) return;
    try {
      await _acceptOrder(r);
      await _deliver(r, files, 'Your download is ready');
    } catch (_) {}
  }

  Future<void> _up(Rec r, String what, {String text = '', Map<String, dynamic> extra = const {}, String? stepHash}) async {
    final eid = '${me.substring(0, 6)}-$what-${toHex(randomBytes(4))}';
    _event(r, me, what, text: text, eid: eid);
    _save(r);
    final body = <String, dynamic>{
      'id': r['id'],
      'what': what,
      'eid': eid,
      if (text.isNotEmpty) 'text': text,
      if (stepHash != null) 'bundle': coin.bundle(stepHash, depth: 3),
      ...extra,
    };
    final peers = {r['buyer'] as String, r['seller'] as String, ?(r['arbiter'] as String?)}..remove(me);
    if (what != 'case' && r['role'] != 'arbiter') peers.remove(r['arbiter']);
    for (final p in peers) {
      await _send(p, 'order-up', body, queue: 'mk-ou:$eid:$p');
    }
  }

  Rec _mustOrder(String id, String role) {
    final r = order(id);
    if (r == null) throw StateError('Order not found');
    if (r['role'] != role) throw StateError('Only the $role can do that');
    return r;
  }

  Future<void> acceptOrder(String id) => _serial(() async => _acceptOrder(_mustOrder(id, 'seller')));

  Future<void> _acceptOrder(Rec r) async {
    final tx = await coin.step(r['lock'] as String, 'ack');
    for (final line in (r['lines'] as List).cast<Map>()) {
      final l = listing('${line['listing']}');
      final stock = l?.body['stock'] as int? ?? -1;
      if (l == null || l.author != me || stock < 0) continue;
      final left = math.max(0, stock - ((line['qty'] as int?) ?? 0));
      await _publish(l.kind, {...l.body, 'stock': left, if (left == 0) 'status': 'sold out'}, id: l.id);
    }
    await _up(r, 'accepted', stepHash: tx.hash);
  }

  Future<void> declineOrder(String id, String reason) => _serial(() async {
    final r = _mustOrder(id, 'seller');
    final tx = await coin.step(r['lock'] as String, 'refund');
    r['declined'] = true;
    await _up(r, 'declined', text: reason, stepHash: tx.hash);
  });

  Future<void> shipOrder(String id, String tracking) => _serial(() async {
    final r = _mustOrder(id, 'seller');
    r['shipped'] = {'ts': nowMs(), 'text': tracking};
    await _up(r, 'shipped', text: tracking);
  });

  Future<void> deliverOrder(String id, List<MediaRef> files, String text) =>
      _serial(() => _deliver(_mustOrder(id, 'seller'), files, text));

  Future<void> _deliver(Rec r, List<MediaRef> files, String text) async {
    r['delivered'] = {'ts': nowMs(), 'text': text, 'files': [for (final f in files) f.toJson()]};
    await _up(r, 'delivered', text: text, extra: {'files': [for (final f in files) f.toJson()]});
  }

  Future<void> refundOrder(String id, int amount, String reason) => _serial(() async {
    final r = _mustOrder(id, 'seller');
    final tx = await coin.step(r['lock'] as String, 'refund', amount: amount);
    await _up(r, 'refunded', text: reason.isEmpty ? 'Refunded ${Coin.format(amount)}' : reason, stepHash: tx.hash);
  });

  Future<void> claimOrder(String id) => _serial(() async {
    final r = _mustOrder(id, 'seller');
    final tx = await coin.step(r['lock'] as String, 'claim');
    await _up(r, 'claimed', stepHash: tx.hash);
  });

  Future<void> cancelOrder(String id) => _serial(() async {
    final r = _mustOrder(id, 'buyer');
    final tx = await coin.step(r['lock'] as String, 'cancel');
    await _up(r, 'cancelled', stepHash: tx.hash);
  });

  /// The buyer has what they paid for: the hold pays the seller.
  Future<void> confirmOrder(String id) => _serial(() async {
    final r = _mustOrder(id, 'buyer');
    final tx = await coin.step(r['lock'] as String, 'release');
    await _up(r, 'received', text: 'Confirmed and released payment', stepHash: tx.hash);
  });

  Future<void> disputeOrder(String id, String reason) => _serial(() async {
    final r = _mustOrder(id, 'buyer');
    if (reason.trim().isEmpty) throw ArgumentError('Say what went wrong');
    final tx = await coin.step(r['lock'] as String, 'dispute');
    await _up(r, 'disputed', text: reason, stepHash: tx.hash);
    if (r['arbiter'] is String) await _sendCase(r, reason);
  });

  Future<void> _sendCase(Rec r, String reason) async {
    final eid = '${me.substring(0, 6)}-case-${toHex(randomBytes(4))}';
    final snapshot = {
      for (final k in ['id', 'buyer', 'seller', 'arbiter', 'lines', 'delivery', 'subtotal', 'shipping', 'total', 'lock', 'holdDays'])
        if (r[k] != null) k: r[k],
    };
    await _send(r['arbiter'] as String, 'order-up', {
      'id': r['id'],
      'what': 'case',
      'eid': eid,
      'text': reason,
      'order': snapshot,
      'bundle': coin.bundle(r['lock'] as String, depth: 6),
    }, queue: 'mk-case:$eid');
  }

  /// The arbiter splits a disputed hold: [toSeller] is released, the rest refunded.
  Future<void> ruleOrder(String id, int toSeller, String text) => _serial(() async {
    final r = _mustOrder(id, 'arbiter');
    final lock = r['lock'] as String;
    final e = coin.escrow(lock);
    if (e == null || !e.disputed) throw StateError('This hold is not disputed');
    if (toSeller < 0 || toSeller > e.remaining) throw ArgumentError('Amount out of range');
    String? last;
    final back = e.remaining - toSeller;
    if (back > 0) last = (await coin.step(lock, 'refund', amount: back)).hash;
    if (toSeller > 0) last = (await coin.step(lock, 'release', amount: toSeller)).hash;
    final eid = '${me.substring(0, 6)}-ruling-${toHex(randomBytes(4))}';
    _event(r, me, 'ruling', text: text, eid: eid);
    _save(r);
    for (final p in [r['buyer'] as String, r['seller'] as String]) {
      await _send(p, 'order-up', {
        'id': id,
        'what': 'ruling',
        'eid': eid,
        'text': text.isEmpty ? '${Coin.format(toSeller)} to the seller, ${Coin.format(back)} back to the buyer' : text,
        if (last != null) 'bundle': coin.bundle(last, depth: 3),
      }, queue: 'mk-ou:$eid:$p');
    }
  });

  Future<void> noteOrder(String id, String text) => _serial(() async {
    final r = order(id);
    if (r == null || text.trim().isEmpty) return;
    await _up(r, 'note', text: text.trim());
  });

  Future<void> _ordersTick() async {
    final c = engine.coin;
    if (c == null) return;
    for (final r in orders()) {
      final lock = r['lock'] as String?;
      if (lock == null) continue;
      final e = c.escrow(lock);
      if (r['waiting'] == true && e != null) {
        r.remove('waiting');
        if (!_paysFor(e, r)) r['invalid'] = true;
        _save(r);
        if (r['invalid'] != true && r['priceChanged'] != true) await _autoDeliver(r);
        continue;
      }
      // A seller collects holds the buyer let mature without a dispute.
      if (r['role'] == 'seller' && e != null && e.actionsFor(me, nowMs()).contains('claim')) {
        try {
          final tx = await c.step(lock, 'claim');
          await _up(r, 'claimed', stepHash: tx.hash);
        } catch (_) {}
      }
    }
  }
}
