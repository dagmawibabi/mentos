part of 'market.dart';

/// Swapping Mentos for birr between two people, the way peer-to-peer
/// exchanges work: whoever sells Mentos locks them in escrow for the buyer,
/// the buyer accepts and pays birr outside the app (Telebirr, a bank, cash),
/// and the seller releases once the birr arrives. If the seller goes quiet
/// after being paid, the buyer can claim the hold when the window closes;
/// if the birr never came, the seller disputes before it closes. An
/// arbiter named on the offer can settle disputes.
///
/// Birr never touches the ledger. Payment details travel only between the
/// two people, over the encrypted direct channel.
extension Exchange on Market {
  static final _tradeId = RegExp(r'^[0-9a-f]{16}$');

  List<Rec> trades({String? role}) => [
    for (final r in records('trade'))
      if (role == null || r['role'] == role) r,
  ];

  Rec? trade(String tid) => record('trade:$tid');

  /// Birr cents for [minor] Mentos at [rate] birr cents per Mentos.
  static int birrFor(int minor, int rate) => (minor * rate) ~/ Coin.scale;

  static String birr(int cents) => '${(cents / 100).toStringAsFixed(2)} birr';

  /// Private payment instructions the seller shares with a buyer.
  String payoutDetails() => engine.db.getKv('mk-birr') ?? '';
  void setPayoutDetails(String text) {
    engine.db.setKv('mk-birr', text.trim());
    _changed();
  }

  String tradeStage(Rec r) {
    final lock = r['lock'] as String?;
    final e = lock == null ? null : engine.coin?.escrow(lock);
    if (e == null) return r['declined'] == true ? 'declined' : 'waiting for lock';
    switch (e.state) {
      case HoldState.cancelled:
        return 'cancelled';
      case HoldState.settled:
        return e.released > 0 ? 'completed' : 'refunded';
      case HoldState.disputed:
        return 'disputed';
      case HoldState.open:
        return 'locked';
      case HoldState.accepted:
        return r['paid'] != null ? 'birr sent' : 'accepted';
    }
  }

  bool _iSellMentos(Rec r) => r['seller'] == me;

  Future<Rec> openTrade(Listing offer, int amount, String method) => _serial(() async {
    if (offer.kind != Kinds.exchange || !offer.active) throw StateError('This offer is closed');
    if (offer.author == me) throw StateError('That is your own offer');
    final min = offer.body['min'] as int, max = offer.body['max'] as int;
    if (amount < min || amount > max) {
      throw ArgumentError('Trade between ${Coin.format(min)} and ${Coin.format(max)} Mentos');
    }
    if (!(offer.body['methods'] as List).contains(method)) throw ArgumentError('Pick one of their methods');
    final makerSells = offer.body['side'] == 'sell';
    final tid = toHex(randomBytes(8));
    final rate = offer.body['rate'] as int;
    final r = <String, dynamic>{
      'id': 'trade:$tid',
      'kind': 'trade',
      'role': 'taker',
      'tid': tid,
      'offer': offer.id,
      'maker': offer.author,
      'taker': me,
      'seller': makerSells ? offer.author : me,
      'buyer': makerSells ? me : offer.author,
      'amount': amount,
      'rate': rate,
      'birr': birrFor(amount, rate),
      'method': method,
      'windowMins': offer.body['windowMins'],
      'created': nowMs(),
    };
    Map<String, Object>? bundle;
    if (!makerSells) {
      final lock = await _lockTrade(r, offer);
      r['lock'] = lock.hash;
      bundle = {'txs': coin.bundle(lock.hash, depth: 6)};
    }
    _event(r, me, 'opened', text: '${Coin.format(amount)} Mentos for ${birr(r['birr'] as int)} via $method');
    _save(r);
    await _send(offer.author, 'trade', {
      'trade': {'tid': tid, 'offer': offer.id, 'amount': amount, 'method': method, 'lock': r['lock']},
      if (bundle != null) 'bundle': bundle['txs'],
      if (!makerSells && payoutDetails().isNotEmpty) 'details': payoutDetails(),
    }, queue: 'mk-trade:$tid');
    return r;
  });

  Future<CoinTx> _lockTrade(Rec r, Listing offer) {
    final window = Duration(minutes: offer.body['windowMins'] as int);
    final now = DateTime.now();
    final arbiters = (offer.body['arbiters'] as List?)?.whereType<String>().toList() ?? const [];
    final arbiter = arbiters.where((a) => a != r['buyer'] && a != r['seller']).firstOrNull;
    r['arbiter'] = arbiter;
    return coin.lock(
      r['buyer'] as String,
      r['amount'] as int,
      memo: 'exchange:${r['tid']}',
      until: now.add(window + const Duration(hours: 6)),
      ackBy: now.add(window),
      arbiter: arbiter,
    );
  }

  Future<void> _onTradeMessage(String from, Map<String, dynamic> m) async {
    if (m['op'] == 'trade') {
      await _receiveTrade(from, m);
      return;
    }
    final tid = m['tid'], what = m['what'];
    if (tid is! String || what is! String) return;
    final r = trade(tid);
    if (r == null) return;
    final other = r['role'] == 'maker' ? r['taker'] : r['maker'];
    if (from != other && from != r['arbiter']) return;
    final bundle = m['bundle'];
    if (bundle is List) await coin.absorb(bundle);
    final text = m['text'] is String ? m['text'] as String : '';
    if (text.length > 1000) return;
    final fromSeller = from == r['seller'];
    switch (what) {
      case 'locked' when fromSeller:
        final lock = m['lock'];
        if (!isId(lock)) return;
        final e = coin.escrow(lock as String);
        if (e != null && (e.payer != from || e.payee != me || e.amount != r['amount'])) return;
        r['lock'] = lock;
        r['arbiter'] = e?.arbiter;
        if (m['details'] is String) r['details'] = m['details'];
      case 'declined' when r['role'] == 'taker':
        r['declined'] = true;
      case 'paid' when !fromSeller:
        r['paid'] = {'ts': nowMs(), 'text': text};
      case 'accepted' || 'released' || 'cancelled' || 'disputed' || 'claimed' || 'note':
        break;
      default:
        return;
    }
    if (!_event(r, from, what, text: text, eid: m['eid'] is String ? m['eid'] as String : null)) return;
    _save(r);
    final label = switch (what) {
      'locked' => 'locked Mentos for your trade',
      'accepted' => 'accepted the trade',
      'paid' => 'says the birr is sent',
      'released' => 'released the Mentos',
      'disputed' => 'disputed the trade',
      'declined' => 'declined the trade',
      'cancelled' => 'cancelled the trade',
      'claimed' => 'claimed the Mentos',
      _ => 'sent a note about a trade',
    };
    _notify(from, tid, what, label, '/market/r/trade/$tid');
  }

  Future<void> _receiveTrade(String from, Map<String, dynamic> m) async {
    final raw = m['trade'];
    if (raw is! Map) return;
    final tid = raw['tid'], amount = raw['amount'], method = raw['method'];
    if (tid is! String || !_tradeId.hasMatch(tid) || trade(tid) != null) return;
    final offer = listing('${raw['offer']}');
    if (offer == null || offer.author != me || offer.kind != Kinds.exchange) return;
    if (amount is! int || method is! String) return;
    final makerSells = offer.body['side'] == 'sell';
    final rate = offer.body['rate'] as int;
    final r = <String, dynamic>{
      'id': 'trade:$tid',
      'kind': 'trade',
      'role': 'maker',
      'tid': tid,
      'offer': offer.id,
      'maker': me,
      'taker': from,
      'seller': makerSells ? me : from,
      'buyer': makerSells ? from : me,
      'amount': amount,
      'rate': rate,
      'birr': birrFor(amount, rate),
      'method': method,
      'windowMins': offer.body['windowMins'],
      'created': nowMs(),
      if (m['details'] is String && (m['details'] as String).length <= 1000) 'details': m['details'],
    };
    _event(r, from, 'opened', text: '${Coin.format(amount)} Mentos via $method');
    final fits = offer.active &&
        amount >= (offer.body['min'] as int) &&
        amount <= (offer.body['max'] as int) &&
        (offer.body['methods'] as List).contains(method);
    _save(r);
    _notify(from, tid, 'trade', 'opened a trade', '/market/r/trade/$tid');
    if (!fits) {
      await _tradeUp(r, 'declined', text: 'This offer no longer fits that trade');
      r['declined'] = true;
      _save(r);
      return;
    }
    if (makerSells) {
      // Accepting a trade on your own sell offer locks the coins right away
      // when the balance allows; otherwise it waits for you in Activity.
      if (coin.balance() >= amount) {
        try {
          final lock = await _lockTrade(r, offer);
          r['lock'] = lock.hash;
          _save(r);
          await _tradeUp(r, 'locked', extra: {'lock': lock.hash, 'details': payoutDetails()}, stepHash: lock.hash);
        } catch (_) {}
      }
    } else {
      final lock = raw['lock'];
      if (!isId(lock)) return;
      final e = await _escrowFrom(m['bundle'], lock as String);
      if (e == null || e.payer != from || e.payee != me || e.amount != amount || e.memo != 'exchange:$tid') {
        return;
      }
      r['lock'] = lock;
      r['arbiter'] = e.arbiter;
      final tx = await coin.step(lock, 'ack');
      _save(r);
      await _tradeUp(r, 'accepted', stepHash: tx.hash);
    }
  }

  Future<void> _tradeUp(Rec r, String what, {String text = '', Map<String, dynamic> extra = const {}, String? stepHash}) async {
    final eid = '${me.substring(0, 6)}-$what-${toHex(randomBytes(4))}';
    _event(r, me, what, text: text, eid: eid);
    _save(r);
    final other = r['role'] == 'maker' ? r['taker'] as String : r['maker'] as String;
    await _send(other, 'trade-up', {
      'tid': r['tid'],
      'what': what,
      'eid': eid,
      if (text.isNotEmpty) 'text': text,
      if (stepHash != null) 'bundle': coin.bundle(stepHash, depth: 4),
      ...extra,
    }, queue: 'mk-tr:$eid');
  }

  Rec _mustTrade(String tid) {
    final r = trade(tid);
    if (r == null) throw StateError('Trade not found');
    return r;
  }

  /// The maker locks Mentos for a trade on their sell offer.
  Future<void> lockForTrade(String tid) => _serial(() async {
    final r = _mustTrade(tid);
    if (!_iSellMentos(r) || r['lock'] != null) throw StateError('Nothing to lock');
    final offer = listing(r['offer'] as String);
    if (offer == null) throw StateError('Offer is gone');
    final lock = await _lockTrade(r, offer);
    r['lock'] = lock.hash;
    _save(r);
    await _tradeUp(r, 'locked', extra: {'lock': lock.hash, 'details': payoutDetails()}, stepHash: lock.hash);
  });

  Future<void> acceptTrade(String tid) => _serial(() async {
    final r = _mustTrade(tid);
    if (_iSellMentos(r)) throw StateError('The buyer accepts');
    final tx = await coin.step(r['lock'] as String, 'ack');
    await _tradeUp(r, 'accepted', stepHash: tx.hash);
  });

  Future<void> markPaid(String tid, String reference) => _serial(() async {
    final r = _mustTrade(tid);
    if (_iSellMentos(r)) throw StateError('Only the buyer pays birr');
    r['paid'] = {'ts': nowMs(), 'text': reference};
    await _tradeUp(r, 'paid', text: reference);
  });

  Future<void> releaseTrade(String tid) => _serial(() async {
    final r = _mustTrade(tid);
    if (!_iSellMentos(r)) throw StateError('Only the seller releases');
    final tx = await coin.step(r['lock'] as String, 'release');
    await _tradeUp(r, 'released', stepHash: tx.hash);
  });

  Future<void> cancelTrade(String tid) => _serial(() async {
    final r = _mustTrade(tid);
    final lock = r['lock'] as String?;
    if (lock == null) {
      r['declined'] = true;
      await _tradeUp(r, 'declined', text: 'Cancelled before locking');
      return;
    }
    final kind = _iSellMentos(r) ? 'cancel' : 'refund';
    final tx = await coin.step(lock, kind);
    await _tradeUp(r, 'cancelled', stepHash: tx.hash);
  });

  Future<void> disputeTrade(String tid, String reason) => _serial(() async {
    final r = _mustTrade(tid);
    if (!_iSellMentos(r)) throw StateError('The seller disputes; buyers can claim after the window');
    final tx = await coin.step(r['lock'] as String, 'dispute');
    await _tradeUp(r, 'disputed', text: reason, stepHash: tx.hash);
  });

  Future<void> claimTrade(String tid) => _serial(() async {
    final r = _mustTrade(tid);
    final tx = await coin.step(r['lock'] as String, 'claim');
    await _tradeUp(r, 'claimed', stepHash: tx.hash);
  });

  Future<void> noteTrade(String tid, String text) => _serial(() async {
    final r = _mustTrade(tid);
    if (text.trim().isEmpty) return;
    await _tradeUp(r, 'note', text: text.trim());
  });

  Future<void> _tradesTick() async {
    // Task workers and trade buyers collect holds that matured undisputed.
    final c = engine.coin;
    if (c == null) return;
    for (final r in [...trades(), ...taskRecords(role: 'worker')]) {
      final lock = r['lock'] as String?;
      if (lock == null) continue;
      final e = c.escrow(lock);
      if (e == null || !e.actionsFor(me, nowMs()).contains('claim')) continue;
      if (r['kind'] == 'task' && (r['submissions'] as List? ?? const []).isEmpty) continue;
      if (r['kind'] == 'trade' && r['paid'] == null) continue;
      try {
        final tx = await c.step(lock, 'claim');
        if (r['kind'] == 'trade') {
          await _tradeUp(r, 'claimed', stepHash: tx.hash);
        } else {
          await _taskUp(r, r['owner'] as String, 'claimed', stepHash: tx.hash);
        }
      } catch (_) {}
    }
  }
}
