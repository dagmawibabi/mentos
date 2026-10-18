import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/crypto/crypto.dart';
import '../../data/models.dart';
import '../engine.dart';
import 'ledger.dart';

/// Mentos coins: one shared ledger, kept by every phone that joins the
/// peer network. There is no server, miner or operator.
///
/// Every account is a chain of payments signed by its owner. Each payment
/// names the hash of the one before it, so an owner can only append. Phones
/// gossip payments, and given the same pool they walk them in the same
/// order, so balances agree without anyone in charge.
///
/// The network treasury is created holding [Coin.supply]. Nothing else
/// mints coins. A new identity may draw exactly [Coin.grant] once. The draw
/// is the same bytes every time, so a restored key gets the same grant
/// rather than a new one.
///
/// Escrow is part of the ledger. A `lock` moves coins out of the payer's
/// balance into a hold that names the payee (and optionally an arbiter).
/// Only the payer can release a hold to the payee, only the payee can hand
/// it back, and once the deadline passes an accepted hold the payer never
/// disputed can be claimed by the payee. An arbiter can settle a disputed
/// hold either way. See docs/COIN.md.
///
/// Two payments at the same place in one chain are a double spend. Every
/// phone signs a vote for the first one it sees. The branch backed by more
/// stake wins, ties go to the lower hash, and the account is flagged.
abstract final class Coin {
  static const scale = Credits.scale;
  static const grant = 5 * scale;
  static const maxAmount = Credits.maxAmount;
  static const maxMemo = Credits.maxMemo;
  static const genesis = Credits.genesis;
  static const app = 'coin-v3';

  /// Every coin starts here. Grants spend it down; checkmarks and fees pay
  /// it back. There is no further issuance.
  static const supply = 100000000 * scale;

  /// Checkmark price at a full treasury, and the most it is allowed to reach.
  static const badgeBase = 10 * scale;
  static const badgeCap = 1000 * scale;

  /// Longest an escrow can stay open.
  static const maxHold = Duration(days: 365);

  /// Most entries one account may have in the pool.
  static const maxChain = 20000;

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

  /// Paid by the sender on a plain `send` whose memo marks a service.
  static int serviceFee(int amount, String memo) =>
      memo.startsWith('task:') || memo.startsWith('resource:')
      ? amount ~/ 20
      : 0;

  /// Taken from what the payee receives when an escrow for a trade pays
  /// out: 2% for orders, tasks, resources and ads. Exchange trades are free.
  static int tradeFee(int amount, String memo) =>
      memo.startsWith('order:') ||
          memo.startsWith('task:') ||
          memo.startsWith('resource:') ||
          memo.startsWith('ad:')
      ? amount ~/ 50
      : 0;

  static const topicLabel = 'mentos-coin-v3';

  /// Gossip topic every running node joins.
  static final topic = toHex(sha256(utf8.encode(topicLabel)));

  static int? parse(String input) => Credits.parse(input);
  static String format(int minor, {bool sign = false}) =>
      Credits.format(minor, sign: sign);
}

/// Kinds that move nothing by themselves and change an escrow's state.
const _signals = {'ack', 'cancel', 'claim', 'dispute'};

/// Kinds that refer to an escrow through `x.esc`.
const escrowOps = {'ack', 'cancel', 'claim', 'dispute', 'release', 'refund'};

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
    this.x = const {},
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

  /// Extra fields for escrow: `esc` (the lock it refers to), and on a lock
  /// `until`, optional `ack` (accept-by) and optional `arb` (arbiter).
  final Map<String, Object> x;

  bool get isMint => kind == 'mint';
  bool get isEscrowOp => escrowOps.contains(kind);
  String? get esc => x['esc'] as String?;
  int? get until => x['until'] as int?;
  int? get ackBy => x['ack'] as int?;
  String? get arbiter => x['arb'] as String?;

  /// The exact bytes the sender signs. Key order is part of the signature.
  /// Payments without extra fields keep the original v1 bytes.
  String get body {
    final m = <String, Object>{
      'v': 1,
      'kind': kind,
      'from': from,
      'to': to,
      'amt': amount,
      'seq': seq,
      'prev': prev,
      'memo': memo,
    };
    if (x.isNotEmpty) {
      final keys = x.keys.toList()..sort();
      m['x'] = {for (final k in keys) k: x[k]!};
    }
    m['ts'] = ts;
    return jsonEncode(m);
  }

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
    x: x,
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
    if (x.isNotEmpty) 'x': x,
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
    final rawX = j['x'];
    final x = <String, Object>{};
    if (rawX != null) {
      if (rawX is! Map || rawX.length > 6) return null;
      for (final e in rawX.entries) {
        final k = e.key, v = e.value;
        if (k is! String || k.length > 8) return null;
        if (v is String && v.length <= 80) {
          x[k] = v;
        } else if (v is int) {
          x[k] = v;
        } else {
          return null;
        }
      }
    }
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
      x: x,
    );
  }

  /// Shape only. Signatures are checked separately, and whether an escrow
  /// step is allowed depends on the escrow, which the ledger walk decides.
  String? problem({int? now}) {
    if (!_id(from) || !_id(to) || from == Coin.treasury) return 'bad identity';
    if (!_id(prev)) return 'bad previous';
    if (kind == 'mint') {
      if (from != to ||
          amount != Coin.grant ||
          seq != 0 ||
          prev != Coin.genesis ||
          memo.isNotEmpty ||
          ts != 0 ||
          x.isNotEmpty) {
        return 'grant must be 5.00 once';
      }
      return null;
    }
    if (memo.length > Coin.maxMemo) return 'memo too long';
    if (seq < 1 || seq > 100000) return 'bad sequence';
    final t = now ?? DateTime.now().millisecondsSinceEpoch;
    if (ts <= 0 || ts > t + const Duration(minutes: 10).inMilliseconds) {
      return 'bad time';
    }
    switch (kind) {
      case 'send':
        if (from == to) return 'cannot pay yourself';
        if (x.isNotEmpty) return 'unexpected fields';
      case 'reward':
        if (from != to || !RegExp(r'^reward:[0-9a-f]{64}$').hasMatch(memo)) {
          return 'bad reward';
        }
        if (x.isNotEmpty) return 'unexpected fields';
      case 'lock':
        if (from == to || to == Coin.treasury) return 'bad payee';
        final until = this.until, ack = ackBy, arb = arbiter;
        if (until == null || until <= ts) return 'hold needs a deadline';
        if (until > ts + Coin.maxHold.inMilliseconds) return 'hold too long';
        if (ack != null && (ack < ts || ack > until)) return 'bad accept-by';
        if (arb != null && (!_id(arb) || arb == from || arb == to || arb == Coin.treasury)) {
          return 'bad arbiter';
        }
        final allowed = {'until', 'ack', 'arb'};
        if (x.keys.any((k) => !allowed.contains(k))) return 'unexpected fields';
      default:
        if (!escrowOps.contains(kind)) return 'unknown payment';
        final e = esc;
        if (e == null || !_id(e) || x.length != 1) return 'missing escrow';
        if (_signals.contains(kind)) {
          if (amount != 0 || to != from) return 'signals move nothing';
          return null;
        }
    }
    if (amount <= 0 || amount > Coin.maxAmount) return 'bad amount';
    return null;
  }

  Future<bool> verify() async =>
      sig.isNotEmpty && await Identity.verify(from, utf8.encode(body), sig);
}

bool _id(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

/// A phone's statement that [hash] is the payment it first saw at [seq] in
/// [account]'s chain. Honest phones vote once per place.
class CoinVote {
  const CoinVote({
    required this.account,
    required this.seq,
    required this.hash,
    required this.voter,
    required this.sig,
  });
  final String account;
  final int seq;
  final String hash;
  final String voter;
  final String sig;

  String get body => 'mentos-coin-vote:v1|$account|$seq|$hash';
  String get slot => '$account:$seq';

  Map<String, Object> toJson() => {
    'a': account,
    's': seq,
    'h': hash,
    'by': voter,
    'sig': sig,
  };

  static CoinVote? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['a'], s = j['s'], h = j['h'], by = j['by'], sig = j['sig'];
    if (a is! String || s is! int || h is! String || by is! String || sig is! String) {
      return null;
    }
    if (!_id(a) || !_id(h) || !_id(by) || s < 1 || sig.length > 200) return null;
    return CoinVote(account: a, seq: s, hash: h, voter: by, sig: sig);
  }

  Future<bool> verify() => Identity.verify(voter, utf8.encode(body), sig);
}

/// How sure this phone can be that a payment will stand.
enum Settle { pending, accepted, witnessed, final_, conflicted }

class Confirmation {
  const Confirmation(this.state, {this.witnesses = 0, this.stake = 0});
  final Settle state;
  final int witnesses;
  final int stake;

  bool get counted => state != Settle.pending;
  bool get atLeastWitnessed =>
      state == Settle.witnessed || state == Settle.final_;

  String get label => switch (state) {
    Settle.pending => 'Pending',
    Settle.accepted => 'Accepted',
    Settle.witnessed => 'Witnessed',
    Settle.final_ => 'Final',
    Settle.conflicted => 'Conflicted',
  };
}

enum HoldState { open, accepted, disputed, settled, cancelled }

/// Coins held between a payer and a payee.
class Escrow {
  Escrow(this.lock)
    : remaining = lock.amount,
      payer = lock.from,
      payee = lock.to;

  final CoinTx lock;
  final String payer;
  final String payee;
  int remaining;
  int released = 0;
  int refunded = 0;
  int fees = 0;
  int? ackTs;
  int? disputeTs;
  bool cancelled = false;
  final steps = <CoinTx>[];

  String get id => lock.hash;
  int get amount => lock.amount;
  String get memo => lock.memo;
  int get until => lock.until!;
  int? get ackBy => lock.ackBy;
  String? get arbiter => lock.arbiter;
  bool get acked => ackTs != null;
  bool get disputed => disputeTs != null;

  HoldState get state {
    if (cancelled) return HoldState.cancelled;
    if (remaining == 0) return HoldState.settled;
    if (disputed) return HoldState.disputed;
    if (acked) return HoldState.accepted;
    return HoldState.open;
  }

  bool involves(String id) => id == payer || id == payee || id == arbiter;

  /// What [who] may sign next, given the time [now].
  Set<String> actionsFor(String who, int now) {
    final out = <String>{};
    if (remaining == 0) return out;
    if (who == payer) {
      out.add('release');
      if (!acked) out.add('cancel');
      if (!disputed && now < until) out.add('dispute');
    }
    if (who == payee) {
      out.add('refund');
      if (!acked) out.add('ack');
      if (acked && !disputed && now >= until) out.add('claim');
    }
    if (who == arbiter && disputed) out.addAll({'release', 'refund'});
    return out;
  }
}

/// What every phone computes from the same pool of signed payments.
class CoinView {
  CoinView({
    required this.chains,
    required this.balances,
    this.badges = const {},
    this.escrows = const {},
    this.flagged = const {},
    this.conflicts = const {},
    this.voided = const {},
    this.witnesses = const {},
    this.stake = const {},
  }) {
    for (final chain in chains.values) {
      for (final tx in chain) {
        _accepted[tx.hash] = tx;
      }
    }
  }
  final Map<String, List<CoinTx>> chains;
  final Map<String, int> balances;

  /// Identities whose accepted checkmark payment met the treasury price.
  final Set<String> badges;

  /// Every hold by its lock hash.
  final Map<String, Escrow> escrows;

  /// Accounts that signed two different payments at the same place.
  final Set<String> flagged;

  /// `account:seq` -> every payment seen there, when there is more than one.
  final Map<String, List<String>> conflicts;

  /// Escrow steps that were accepted into a chain but changed nothing,
  /// for example a claim that arrived after a dispute.
  final Set<String> voided;

  /// Payment hash -> phones (other than the sender) that voted for it.
  final Map<String, Set<String>> witnesses;

  /// Balance plus coins held in escrow for each account, used to weigh votes.
  final Map<String, int> stake;

  final _accepted = <String, CoinTx>{};

  int balanceOf(String id) => balances[id] ?? 0;
  bool contains(String hash) => _accepted.containsKey(hash);
  CoinTx? tx(String hash) => _accepted[hash];
  Iterable<CoinTx> get all => _accepted.values;

  int get escrowed =>
      escrows.values.fold<int>(0, (s, e) => s + e.remaining);

  /// Coins held in escrow where [id] pays and where [id] is paid.
  ({int outgoing, int incoming}) holds(String id) {
    var out = 0, inc = 0;
    for (final e in escrows.values) {
      if (e.payer == id) out += e.remaining;
      if (e.payee == id) inc += e.remaining;
    }
    return (outgoing: out, incoming: inc);
  }

  Confirmation confirmation(String hash) {
    final t = _accepted[hash];
    if (t == null) return const Confirmation(Settle.pending);
    if (t.isMint) return const Confirmation(Settle.final_);
    final w = witnesses[hash] ?? const <String>{};
    final weight = w.fold<int>(0, (s, v) => s + (stake[v] ?? 0));
    if (conflicts.containsKey('${t.from}:${t.seq}')) {
      return Confirmation(Settle.conflicted, witnesses: w.length, stake: weight);
    }
    final others = chains.keys.where((k) => k != t.from).length;
    final need = others < 3 ? (others < 1 ? 1 : others) : 3;
    if (w.length >= need) {
      return Confirmation(Settle.final_, witnesses: w.length, stake: weight);
    }
    if (w.isNotEmpty) {
      return Confirmation(Settle.witnessed, witnesses: w.length, stake: weight);
    }
    return const Confirmation(Settle.accepted);
  }
}

bool _badgeMemo(String memo) => memo == 'badge' || memo.startsWith('badge:');

int _order(CoinTx a, CoinTx b) {
  final t = a.ts.compareTo(b.ts);
  return t != 0 ? t : a.hash.compareTo(b.hash);
}

/// Walks the pool so two phones with the same payments (and votes) produce
/// the same chains. Payments are applied earliest first (time, then hash).
/// A payment counts only when it extends its sender's chain and the sender
/// can cover it. Where a chain forks, the branch with more voting stake is
/// followed; without votes the lower hash wins.
CoinView compileCoin(
  List<CoinTx> pool, {
  int? supply,
  List<CoinVote> votes = const [],
}) {
  final first = _walk(pool, supply: supply);
  if (first.forkSlots.isEmpty || votes.isEmpty) {
    return first.view(votes: votes, stake: null);
  }
  final stake = first.stake();
  return _walk(pool, supply: supply, votes: votes, stake: stake)
      .view(votes: votes, stake: stake);
}

class _Walk {
  _Walk(this.endowment);
  final int endowment;
  final chains = <String, List<CoinTx>>{};
  final balances = <String, int>{};
  final escrows = <String, Escrow>{};
  final badges = <String>{};
  final voided = <String>{};
  final forkSlots = <String, List<String>>{};
  final flagged = <String>{};

  Map<String, int> stake() {
    final out = <String, int>{...balances};
    for (final e in escrows.values) {
      out[e.payer] = (out[e.payer] ?? 0) + e.remaining;
    }
    out.remove(Coin.treasury);
    return out;
  }

  CoinView view({required List<CoinVote> votes, Map<String, int>? stake}) {
    final weights = stake ?? this.stake();
    final witnesses = <String, Set<String>>{};
    final known = chains.keys.toSet();
    for (final entry in _ballots(votes).entries) {
      for (final v in entry.value.entries) {
        if (!known.contains(v.key)) continue;
        (witnesses[v.value] ??= <String>{}).add(v.key);
      }
    }
    return CoinView(
      chains: chains,
      balances: balances,
      badges: badges,
      escrows: escrows,
      flagged: flagged,
      conflicts: forkSlots,
      voided: voided,
      witnesses: witnesses,
      stake: weights,
    );
  }
}

/// slot -> voter -> hash, keeping only voters who backed a single payment
/// there and who are not the account voting for itself.
Map<String, Map<String, String>> _ballots(List<CoinVote> votes) {
  final seen = <String, Map<String, Set<String>>>{};
  for (final v in votes) {
    if (v.voter == v.account) continue;
    ((seen[v.slot] ??= {})[v.voter] ??= <String>{}).add(v.hash);
  }
  return {
    for (final s in seen.entries)
      s.key: {
        for (final v in s.value.entries)
          if (v.value.length == 1) v.key: v.value.first,
      },
  };
}

_Walk _walk(
  List<CoinTx> pool, {
  int? supply,
  List<CoinVote> votes = const [],
  Map<String, int>? stake,
}) {
  final w = _Walk(supply ?? Coin.supply);
  final unique = <String, CoinTx>{};
  for (final tx in pool) {
    if (tx.problem(now: _farFuture) != null) continue;
    unique[tx.hash] = tx;
  }
  // account -> parent hash -> children
  final children = <String, Map<String, List<CoinTx>>>{};
  final mints = <String, CoinTx>{};
  for (final tx in unique.values) {
    if (tx.isMint) {
      mints[tx.from] = tx;
      continue;
    }
    ((children[tx.from] ??= {})[tx.prev] ??= []).add(tx);
  }
  for (final byParent in children.values) {
    for (final list in byParent.values) {
      if (list.length < 2) continue;
      final seqs = list.map((t) => t.seq).toSet();
      for (final s in seqs) {
        final same = list.where((t) => t.seq == s).toList();
        if (same.length < 2) continue;
        w.forkSlots['${same.first.from}:$s'] = [for (final t in same) t.hash]..sort();
        w.flagged.add(same.first.from);
      }
    }
  }
  final ballots = stake == null ? const <String, Map<String, String>>{} : _ballots(votes);
  int weight(CoinTx t) {
    final slot = ballots['${t.from}:${t.seq}'];
    if (slot == null) return 0;
    var sum = 0;
    for (final e in slot.entries) {
      if (e.value == t.hash) sum += (stake![e.key] ?? 0) + 1;
    }
    return sum;
  }

  CoinTx? next(String account, String tip, int seq) {
    final options = children[account]?[tip]
        ?.where((t) => t.seq == seq + 1)
        .toList();
    if (options == null || options.isEmpty) return null;
    if (options.length == 1) return options.first;
    options.sort((a, b) {
      final byWeight = weight(b).compareTo(weight(a));
      return byWeight != 0 ? byWeight : a.hash.compareTo(b.hash);
    });
    return options.first;
  }

  final balances = w.balances..[Coin.treasury] = w.endowment;
  final escrows = w.escrows;
  final tips = <String, CoinTx>{};
  final ready = SplayTreeSet<CoinTx>(_order);
  final onTreasury = <CoinTx>{};
  final onBalance = <String, CoinTx>{};
  final onEscrow = <String, List<CoinTx>>{};
  final onReceipt = <String, List<CoinTx>>{};
  final accepted = <String, CoinTx>{};
  final rewarded = <String>{};

  int bal(String id) => balances[id] ?? 0;
  void credit(String id, int v) => balances[id] = bal(id) + v;

  void consider(CoinTx tx) {
    switch (tx.kind) {
      case 'mint':
        bal(Coin.treasury) >= tx.amount ? ready.add(tx) : onTreasury.add(tx);
      case 'reward':
        final receipt = tx.memo.substring(7);
        if (!accepted.containsKey(receipt)) {
          (onReceipt[receipt] ??= []).add(tx);
        } else {
          ready.add(tx);
        }
      case 'send':
      case 'lock':
        final need = tx.amount +
            (tx.kind == 'send' ? Coin.serviceFee(tx.amount, tx.memo) : 0);
        bal(tx.from) >= need ? ready.add(tx) : onBalance[tx.from] = tx;
      default:
        escrows.containsKey(tx.esc)
            ? ready.add(tx)
            : (onEscrow[tx.esc!] ??= []).add(tx);
    }
  }

  void advance(String account) {
    final tip = tips[account];
    if (tip == null) return;
    final n = next(account, tip.hash, tip.seq);
    if (n != null) consider(n);
  }

  void wake(String account) {
    final waiting = onBalance.remove(account);
    if (waiting != null) consider(waiting);
  }

  void refill() {
    if (onTreasury.isEmpty) return;
    final list = onTreasury.toList();
    onTreasury.clear();
    for (final tx in list) {
      consider(tx);
    }
  }

  for (final mint in mints.values) {
    consider(mint);
  }

  while (ready.isNotEmpty) {
    final tx = ready.first;
    ready.remove(tx);
    final treasuryBefore = bal(Coin.treasury);
    switch (tx.kind) {
      case 'mint':
        if (treasuryBefore < tx.amount) {
          onTreasury.add(tx);
          continue;
        }
        credit(Coin.treasury, -tx.amount);
        credit(tx.from, tx.amount);
        tips[tx.from] = tx;
        w.chains[tx.from] = [tx];
        accepted[tx.hash] = tx;
        advance(tx.from);
        continue;
      case 'reward':
        final receipt = accepted[tx.memo.substring(7)];
        final eligible =
            receipt != null &&
            receipt.kind == 'send' &&
            receipt.to == tx.from &&
            receipt.from != tx.from &&
            (receipt.memo.startsWith('task:') ||
                receipt.memo.startsWith('resource:')) &&
            tx.amount == Coin.rewardAmount(receipt.amount) &&
            !rewarded.contains(receipt.hash);
        if (!eligible) continue; // The chain stops here for good.
        if (treasuryBefore < tx.amount) {
          onTreasury.add(tx);
          continue;
        }
        rewarded.add(receipt.hash);
        credit(Coin.treasury, -tx.amount);
        credit(tx.from, tx.amount);
      case 'send':
        final fee = Coin.serviceFee(tx.amount, tx.memo);
        credit(tx.from, -tx.amount - fee);
        credit(Coin.treasury, fee);
        credit(tx.to, tx.amount);
        if (tx.to == Coin.treasury &&
            _badgeMemo(tx.memo) &&
            tx.amount >= Coin.badgePrice(treasuryBefore)) {
          w.badges.add(tx.from);
        }
        wake(tx.to);
      case 'lock':
        credit(tx.from, -tx.amount);
        final e = Escrow(tx);
        escrows[tx.hash] = e;
        for (final op in onEscrow.remove(tx.hash) ?? const <CoinTx>[]) {
          ready.add(op);
        }
      default:
        final e = escrows[tx.esc]!;
        if (_applyStep(e, tx, credit)) {
          e.steps.add(tx);
          wake(e.payer);
          wake(e.payee);
        } else {
          w.voided.add(tx.hash);
        }
    }
    tips[tx.from] = tx;
    w.chains[tx.from]!.add(tx);
    accepted[tx.hash] = tx;
    for (final r in onReceipt.remove(tx.hash) ?? const <CoinTx>[]) {
      ready.add(r);
    }
    advance(tx.from);
    if (bal(Coin.treasury) > treasuryBefore) refill();
  }
  return w;
}

/// A time after any real timestamp, so the walk itself never rejects a
/// payment for being early. Ingestion checks the real clock.
const _farFuture = 1 << 52;

bool _applyStep(Escrow e, CoinTx tx, void Function(String, int) credit) {
  if (e.remaining == 0 || tx.ts < e.lock.ts) return false;
  final who = tx.from;
  switch (tx.kind) {
    case 'ack':
      if (who != e.payee || e.acked || e.cancelled) return false;
      e.ackTs = tx.ts;
      return true;
    case 'cancel':
      if (who != e.payer || e.acked) return false;
      credit(e.payer, e.remaining);
      e.refunded += e.remaining;
      e.remaining = 0;
      e.cancelled = true;
      return true;
    case 'dispute':
      if (who != e.payer || e.disputed || tx.ts >= e.until) return false;
      e.disputeTs = tx.ts;
      return true;
    case 'claim':
      if (who != e.payee || !e.acked || e.disputed || tx.ts < e.until) {
        return false;
      }
      final fee = Coin.tradeFee(e.remaining, e.memo);
      credit(e.payee, e.remaining - fee);
      credit(Coin.treasury, fee);
      e.fees += fee;
      e.released += e.remaining;
      e.remaining = 0;
      return true;
    case 'release':
      final byArbiter = who == e.arbiter && e.disputed;
      if ((who != e.payer && !byArbiter) ||
          tx.to != e.payee ||
          tx.amount > e.remaining) {
        return false;
      }
      final fee = Coin.tradeFee(tx.amount, e.memo);
      credit(e.payee, tx.amount - fee);
      credit(Coin.treasury, fee);
      e.fees += fee;
      e.released += tx.amount;
      e.remaining -= tx.amount;
      return true;
    case 'refund':
      final byArbiter = who == e.arbiter && e.disputed;
      if ((who != e.payee && !byArbiter) ||
          tx.to != e.payer ||
          tx.amount > e.remaining) {
        return false;
      }
      credit(e.payer, tx.amount);
      e.refunded += tx.amount;
      e.remaining -= tx.amount;
      return true;
  }
  return false;
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
  Timer? _voteFlush;
  final _changes = StreamController<void>.broadcast();
  final _noted = <String>{};
  final _orphans = <String, CoinTx>{};
  final _outVotes = <CoinVote>[];
  Future<void> _queue = Future.value();
  bool _closed = false;
  DateTime _lastAnnounce = DateTime.fromMillisecondsSinceEpoch(0);
  bool _seeded = false;
  CoinView? _cached;

  /// Votes are only cast for payments this recent. Old history needs no
  /// witnesses, and a phone catching up should not flood the topic.
  static const _voteWindow = Duration(days: 2);

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
    _voteFlush?.cancel();
    await _sub?.cancel();
    await _queue;
    await _changes.close();
  }

  // ---------------------------------------------------------------------------
  // reading

  List<CoinTx> pool() => [
    for (final raw in engine.db.coinTxRows()) ?CoinTx.fromJson(jsonDecode(raw)),
  ];

  List<CoinVote> votes() => [
    for (final raw in engine.db.coinVoteRows()) ?CoinVote.fromJson(jsonDecode(raw)),
  ];

  /// Computed once per change and shared by every reader.
  CoinView view() => _cached ??= compileCoin(pool(), votes: votes());

  void _dirty() => _cached = null;

  int balance([String? id]) => view().balanceOf(id ?? _me);

  CoinTx? tx(String hash) => view().tx(hash);

  Confirmation confirmation(String hash) => view().confirmation(hash);

  Escrow? escrow(String lockHash) => view().escrows[lockHash];

  /// Holds that involve [id], newest first.
  List<Escrow> escrows([String? id]) {
    final who = id ?? _me;
    return view().escrows.values.where((e) => e.involves(who)).toList()
      ..sort((a, b) => b.lock.ts.compareTo(a.lock.ts));
  }

  bool flagged(String id) => view().flagged.contains(id);

  /// Payments that touch [id], newest first. The welcome grant has time 0,
  /// so it sits at the bottom until something else happens.
  List<CoinTx> history([String? id]) {
    final who = id ?? _me;
    final v = view();
    final all = <CoinTx>[];
    for (final tx in v.all) {
      final hold = tx.isEscrowOp ? v.escrows[tx.esc] : null;
      if (tx.from == who ||
          tx.to == who ||
          (hold != null && hold.involves(who)) ||
          (who == Coin.treasury &&
              (tx.isMint ||
                  tx.kind == 'reward' ||
                  Coin.serviceFee(tx.amount, tx.memo) > 0))) {
        all.add(tx);
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
    final txs = v.all.toList();
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

  /// This payment and the ones before it in its chain, oldest first, so a
  /// recipient who has not synced yet can verify it on the spot.
  List<Map<String, Object>> bundle(String hash, {int depth = 24}) {
    final v = view();
    var t = v.tx(hash);
    if (t == null) return const [];
    final out = <CoinTx>[];
    while (t != null && out.length < depth) {
      out.add(t);
      if (t.isMint) break;
      t = v.tx(t.prev);
    }
    return [for (final x in out.reversed) x.toJson()];
  }

  /// Stores a bundle another phone attached to a message.
  Future<void> absorb(Object? list) =>
      onMessage('bundle', {'op': 'txs', 'txs': list});

  Future<CoinTx> claimReward(String receipt) => _serial(() async {
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
    final tx = await _sign(kind: 'reward', to: _me, amount: amount, memo: 'reward:$receipt');
    await _ingest(tx, relay: true);
    if (!view().contains(tx.hash)) {
      throw StateError('Reward is not accepted by this ledger view');
    }
    await announce(force: true);
    return tx;
  });

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

  Future<T> _serial<T>(Future<T> Function() f) {
    final done = Completer<T>();
    unawaited(
      _guard(() async {
        try {
          done.complete(await f());
        } catch (e, st) {
          if (!done.isCompleted) done.completeError(e, st);
        }
      }),
    );
    return done.future;
  }

  /// Sends [amount] (hundredths of a Mentos) to [to].
  Future<CoinTx> pay(String to, int amount, {String memo = ''}) =>
      _serial(() => _pay(to, amount, memo));

  /// Serialize receipt lookup and payment together to make retries safe.
  Future<CoinTx> payOnce(String to, int amount, {required String memo}) =>
      _serial(() async {
        final existing = history()
            .where((t) => t.from == _me && t.kind == 'send' && t.memo == memo)
            .firstOrNull;
        if (existing != null &&
            (existing.to != to || existing.amount != amount)) {
          throw StateError('A different payment already uses this reference');
        }
        return existing ?? await _pay(to, amount, memo);
      });

  Future<CoinTx> _sign({
    required String kind,
    required String to,
    required int amount,
    String memo = '',
    Map<String, Object> x = const {},
    int minTs = 0,
  }) async {
    final chain = view().chains[_me];
    final tip = chain == null || chain.isEmpty ? null : chain.last;
    if (tip == null) throw StateError('Wallet is not ready');
    // A clock behind the last entry (or behind the hold a step refers to)
    // would make this one sort before it and void it.
    var ts = nowMs();
    if (ts < tip.ts) ts = tip.ts;
    if (ts < minTs) ts = minTs;
    final draft = CoinTx(
      kind: kind,
      from: _me,
      to: to,
      amount: amount,
      seq: tip.seq + 1,
      prev: tip.hash,
      memo: memo.length > Coin.maxMemo ? memo.substring(0, Coin.maxMemo) : memo,
      ts: ts,
      sig: '',
      x: x,
    );
    return draft.withSig(await engine.me.sign(utf8.encode(draft.body)));
  }

  Future<CoinTx> _pay(String to, int amount, String memo) async {
    if (to == _me) throw ArgumentError('Cannot pay yourself');
    if (!_id(to)) throw ArgumentError('That address is not a Mentos identity');
    if (amount <= 0 || amount > Coin.maxAmount) {
      throw ArgumentError('Amount out of range');
    }
    final note = memo.trim();
    if (balance(_me) < amount + Coin.serviceFee(amount, note)) {
      throw StateError('Not enough Mentos');
    }
    final tx = await _sign(kind: 'send', to: to, amount: amount, memo: note);
    return _commit(tx, notify: to);
  }

  Future<CoinTx> _commit(CoinTx tx, {String? notify}) async {
    final kept = await _ingest(tx, relay: true);
    if (kept == _Keep.reject) {
      final why = tx.problem();
      throw StateError(why ?? 'The ledger refused that payment');
    }
    if (!view().contains(tx.hash)) {
      throw StateError('Another payment already spent those coins');
    }
    for (final peer in {?notify}) {
      if (peer == _me || peer == Coin.treasury) continue;
      try {
        await engine.sendApp(peer, Coin.app, {
          'op': 'txs',
          'txs': bundle(tx.hash, depth: 4),
        }, queueId: 'coin:${tx.hash}:$peer');
      } catch (_) {}
    }
    await announce(force: true);
    return tx;
  }

  /// Holds [amount] for [to] until [until]. With [ackBy] the payer may take
  /// the coins back if [to] has not accepted by then (and any time before
  /// they accept). An [arbiter] can settle a dispute either way.
  Future<CoinTx> lock(
    String to,
    int amount, {
    required String memo,
    required DateTime until,
    DateTime? ackBy,
    String? arbiter,
  }) => _serial(() async {
    if (to == _me || to == Coin.treasury || !_id(to)) {
      throw ArgumentError('That address cannot receive a hold');
    }
    if (amount <= 0 || amount > Coin.maxAmount) {
      throw ArgumentError('Amount out of range');
    }
    final existing = _myLock(memo);
    if (existing != null) {
      if (existing.to != to || existing.amount != amount) {
        throw StateError('A different hold already uses this reference');
      }
      return existing;
    }
    if (balance(_me) < amount) throw StateError('Not enough Mentos');
    final tx = await _sign(
      kind: 'lock',
      to: to,
      amount: amount,
      memo: memo,
      x: {
        'until': until.millisecondsSinceEpoch,
        if (ackBy != null) 'ack': ackBy.millisecondsSinceEpoch,
        if (arbiter != null && arbiter.isNotEmpty) 'arb': arbiter,
      },
    );
    return _commit(tx, notify: to);
  });

  CoinTx? _myLock(String memo) {
    if (memo.isEmpty) return null;
    for (final e in view().escrows.values) {
      if (e.payer == _me && e.memo == memo) return e.lock;
    }
    return null;
  }

  /// The hold this phone opened with [memo], if any.
  Escrow? holdFor(String memo) {
    for (final e in view().escrows.values) {
      if (e.memo == memo) return e;
    }
    return null;
  }

  /// Signs one step on hold [lockHash]: ack, cancel, dispute, claim,
  /// release or refund. Release and refund take an [amount]; by default
  /// everything still held.
  Future<CoinTx> step(String lockHash, String kind, {int? amount}) =>
      _serial(() async {
        final e = escrow(lockHash);
        if (e == null) throw StateError('That hold is not on this ledger yet');
        final allowed = e.actionsFor(_me, nowMs());
        if (!allowed.contains(kind)) {
          throw StateError(_whyNot(e, kind));
        }
        final moves = kind == 'release' || kind == 'refund';
        final value = moves ? (amount ?? e.remaining) : 0;
        if (moves && (value <= 0 || value > e.remaining)) {
          throw ArgumentError('Amount out of range');
        }
        final to = switch (kind) {
          'release' => e.payee,
          'refund' => e.payer,
          _ => _me,
        };
        final tx = await _sign(
          kind: kind,
          to: to,
          amount: value,
          memo: e.memo,
          x: {'esc': lockHash},
          minTs: e.lock.ts + 1,
        );
        final saved = await _commit(tx);
        if (view().voided.contains(saved.hash)) {
          throw StateError('The hold changed before that step arrived');
        }
        for (final peer in {e.payer, e.payee, ?e.arbiter}) {
          if (peer == _me) continue;
          try {
            await engine.sendApp(peer, Coin.app, {
              'op': 'txs',
              'txs': bundle(saved.hash, depth: 4),
            }, queueId: 'coin:${saved.hash}:$peer');
          } catch (_) {}
        }
        return saved;
      });

  String _whyNot(Escrow e, String kind) {
    if (e.remaining == 0) return 'This hold is already settled';
    return switch (kind) {
      'cancel' => 'They already accepted, so the hold cannot be cancelled',
      'claim' when e.disputed => 'The payer disputed this hold',
      'claim' when !e.acked => 'Accept the hold before claiming it',
      'claim' => 'The hold can be claimed after ${DateTime.fromMillisecondsSinceEpoch(e.until)}',
      'dispute' when e.disputed => 'Already disputed',
      'dispute' => 'The dispute window has closed',
      'ack' => 'Only the payee can accept, once',
      _ => 'You cannot do that on this hold',
    };
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
              for (final raw in list.take(200)) {
                final tx = CoinTx.fromJson(raw);
                if (tx != null) await _consider(tx, relay: true, settle: false);
              }
              await _settle();
            }
          case 'votes':
            final list = m['votes'];
            if (list is List) {
              var changed = false;
              for (final raw in list.take(400)) {
                final v = CoinVote.fromJson(raw);
                if (v != null && await _storeVote(v)) changed = true;
              }
              if (changed) {
                _dirty();
                _publish();
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
    final remote = <String, ({int n, String sum, int votes})>{};
    for (final row in raw.take(20000)) {
      if (row is! Map) continue;
      final id = row['id'];
      final n = row['n'];
      final sum = row['sum'];
      final vn = row['vn'];
      final count = n is int ? n : (n is num ? n.toInt() : null);
      if (id is String && count != null && sum is String) {
        remote[id] = (n: count, sum: sum, votes: vn is int ? vn : 0);
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
      final moreVotes = mine != null && theirs != null && mine.votes > theirs.votes;
      if (!differ && !moreVotes) continue;
      if (mine != null) await _sendAccount(from, id);
      if (theirs != null && (differ || theirs.votes > mine.votes)) {
        try {
          await engine.sendApp(from, Coin.app, {'op': 'want', 'id': id});
        } catch (_) {}
      }
    }
  }

  Future<void> _sendAccount(String to, String id) async {
    if (!_id(id)) return;
    final txs = [
      for (final raw in engine.db.coinTxRowsFor(id)) ?CoinTx.fromJson(jsonDecode(raw)),
    ];
    for (var i = 0; i < txs.length; i += 30) {
      final end = i + 30 > txs.length ? txs.length : i + 30;
      final body = {
        'op': 'txs',
        'txs': [for (final tx in txs.sublist(i, end)) tx.toJson()],
      };
      try {
        await engine.sendApp(to, Coin.app, body);
      } catch (_) {}
    }
    final votes = engine.db.coinVoteRowsFor(id);
    for (var i = 0; i < votes.length; i += 80) {
      final end = i + 80 > votes.length ? votes.length : i + 80;
      try {
        await engine.sendApp(to, Coin.app, {
          'op': 'votes',
          'votes': [for (final raw in votes.sublist(i, end)) jsonDecode(raw)],
        });
      } catch (_) {}
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
      {'id': e.key, 'n': e.value.n, 'sum': e.value.sum, 'vn': e.value.votes},
  ];

  Map<String, ({int n, String sum, int votes})> _summaryMap() {
    final votes = engine.db.coinVoteCounts();
    return {
      for (final r in engine.db.coinAccountHashes().entries)
        r.key: (
          n: r.value.length,
          sum: toHex(sha256(utf8.encode((r.value..sort()).join()))),
          votes: votes[r.key] ?? 0,
        ),
    };
  }

  Future<_Keep> _ingest(CoinTx tx, {required bool relay}) async {
    final first = await _consider(tx, relay: relay, settle: false);
    await _settle();
    return engine.db.coinTxByHash(tx.hash) == null ? first : _Keep.saved;
  }

  Future<void> _settle() async {
    await _drain();
    _publish();
  }

  Future<void> _drain() async {
    var again = true;
    while (again) {
      again = false;
      for (final tx in _orphans.values.toList()) {
        final kept = await _consider(tx, relay: true, settle: false, orphan: true);
        if (kept == _Keep.wait) continue;
        _orphans.remove(tx.hash);
        if (kept == _Keep.saved) again = true;
      }
    }
  }

  Future<_Keep> _consider(
    CoinTx tx, {
    required bool relay,
    required bool settle,
    bool orphan = false,
  }) async {
    final now = nowMs();
    if (tx.problem(now: now) != null) return _Keep.reject;
    if (engine.db.coinTxByHash(tx.hash) != null) return _Keep.duplicate;
    if (!await tx.verify()) return _Keep.reject;
    final kept = _tryStore(tx);
    if (kept == _Keep.wait && !orphan) {
      if (_orphans.length < 500) _orphans[tx.hash] = tx;
    }
    if (kept == _Keep.saved) {
      _dirty();
      await _vote(tx, now);
      if (relay) await _gossip({'op': 'tx', 'tx': tx.toJson()});
    }
    if (settle) await _settle();
    return kept;
  }

  _Keep _tryStore(CoinTx tx) {
    if (engine.db.coinTxByHash(tx.hash) != null) return _Keep.duplicate;
    if (engine.db.coinCount(tx.from) >= Coin.maxChain) return _Keep.reject;
    if (tx.isMint) {
      if (engine.db.coinMint(tx.from) != null) return _Keep.reject;
      _put(tx);
      return _Keep.saved;
    }
    final parentRaw = engine.db.coinTxByHash(tx.prev);
    if (parentRaw == null) return _Keep.wait;
    final parent = CoinTx.fromJson(jsonDecode(parentRaw));
    if (parent == null || parent.from != tx.from || parent.seq + 1 != tx.seq) {
      return _Keep.reject;
    }
    _put(tx);
    return _Keep.saved;
  }

  void _put(CoinTx tx) => engine.db.putCoinTx(
    tx.hash,
    tx.from,
    tx.seq,
    tx.to,
    tx.amount,
    jsonEncode(tx.toJson()),
    tx.ts,
  );

  /// First seen wins: this phone backs the first payment it stored at each
  /// place in a chain, and never a second one.
  Future<void> _vote(CoinTx tx, int now) async {
    if (tx.isMint || tx.from == _me) return;
    if (now - tx.ts > _voteWindow.inMilliseconds) return;
    if (engine.db.coinVotedSlot(tx.from, tx.seq, _me)) return;
    final draft = CoinVote(account: tx.from, seq: tx.seq, hash: tx.hash, voter: _me, sig: '');
    final vote = CoinVote(
      account: draft.account,
      seq: draft.seq,
      hash: draft.hash,
      voter: _me,
      sig: await engine.me.sign(utf8.encode(draft.body)),
    );
    engine.db.putCoinVote(vote.account, vote.seq, vote.voter, vote.hash, jsonEncode(vote.toJson()));
    _outVotes.add(vote);
    _voteFlush ??= Timer(const Duration(milliseconds: 400), () {
      _voteFlush = null;
      final batch = List.of(_outVotes);
      _outVotes.clear();
      for (var i = 0; i < batch.length; i += 80) {
        final end = i + 80 > batch.length ? batch.length : i + 80;
        unawaited(_gossip({
          'op': 'votes',
          'votes': [for (final v in batch.sublist(i, end)) v.toJson()],
        }));
      }
    });
  }

  Future<bool> _storeVote(CoinVote v) async {
    if (engine.db.coinVoteExists(v.account, v.seq, v.voter, v.hash)) return false;
    if (engine.db.coinVotesInSlot(v.account, v.seq) >= 64) return false;
    if (!await v.verify()) return false;
    engine.db.putCoinVote(v.account, v.seq, v.voter, v.hash, jsonEncode(v.toJson()));
    return true;
  }

  void _publish() {
    if (_closed || _changes.isClosed) return;
    try {
      _changes.add(null);
      _seedNotes();
      final me = _me;
      for (final tx in history(me)) {
        if (tx.isMint || tx.from == me) continue;
        if (!_noted.add(tx.hash)) continue;
        final text = switch (tx.kind) {
          'send' when tx.to == me => 'sent ${Coin.format(tx.amount)} Mentos',
          'lock' when tx.to == me => 'is holding ${Coin.format(tx.amount)} Mentos for you',
          'release' when tx.to == me => 'released ${Coin.format(tx.amount)} Mentos to you',
          'refund' when tx.to == me => 'refunded ${Coin.format(tx.amount)} Mentos',
          'ack' => 'accepted your hold',
          'dispute' => 'disputed a hold',
          'cancel' => 'cancelled a hold',
          'claim' => 'claimed a hold',
          _ => null,
        };
        if (text == null) continue;
        engine.noteActivity(
          Activity(
            id: 'coin:${tx.hash}',
            kind: 'coin',
            actor: tx.from,
            ref: tx.hash,
            ts: tx.ts,
            text: text,
          ),
          title: engine.nameOf(tx.from),
          body: text[0].toUpperCase() + text.substring(1),
          route: '/wallet',
          category: 'other',
        );
      }
    } catch (_) {}
  }
}
