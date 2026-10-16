import 'dart:async';
import 'dart:convert';

import '../../data/models.dart';
import '../engine.dart';
import 'ledger.dart';

class PayRequest {
  const PayRequest({required this.id, required this.peer, required this.amount, required this.memo, required this.at});
  final String id;
  final String peer;
  final int amount;
  final String memo;
  final int at;
}

/// Runs mutual-credit ledgers with every contact. Only the payer proposes
/// an entry; the payee countersigns it if it stays within the credit limit
/// they gave the payer, or holds it for approval otherwise.
class Payments {
  Payments(this.engine, {Duration resendEvery = const Duration(seconds: 60)}) {
    _sub = engine.appMessages.where((m) => m.app == app).listen((m) => _guard(() => _on(m.from, m.m)));
    _resend = Timer.periodic(resendEvery, (_) => _guard(resendPending));
  }

  static const app = 'pay';

  final Engine engine;
  late final StreamSubscription _sub;
  late final Timer _resend;
  final _changes = StreamController<void>.broadcast();
  Future<void> _queue = Future.value();

  Stream<void> get changes => _changes.stream;
  String get _me => engine.me.id;

  /// Messages are handled one at a time so two arriving together cannot
  /// both extend the same ledger position.
  Future<void> _guard(Future<void> Function() f) => _queue = _queue.then((_) => f()).catchError((_) {});

  Future<void> idle() => _queue;

  // ---------------------------------------------------------------------------
  // reading

  List<LedgerEntry> ledger(String peer) => [
        for (final r in engine.db.ledgerRows(Credits.pairId(_me, peer))) ?LedgerEntry.fromJson(jsonDecode(r)),
      ];

  LedgerEntry? _last(String peer) => ledger(peer).lastOrNull;

  /// Positive: [peer] owes you. Negative: you owe [peer].
  int balance(String peer) => balanceOf(_me, ledger(peer));

  Map<String, int> balances() => {for (final p in engine.db.ledgerPeers()) p: balance(p)};

  LedgerEntry? _pending(String peer, String state) {
    final rows = engine.db.ledgerRows(Credits.pairId(_me, peer), state: state);
    return rows.isEmpty ? null : LedgerEntry.fromJson(jsonDecode(rows.last));
  }

  /// A payment you sent that the other person has not countersigned yet.
  LedgerEntry? outgoing(String peer) => _pending(peer, 'out');

  /// Payments waiting for your approval because they go over a limit.
  List<LedgerEntry> approvals() => [
        for (final r in engine.db.ledgerPending())
          if (r.state == 'in') ?LedgerEntry.fromJson(jsonDecode(r.data)),
      ];

  // ---------------------------------------------------------------------------
  // credit limits

  Map<String, int> _limits() {
    try {
      final raw = engine.db.getKv('payLimits');
      if (raw == null) return {};
      return {for (final e in (jsonDecode(raw) as Map).entries) '${e.key}': (e.value as num).toInt()};
    } catch (_) {
      return {};
    }
  }

  /// How much [peer] may owe you before a payment from them needs your
  /// approval. Zero (the default) means every payment asks first.
  int limit(String peer) => _limits()[peer] ?? 0;

  void setLimit(String peer, int minor) {
    final l = _limits()..[peer] = minor.clamp(0, Credits.maxAmount);
    engine.db.setKv('payLimits', jsonEncode(l));
    _changes.add(null);
  }

  // ---------------------------------------------------------------------------
  // paying

  /// Pays [peer] [amount] (hundredths). The payment is final once [peer]
  /// countersigns; until then it shows as waiting.
  Future<LedgerEntry> pay(String peer, int amount, {String memo = ''}) async {
    if (peer == _me) throw ArgumentError('Cannot pay yourself');
    if (amount <= 0 || amount > Credits.maxAmount) throw ArgumentError('Amount out of range');
    if (outgoing(peer) != null) throw StateError('Your last payment to them is still waiting for their signature');
    final m = memo.trim();
    final e = await _propose(peer, amount, m.length > Credits.maxMemo ? m.substring(0, Credits.maxMemo) : m);
    _changes.add(null);
    return e;
  }

  Future<LedgerEntry> _propose(String peer, int amount, String memo, {int? ts}) async {
    final last = _last(peer);
    final draft = LedgerEntry(
      pair: Credits.pairId(_me, peer),
      seq: (last?.seq ?? 0) + 1,
      prev: last?.hash ?? Credits.genesis,
      from: _me,
      to: peer,
      amount: amount,
      memo: memo,
      ts: ts ?? nowMs(),
    );
    final e = draft.copyWith(sigFrom: await engine.me.sign(utf8.encode(draft.body)));
    engine.db.putLedger(e.pair, e.seq, peer, 'out', jsonEncode(e.toJson()), e.ts);
    await engine.sendApp(peer, app, {'op': 'propose', 'e': e.toJson()}, queueId: 'pay:${e.pair}:${e.seq}');
    return e;
  }

  /// Asks [peer] to pay you. They see it and can pay with one tap.
  Future<void> request(String peer, int amount, {String memo = ''}) async {
    final id = '${nowMs()}';
    await engine.sendApp(peer, app, {'op': 'request', 'id': id, 'amt': amount, 'memo': memo}, queueId: 'payreq:$peer:$id');
  }

  List<PayRequest> requests() {
    try {
      final raw = engine.db.getKv('payRequests');
      if (raw == null) return const [];
      return [
        for (final r in jsonDecode(raw) as List)
          if (r is Map)
            PayRequest(
              id: r['id'] as String,
              peer: r['peer'] as String,
              amount: (r['amt'] as num).toInt(),
              memo: r['memo'] as String,
              at: (r['at'] as num).toInt(),
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  void dismissRequest(String id) {
    final rest = [for (final r in requests()) if (r.id != id) r];
    engine.db.setKv('payRequests', jsonEncode([
      for (final r in rest) {'id': r.id, 'peer': r.peer, 'amt': r.amount, 'memo': r.memo, 'at': r.at},
    ]));
    _changes.add(null);
  }

  /// Approves (countersigns) a payment that went over your limit.
  Future<void> approve(LedgerEntry e) => _guard(() async {
        engine.db.deleteLedger(e.pair, e.seq, 'in');
        if (!await _accept(e)) _changes.add(null);
      });

  Future<void> decline(LedgerEntry e) => _guard(() async {
        engine.db.deleteLedger(e.pair, e.seq, 'in');
        await engine.sendApp(e.from, app, {'op': 'reject', 'pair': e.pair, 'seq': e.seq, 'hash': e.hash, 'why': 'declined'});
        _changes.add(null);
      });

  // ---------------------------------------------------------------------------
  // incoming

  Future<void> _on(String from, Map<String, dynamic> m) async {
    switch (m['op']) {
      case 'propose':
        final e = LedgerEntry.fromJson(m['e']);
        if (e != null && e.from == from && e.to == _me) await _onPropose(e);
      case 'accept':
        await _onAccept(from, m);
      case 'reject':
        await _onReject(from, m);
      case 'request':
        final amt = m['amt'];
        final memo = m['memo'];
        final id = m['id'];
        if (amt is! int || amt <= 0 || amt > Credits.maxAmount || memo is! String || id is! String || id.length > 40) return;
        final all = [
          ...requests(),
          PayRequest(id: '$from:$id', peer: from, amount: amt, memo: memo.length > Credits.maxMemo ? memo.substring(0, Credits.maxMemo) : memo, at: nowMs()),
        ];
        engine.db.setKv('payRequests', jsonEncode([
          for (final r in all.take(50)) {'id': r.id, 'peer': r.peer, 'amt': r.amount, 'memo': r.memo, 'at': r.at},
        ]));
        engine.noteActivity(
          Activity(id: 'payreq:$from:$id', kind: 'pay', actor: from, ts: nowMs(), text: 'asked for ${Credits.format(amt)}'),
          title: engine.nameOf(from),
          body: 'Asked you for ${Credits.format(amt)} credits${memo.isEmpty ? '' : ': $memo'}',
          route: '/wallet/$from',
          category: 'dm',
        );
        _changes.add(null);
    }
  }

  Future<void> _onPropose(LedgerEntry e) async {
    final peer = e.from;
    final last = _last(peer);
    // Already countersigned (our accept was lost): just say so again.
    if (last != null && e.seq <= last.seq) {
      final mine = ledger(peer).where((x) => x.seq == e.seq).firstOrNull;
      if (mine != null && mine.hash == e.hash) {
        await engine.sendApp(peer, app, {'op': 'accept', 'pair': e.pair, 'seq': e.seq, 'hash': e.hash, 'st': mine.sigTo});
      }
      return;
    }
    final problem = e.problem(me: _me, peer: peer, last: last);
    if (problem != null || !await e.verifyFrom()) {
      await engine.sendApp(peer, app, {'op': 'reject', 'pair': e.pair, 'seq': e.seq, 'hash': e.hash, 'why': problem ?? 'bad signature'});
      return;
    }
    // Both of us proposed the same position at once. The lower node id
    // wins; the other side moves its payment after it.
    final mine = outgoing(peer);
    LedgerEntry? rebase;
    if (mine != null && mine.seq == e.seq) {
      if (_me.compareTo(peer) < 0) {
        await engine.sendApp(peer, app, {'op': 'reject', 'pair': e.pair, 'seq': e.seq, 'hash': e.hash, 'why': 'conflict'});
        return;
      }
      rebase = mine;
      engine.db.deleteLedger(mine.pair, mine.seq, 'out');
      engine.db.deleteOutbox('pay:${mine.pair}:${mine.seq}');
    }
    final after = balance(peer) + e.amount;
    if (after > limit(peer)) {
      engine.db.putLedger(e.pair, e.seq, peer, 'in', jsonEncode(e.toJson()), e.ts);
      engine.noteActivity(
        Activity(id: 'pay:${e.hash}', kind: 'pay', actor: peer, ts: e.ts, text: 'wants to pay ${Credits.format(e.amount)}'),
        title: engine.nameOf(peer),
        body: 'Wants to pay you ${Credits.format(e.amount)} credits. That goes over your limit, so it needs your approval.',
        route: '/wallet/$peer',
        category: 'dm',
      );
    } else {
      await _accept(e);
    }
    if (rebase != null) await _propose(peer, rebase.amount, rebase.memo, ts: rebase.ts);
    _changes.add(null);
  }

  /// Countersigns and records [e]. False when it no longer fits the ledger.
  Future<bool> _accept(LedgerEntry e) async {
    final peer = e.from;
    if (e.problem(me: _me, peer: peer, last: _last(peer)) != null) {
      await engine.sendApp(peer, app, {'op': 'reject', 'pair': e.pair, 'seq': e.seq, 'hash': e.hash, 'why': 'out of order'});
      return false;
    }
    final done = e.copyWith(sigTo: await engine.me.sign(utf8.encode(e.body)));
    engine.db.putLedger(done.pair, done.seq, peer, 'done', jsonEncode(done.toJson()), done.ts);
    await engine.sendApp(peer, app, {'op': 'accept', 'pair': e.pair, 'seq': e.seq, 'hash': e.hash, 'st': done.sigTo});
    engine.noteActivity(
      Activity(id: 'pay:${e.hash}', kind: 'pay', actor: peer, ts: e.ts, text: 'paid ${Credits.format(e.amount)}'),
      title: engine.nameOf(peer),
      body: 'Paid you ${Credits.format(e.amount)} credits${e.memo.isEmpty ? '' : ' · ${e.memo}'}',
      route: '/wallet/$peer',
      category: 'dm',
    );
    _changes.add(null);
    return true;
  }

  Future<void> _onAccept(String from, Map<String, dynamic> m) async {
    final mine = outgoing(from);
    if (mine == null || m['pair'] != mine.pair || m['seq'] != mine.seq || m['hash'] != mine.hash) return;
    final st = m['st'];
    if (st is! String) return;
    final done = mine.copyWith(sigTo: st);
    if (!await done.verifyTo()) return;
    engine.db.putLedger(done.pair, done.seq, from, 'done', jsonEncode(done.toJson()), done.ts);
    engine.db.deleteLedger(done.pair, done.seq, 'out');
    engine.db.deleteOutbox('pay:${done.pair}:${done.seq}');
    _changes.add(null);
  }

  Future<void> _onReject(String from, Map<String, dynamic> m) async {
    final mine = outgoing(from);
    if (mine == null || m['pair'] != mine.pair || m['seq'] != mine.seq || m['hash'] != mine.hash) return;
    // A conflict resolves itself: their payment reaches us and ours is
    // moved after it. Anything else cancels ours.
    if (m['why'] == 'conflict') return;
    engine.db.deleteLedger(mine.pair, mine.seq, 'out');
    engine.db.deleteOutbox('pay:${mine.pair}:${mine.seq}');
    engine.noteActivity(
      Activity(id: 'payno:${mine.hash}', kind: 'pay', actor: from, ts: nowMs(), text: 'declined ${Credits.format(mine.amount)}'),
      title: engine.nameOf(from),
      body: 'Did not accept your payment of ${Credits.format(mine.amount)} (${m['why'] ?? 'declined'})',
      route: '/wallet/$from',
      category: 'dm',
    );
    _changes.add(null);
  }

  /// Sends unanswered payments again, in case the other side's answer was
  /// lost. Countersigning is idempotent, so duplicates are harmless.
  Future<void> resendPending() async {
    for (final r in engine.db.ledgerPending()) {
      if (r.state != 'out') continue;
      await engine.sendApp(r.peer, app, {'op': 'propose', 'e': jsonDecode(r.data)});
    }
  }

  /// Rechecks every signature and link in the chain with [peer].
  Future<bool> audit(String peer) async {
    LedgerEntry? last;
    for (final e in ledger(peer)) {
      if (e.problem(me: _me, peer: peer, last: last, now: e.ts) != null) return false;
      if (!await e.verifyFrom() || !await e.verifyTo()) return false;
      last = e;
    }
    return true;
  }

  Future<void> dispose() async {
    _resend.cancel();
    await _sub.cancel();
    await _changes.close();
  }
}
