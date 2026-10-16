import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/crypto/crypto.dart';
import '../../data/models.dart';
import '../engine.dart';
import 'ledger.dart';

/// Mentos coins: one shared ledger, kept by every phone that joins the
/// peer network.
///
/// The network treasury is created holding [Coin.supply]. Nothing else
/// mints coins. A new identity may draw exactly [Coin.grant] from that
/// treasury once. The draw is signed by the identity and is the same bytes
/// every time, so a second device restored from the same key produces the
/// same grant rather than a new one. If the treasury cannot cover the
/// grant, the draw waits until checkmarks or service fees refill it.
/// Later payments are signed by the sender and name the hash of their
/// previous payment. Phones gossip the payments and, given the same set,
/// walk them in the same order, so balances agree without a server.
///
/// Two payments that spend the same coins cannot both count. The one with
/// the lower hash is the one the ledger keeps.
abstract final class Coin {
  static const scale = Credits.scale;
  static const grant = 5 * scale;
  static const maxAmount = Credits.maxAmount;
  static const maxMemo = Credits.maxMemo;
  static const genesis = Credits.genesis;
  static const app = 'coin-v2';

  /// Every coin starts here. Grants spend it down; checkmarks and service
  /// fees pay it back. There is no further issuance.
  static const supply = 100000000 * scale;

  /// Checkmark price at a full treasury, and the most it is allowed to reach.
  static const badgeBase = 10 * scale;
  static const badgeCap = 1000 * scale;

  /// Reserved protocol account: no private key and no welcome grant.
  static final treasury = toHex(
    sha256(utf8.encode('mentos:network-treasury:v1')),
  );
  static bool get treasuryConfigured => true;

  /// 10.00 when the treasury is full. Each 5.00 drawn out adds 0.01, and
  /// deposits that refill the treasury bring the price back down.
  static int badgePrice(int treasury) {
    final held = treasury < 0 ? 0 : (treasury > supply ? supply : treasury);
    final raw = badgeBase + (supply - held) ~/ grant;
    if (raw < badgeBase) return badgeBase;
    if (raw > badgeCap) return badgeCap;
    return raw;
  }

  static int rewardAmount(int paid) => (paid ~/ 20).clamp(0, 10);
  static int serviceFee(int amount, String memo) =>
      memo.startsWith('task:') || memo.startsWith('resource:')
      ? amount ~/ 20
      : 0;
  static const topicLabel = 'mentos-coin-v2';

  /// Gossip topic every running node joins.
  static final topic = toHex(sha256(utf8.encode(topicLabel)));

  static int? parse(String input) => Credits.parse(input);
  static String format(int minor, {bool sign = false}) =>
      Credits.format(minor, sign: sign);
}

class CoinTx {
  const CoinTx({
    required this.kind,
    required this.from,
    required this.to,
    required this.amount,
    required this.seq,
    required this.prev,
    required this.memo,
    required this.ts,
    required this.sig,
  });

  final String kind;
  final String from;
  final String to;
  final int amount;
  final int seq;
  final String prev;
  final String memo;
  final int ts;
  final String sig;

  bool get isMint => kind == 'mint';

  /// The exact bytes the sender signs. Key order is part of the signature.
  String get body => jsonEncode({
    'v': 1,
    'kind': kind,
    'from': from,
    'to': to,
    'amt': amount,
    'seq': seq,
    'prev': prev,
    'memo': memo,
    'ts': ts,
  });

  String get hash => toHex(sha256(utf8.encode(body)));

  CoinTx withSig(String sig) => CoinTx(
    kind: kind,
    from: from,
    to: to,
    amount: amount,
    seq: seq,
    prev: prev,
    memo: memo,
    ts: ts,
    sig: sig,
  );

  Map<String, Object> toJson() => {
    'kind': kind,
    'from': from,
    'to': to,
    'amt': amount,
    'seq': seq,
    'prev': prev,
    'memo': memo,
    'ts': ts,
    'sig': sig,
  };

  static CoinTx? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = j['kind'],
        from = j['from'],
        to = j['to'],
        prev = j['prev'],
        memo = j['memo'];
    final amt = j['amt'], seq = j['seq'], ts = j['ts'], sig = j['sig'];
    if (kind is! String ||
        from is! String ||
        to is! String ||
        prev is! String ||
        memo is! String) {
      return null;
    }
    if (amt is! int || seq is! int || ts is! int || sig is! String) return null;
    return CoinTx(
      kind: kind,
      from: from,
      to: to,
      amount: amt,
      seq: seq,
      prev: prev,
      memo: memo,
      ts: ts,
      sig: sig,
    );
  }

  /// Shape only. Signatures are checked separately.
  String? problem({int? now}) {
    if (!_id(from) || !_id(to) || from == Coin.treasury) return 'bad identity';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(prev)) return 'bad previous';
    if (kind == 'mint') {
      if (from != to ||
          amount != Coin.grant ||
          seq != 0 ||
          prev != Coin.genesis ||
          memo.isNotEmpty ||
          ts != 0) {
        return 'grant must be 5.00 once';
      }
      return null;
    }
    if (kind != 'send' && kind != 'reward') return 'unknown payment';
    if (kind == 'reward' &&
        (from != to || !RegExp(r'^reward:[0-9a-f]{64}$').hasMatch(memo))) {
      return 'bad reward';
    }
    if (kind == 'send' && from == to) return 'cannot pay yourself';
    if (amount <= 0 || amount > Coin.maxAmount) return 'bad amount';
    if (memo.length > Coin.maxMemo) return 'memo too long';
    if (seq < 1 || seq > 100000) return 'bad sequence';
    final t = now ?? DateTime.now().millisecondsSinceEpoch;
    if (ts <= 0 || ts > t + const Duration(minutes: 10).inMilliseconds) {
      return 'bad time';
    }
    return null;
  }

  Future<bool> verify() async =>
      sig.isNotEmpty && await Identity.verify(from, utf8.encode(body), sig);
}

bool _id(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

/// What every phone computes from the same pool of signed payments.
class CoinView {
  const CoinView({
    required this.chains,
    required this.balances,
    this.badges = const {},
  });
  final Map<String, List<CoinTx>> chains;
  final Map<String, int> balances;

  /// Identities whose accepted checkmark payment met the treasury price.
  final Set<String> badges;

  int balanceOf(String id) => balances[id] ?? 0;

  bool contains(String hash) {
    for (final chain in chains.values) {
      for (final tx in chain) {
        if (tx.hash == hash) return true;
      }
    }
    return false;
  }
}

bool _badgeMemo(String memo) => memo == 'badge' || memo.startsWith('badge:');

/// Walks the pool in hash order so two phones with the same payments
/// produce the same chains. The treasury opens with [supply] (the protocol
/// endowment, unless a test passes a smaller one). A welcome grant counts
/// only when that balance can cover it. A later payment counts only when
/// it extends its sender's chain and the sender can cover it.
CoinView compileCoin(List<CoinTx> pool, {int? supply}) {
  final endowment = supply ?? Coin.supply;
  final byFrom = <String, List<CoinTx>>{};
  for (final tx in pool) {
    if (tx.problem() != null) continue;
    (byFrom[tx.from] ??= []).add(tx);
  }
  final pendingMints = <String, CoinTx>{};
  for (final entry in byFrom.entries) {
    CoinTx? mint;
    for (final tx in entry.value) {
      if (tx.isMint) mint = tx;
    }
    if (mint != null) pendingMints[entry.key] = mint;
  }
  final tips = <String, CoinTx>{};
  final chains = <String, List<CoinTx>>{};
  final balances = <String, int>{Coin.treasury: endowment};
  final accepted = <String, CoinTx>{};
  final rewarded = <String>{};
  final badges = <String>{};
  var guard = 0;
  while (guard++ < pool.length + 2) {
    final ready = <CoinTx>[];
    final treasuryNow = balances[Coin.treasury] ?? 0;
    for (final mint in pendingMints.values) {
      if (treasuryNow >= mint.amount) ready.add(mint);
    }
    for (final account in tips.keys) {
      final tip = tips[account]!;
      final options =
          (byFrom[account] ?? const <CoinTx>[])
              .where(
                (t) => !t.isMint && t.seq == tip.seq + 1 && t.prev == tip.hash,
              )
              .toList()
            ..sort((a, b) => a.hash.compareTo(b.hash));
      for (final tx in options) {
        final receipt = tx.kind == 'reward'
            ? accepted[tx.memo.substring(7)]
            : null;
        final eligible =
            receipt != null &&
            receipt.to == tx.from &&
            receipt.from != tx.from &&
            (receipt.memo.startsWith('task:') ||
                receipt.memo.startsWith('resource:')) &&
            tx.amount == Coin.rewardAmount(receipt.amount) &&
            !rewarded.contains(receipt.hash);
        if (tx.kind == 'reward'
            ? eligible && treasuryNow >= tx.amount
            : (balances[account] ?? 0) >=
                  tx.amount + Coin.serviceFee(tx.amount, tx.memo)) {
          ready.add(tx);
          break;
        }
      }
    }
    if (ready.isEmpty) break;
    ready.sort((a, b) => a.hash.compareTo(b.hash));
    final tx = ready.first;
    if (tx.isMint) {
      pendingMints.remove(tx.from);
      tips[tx.from] = tx;
      chains[tx.from] = [tx];
      balances[Coin.treasury] = treasuryNow - tx.amount;
      balances[tx.from] = (balances[tx.from] ?? 0) + tx.amount;
      continue;
    }
    tips[tx.from] = tx;
    chains[tx.from]!.add(tx);
    accepted[tx.hash] = tx;
    if (tx.kind == 'send' &&
        tx.to == Coin.treasury &&
        _badgeMemo(tx.memo) &&
        tx.amount >= Coin.badgePrice(treasuryNow)) {
      badges.add(tx.from);
    }
    final source = tx.kind == 'reward' ? Coin.treasury : tx.from;
    if (tx.kind == 'reward') rewarded.add(tx.memo.substring(7));
    final fee = tx.kind == 'send' ? Coin.serviceFee(tx.amount, tx.memo) : 0;
    balances[source] = (balances[source] ?? 0) - tx.amount - fee;
    balances[Coin.treasury] = (balances[Coin.treasury] ?? 0) + fee;
    balances[tx.to] = (balances[tx.to] ?? 0) + tx.amount;
  }
  return CoinView(chains: chains, balances: balances, badges: badges);
}

enum _Keep { saved, duplicate, reject, wait }

/// Keeps this device's copy of the ledger and exchanges it with peers.
class CoinLedger {
  CoinLedger(this.engine) {
    _sub = engine.appMessages.where((m) => m.app == Coin.app).listen((m) {
      unawaited(onMessage(m.from, m.m));
    });
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_closed) unawaited(_guard(() => announce()));
    });
  }

  final Engine engine;
  StreamSubscription<({String from, String app, Map<String, dynamic> m})>? _sub;
  Timer? _timer;
  final _changes = StreamController<void>.broadcast();
  final _noted = <String>{};
  final _orphans = <String, CoinTx>{};
  Future<void> _queue = Future.value();
  bool _closed = false;
  DateTime _lastAnnounce = DateTime.fromMillisecondsSinceEpoch(0);
  bool _seeded = false;

  Stream<void> get changes => _changes.stream;
  String get _me => engine.me.id;

  Future<void> _guard(Future<void> Function() f) {
    final next = _queue.then((_) => f()).catchError((_) {});
    _queue = next;
    return next;
  }

  Future<void> idle() => _queue;

  Future<void> dispose() async {
    _closed = true;
    _timer?.cancel();
    await _sub?.cancel();
    await _queue;
    await _changes.close();
  }

  // ---------------------------------------------------------------------------
  // reading

  List<CoinTx> pool() => [
    for (final raw in engine.db.coinTxRows()) ?CoinTx.fromJson(jsonDecode(raw)),
  ];

  CoinView view() => compileCoin(pool());

  int balance([String? id]) => view().balanceOf(id ?? _me);

  /// Payments that touch [id], newest first. The welcome grant has time 0,
  /// so it sits at the bottom until something else happens.
  List<CoinTx> history([String? id]) {
    final who = id ?? _me;
    final v = view();
    final all = <CoinTx>[];
    for (final chain in v.chains.values) {
      for (final tx in chain) {
        if (tx.from == who ||
            tx.to == who ||
            (who == Coin.treasury &&
                (tx.isMint ||
                    tx.kind == 'reward' ||
                    Coin.serviceFee(tx.amount, tx.memo) > 0))) {
          all.add(tx);
        }
      }
    }
    all.sort((a, b) {
      final byTime = b.ts.compareTo(a.ts);
      return byTime != 0 ? byTime : b.hash.compareTo(a.hash);
    });
    return all;
  }

  int get accounts => view().chains.length;

  bool hasBadge(String id) =>
      Coin.treasuryConfigured && view().badges.contains(id);

  List<CoinTx> rewardReceipts() {
    final v = view();
    final txs = v.chains.values.expand((c) => c).toList();
    final claimed = txs
        .where((t) => t.kind == 'reward')
        .map((t) => t.memo)
        .toSet();
    return txs
        .where(
          (t) =>
              t.kind == 'send' &&
              t.to == _me &&
              (t.memo.startsWith('task:') || t.memo.startsWith('resource:')) &&
              Coin.rewardAmount(t.amount) > 0 &&
              !claimed.contains('reward:${t.hash}'),
        )
        .toList();
  }

  Future<CoinTx> claimReward(String receipt) {
    final done = Completer<CoinTx>();
    unawaited(
      _guard(() async {
        try {
          final payment = rewardReceipts()
              .where((t) => t.hash == receipt)
              .firstOrNull;
          if (payment == null) {
            throw StateError('No eligible unclaimed contribution');
          }
          final amount = Coin.rewardAmount(payment.amount);
          if (balance(Coin.treasury) < amount) {
            throw StateError('The treasury needs more funding');
          }
          final tip = view().chains[_me]!.last;
          final draft = CoinTx(
            kind: 'reward',
            from: _me,
            to: _me,
            amount: amount,
            seq: tip.seq + 1,
            prev: tip.hash,
            memo: 'reward:$receipt',
            ts: nowMs(),
            sig: '',
          );
          final tx = draft.withSig(
            await engine.me.sign(utf8.encode(draft.body)),
          );
          await _ingest(tx, relay: true);
          if (!view().contains(tx.hash)) {
            throw StateError('Reward is not accepted by this ledger view');
          }
          await announce(force: true);
          done.complete(tx);
        } catch (e, st) {
          done.completeError(e, st);
        }
      }),
    );
    return done.future;
  }

  // ---------------------------------------------------------------------------
  // grant and paying

  /// Writes the one-time welcome grant if this identity does not have it yet.
  /// The coins come out of the treasury when the ledger applies the grant.
  Future<void> ensureGrant() => _guard(() async {
    _seedNotes();
    if (engine.db.coinMint(_me) != null) return;
    final draft = CoinTx(
      kind: 'mint',
      from: _me,
      to: _me,
      amount: Coin.grant,
      seq: 0,
      prev: Coin.genesis,
      memo: '',
      ts: 0,
      sig: '',
    );
    final tx = draft.withSig(await engine.me.sign(utf8.encode(draft.body)));
    await _ingest(tx, relay: false);
  });

  /// Sends [amount] (hundredths of a Mentos) to [to].
  Future<CoinTx> pay(String to, int amount, {String memo = ''}) {
    final done = Completer<CoinTx>();
    unawaited(
      _guard(() async {
        try {
          done.complete(await _pay(to, amount, memo));
        } catch (e, st) {
          if (!done.isCompleted) done.completeError(e, st);
        }
      }),
    );
    return done.future;
  }

  /// Serialize receipt lookup and payment together to make retries safe.
  Future<CoinTx> payOnce(String to, int amount, {required String memo}) {
    final done = Completer<CoinTx>();
    unawaited(
      _guard(() async {
        try {
          final existing = history()
              .where((t) => t.from == _me && t.memo == memo)
              .firstOrNull;
          if (existing != null &&
              (existing.to != to || existing.amount != amount)) {
            throw StateError('A different payment already uses this reference');
          }
          done.complete(existing ?? await _pay(to, amount, memo));
        } catch (e, st) {
          done.completeError(e, st);
        }
      }),
    );
    return done.future;
  }

  Future<CoinTx> _pay(String to, int amount, String memo) async {
    if (to == _me) throw ArgumentError('Cannot pay yourself');
    if (!_id(to)) throw ArgumentError('That address is not a Mentos identity');
    if (amount <= 0 || amount > Coin.maxAmount) {
      throw ArgumentError('Amount out of range');
    }
    final note = memo.trim();
    final chain = view().chains[_me];
    final tip = chain == null || chain.isEmpty ? null : chain.last;
    if (tip == null) throw StateError('Wallet is not ready');
    if (balance(_me) < amount + Coin.serviceFee(amount, note)) {
      throw StateError('Not enough Mentos');
    }
    final draft = CoinTx(
      kind: 'send',
      from: _me,
      to: to,
      amount: amount,
      seq: tip.seq + 1,
      prev: tip.hash,
      memo: note.length > Coin.maxMemo ? note.substring(0, Coin.maxMemo) : note,
      ts: nowMs(),
      sig: '',
    );
    final tx = draft.withSig(await engine.me.sign(utf8.encode(draft.body)));
    final kept = await _ingest(tx, relay: true);
    if (kept == _Keep.reject) {
      final why = tx.problem();
      throw StateError(why ?? 'The ledger refused that payment');
    }
    if (!view().contains(tx.hash)) {
      throw StateError('Another payment already spent those coins');
    }
    try {
      await engine.sendApp(to, Coin.app, {
        'op': 'tx',
        'tx': tx.toJson(),
      }, queueId: 'coin:${tx.hash}');
    } catch (_) {}
    await announce(force: true);
    return tx;
  }

  // ---------------------------------------------------------------------------
  // network

  /// Joins the coin topic and tells neighbours what this phone holds.
  Future<void> join() => _guard(() async {
    if (_closed) return;
    try {
      await engine.net.join(Coin.topic, const []);
    } catch (_) {}
    await announce(force: true);
  });

  Future<void> onPeer(String peer) => _guard(() async {
    if (_closed || peer == _me) return;
    try {
      await engine.sendApp(peer, Coin.app, {'op': 'sum', 'list': _summaries()});
    } catch (_) {}
  });

  Future<void> announce({bool force = false}) async {
    if (_closed) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastAnnounce) < const Duration(seconds: 2)) {
      return;
    }
    _lastAnnounce = now;
    await _gossip({'op': 'sum', 'list': _summaries()});
  }

  Future<void> onMessage(String from, Map<String, dynamic> m) =>
      _guard(() async {
        if (_closed || from == _me) return;
        switch (m['op']) {
          case 'tx':
            final tx = CoinTx.fromJson(m['tx']);
            if (tx != null) await _ingest(tx, relay: true);
          case 'txs':
            final list = m['txs'];
            if (list is List) {
              for (final raw in list) {
                final tx = CoinTx.fromJson(raw);
                if (tx != null) await _ingest(tx, relay: true);
              }
            }
          case 'sum':
            await _onSummary(from, m['list']);
          case 'want':
            final id = m['id'];
            if (id is String) await _sendAccount(from, id);
        }
      });

  Future<void> _onSummary(String from, Object? raw) async {
    if (raw is! List) return;
    final remote = <String, ({int n, String sum})>{};
    for (final row in raw) {
      if (row is! Map) continue;
      final id = row['id'];
      final n = row['n'];
      final sum = row['sum'];
      final count = n is int ? n : (n is num ? n.toInt() : null);
      if (id is String && count != null && sum is String) {
        remote[id] = (n: count, sum: sum);
      }
    }
    final local = _summaryMap();
    for (final id in {...remote.keys, ...local.keys}) {
      final mine = local[id];
      final theirs = remote[id];
      final differ =
          mine == null ||
          theirs == null ||
          mine.n != theirs.n ||
          mine.sum != theirs.sum;
      if (!differ) continue;
      if (mine != null) await _sendAccount(from, id);
      if (theirs != null) {
        try {
          await engine.sendApp(from, Coin.app, {'op': 'want', 'id': id});
        } catch (_) {}
      }
    }
  }

  Future<void> _sendAccount(String to, String id) async {
    final txs = [
      for (final tx in pool())
        if (tx.from == id) tx,
    ];
    if (txs.isEmpty) return;
    for (var i = 0; i < txs.length; i += 30) {
      final end = i + 30 > txs.length ? txs.length : i + 30;
      final body = {
        'op': 'txs',
        'txs': [for (final tx in txs.sublist(i, end)) tx.toJson()],
      };
      try {
        await engine.sendApp(to, Coin.app, body);
      } catch (_) {}
      await _gossip(body);
    }
  }

  Future<void> _gossip(Map<String, dynamic> body) async {
    if (_closed || !engine.running) return;
    try {
      await engine.net.broadcast(
        Coin.topic,
        Uint8List.fromList(utf8.encode(jsonEncode(body))),
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // pool

  void _seedNotes() {
    if (_seeded) return;
    _seeded = true;
    for (final a in engine.db.activity()) {
      if (a.kind == 'coin' && a.id.startsWith('coin:')) {
        _noted.add(a.id.substring(5));
      }
    }
  }

  List<Map<String, Object>> _summaries() => [
    for (final e in _summaryMap().entries)
      {'id': e.key, 'n': e.value.n, 'sum': e.value.sum},
  ];

  Map<String, ({int n, String sum})> _summaryMap() {
    final hashes = <String, List<String>>{};
    for (final tx in pool()) {
      (hashes[tx.from] ??= []).add(tx.hash);
    }
    return {
      for (final e in hashes.entries)
        e.key: (
          n: e.value.length,
          sum: toHex(sha256(utf8.encode((e.value..sort()).join()))),
        ),
    };
  }

  Future<_Keep> _ingest(CoinTx tx, {required bool relay}) async {
    final first = await _consider(tx, relay: relay);
    if (first == _Keep.wait) {
      if (_orphans.length < 300) _orphans[tx.hash] = tx;
    }
    await _drain();
    _publish();
    return engine.db.coinTxByHash(tx.hash) == null ? first : _Keep.saved;
  }

  Future<void> _drain() async {
    var again = true;
    while (again) {
      again = false;
      for (final tx in _orphans.values.toList()) {
        final kept = await _consider(tx, relay: true);
        if (kept == _Keep.wait) continue;
        _orphans.remove(tx.hash);
        if (kept == _Keep.saved) again = true;
      }
    }
  }

  Future<_Keep> _consider(CoinTx tx, {required bool relay}) async {
    final now = nowMs();
    if (tx.problem(now: now) != null) return _Keep.reject;
    if (!await tx.verify()) return _Keep.reject;
    final kept = _tryStore(tx);
    if (kept == _Keep.saved && relay) {
      await _gossip({'op': 'tx', 'tx': tx.toJson()});
    }
    return kept;
  }

  _Keep _tryStore(CoinTx tx) {
    if (engine.db.coinTxByHash(tx.hash) != null) return _Keep.duplicate;
    if (engine.db.coinCount(tx.from) >= 2000) return _Keep.reject;
    if (tx.isMint) {
      if (engine.db.coinMint(tx.from) != null) return _Keep.reject;
      engine.db.putCoinTx(
        tx.hash,
        tx.from,
        tx.seq,
        tx.to,
        tx.amount,
        jsonEncode(tx.toJson()),
        tx.ts,
      );
      return _Keep.saved;
    }
    final parentRaw = engine.db.coinTxByHash(tx.prev);
    if (parentRaw == null) return _Keep.wait;
    final parent = CoinTx.fromJson(jsonDecode(parentRaw));
    if (parent == null || parent.from != tx.from || parent.seq + 1 != tx.seq) {
      return _Keep.reject;
    }
    engine.db.putCoinTx(
      tx.hash,
      tx.from,
      tx.seq,
      tx.to,
      tx.amount,
      jsonEncode(tx.toJson()),
      tx.ts,
    );
    return _Keep.saved;
  }

  void _publish() {
    if (_closed || _changes.isClosed) return;
    try {
      _changes.add(null);
      _seedNotes();
      final me = _me;
      for (final tx in history(me)) {
        if (tx.isMint || tx.to != me || tx.from == me) continue;
        if (!_noted.add(tx.hash)) continue;
        engine.noteActivity(
          Activity(
            id: 'coin:${tx.hash}',
            kind: 'coin',
            actor: tx.from,
            ts: tx.ts,
            text: 'sent ${Coin.format(tx.amount)} Mentos',
          ),
          title: engine.nameOf(tx.from),
          body: 'Sent ${Coin.format(tx.amount)} Mentos',
          route: '/wallet',
          category: 'other',
        );
      }
    } catch (_) {}
  }
}
