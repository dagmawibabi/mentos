import 'dart:convert';

import '../../core/crypto/crypto.dart';

/// Mutual credit between two people. There is no coin and no global
/// ledger: a payment is an IOU both of them sign, appended to a chain only
/// the two of them keep. Each entry names the previous one by hash, so
/// neither side can drop, reorder or rewrite history without the other's
/// signature. See docs/PAYMENTS.md for the threat model.
abstract final class Credits {
  /// Amounts are integers in hundredths of a credit.
  static const scale = 100;
  static const maxAmount = 100000000; // one million credits
  static const maxMemo = 140;
  static const genesis = '0000000000000000000000000000000000000000000000000000000000000000';

  static String pairId(String a, String b) {
    final s = [a, b]..sort();
    return toHex(sha256(utf8.encode('mentos-credit:${s[0]}:${s[1]}'))).substring(0, 32);
  }

  /// "12.5" -> 1250. Null for anything that is not a positive amount.
  static int? parse(String input) {
    final t = input.trim().replaceAll(',', '.');
    final m = RegExp(r'^(\d{1,7})(?:\.(\d{1,2}))?$').firstMatch(t);
    if (m == null) return null;
    final whole = int.parse(m.group(1)!);
    final frac = m.group(2) == null ? 0 : int.parse(m.group(2)!.padRight(2, '0'));
    final v = whole * scale + frac;
    return v <= 0 || v > maxAmount ? null : v;
  }

  static String format(int minor, {bool sign = false}) {
    final neg = minor < 0;
    final a = minor.abs();
    final s = '${a ~/ scale}.${(a % scale).toString().padLeft(2, '0')}';
    return neg ? '−$s' : (sign && minor > 0 ? '+$s' : s);
  }
}

/// One payment. [from] pays [to] [amount]; after it, [from] owes [to] that
/// much more (or is owed that much less).
class LedgerEntry {
  const LedgerEntry({
    required this.pair,
    required this.seq,
    required this.prev,
    required this.from,
    required this.to,
    required this.amount,
    required this.memo,
    required this.ts,
    this.sigFrom = '',
    this.sigTo = '',
  });

  final String pair;
  final int seq;
  final String prev;
  final String from;
  final String to;
  final int amount;
  final String memo;
  final int ts;
  final String sigFrom;
  final String sigTo;

  /// The exact bytes both people sign.
  String get body => jsonEncode({
        'v': 1,
        'pair': pair,
        'seq': seq,
        'prev': prev,
        'from': from,
        'to': to,
        'amt': amount,
        'memo': memo,
        'ts': ts,
      });

  String get hash => toHex(sha256(utf8.encode(body)));

  bool get complete => sigFrom.isNotEmpty && sigTo.isNotEmpty;

  LedgerEntry copyWith({String? sigFrom, String? sigTo, int? seq, String? prev}) => LedgerEntry(
        pair: pair,
        seq: seq ?? this.seq,
        prev: prev ?? this.prev,
        from: from,
        to: to,
        amount: amount,
        memo: memo,
        ts: ts,
        sigFrom: sigFrom ?? this.sigFrom,
        sigTo: sigTo ?? this.sigTo,
      );

  Map<String, Object> toJson() => {
        'pair': pair,
        'seq': seq,
        'prev': prev,
        'from': from,
        'to': to,
        'amt': amount,
        'memo': memo,
        'ts': ts,
        'sf': sigFrom,
        'st': sigTo,
      };

  static LedgerEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final pair = j['pair'], seq = j['seq'], prev = j['prev'], from = j['from'], to = j['to'];
    final amt = j['amt'], memo = j['memo'], ts = j['ts'];
    if (pair is! String || seq is! int || prev is! String || from is! String || to is! String) return null;
    if (amt is! int || memo is! String || ts is! int) return null;
    return LedgerEntry(
      pair: pair,
      seq: seq,
      prev: prev,
      from: from,
      to: to,
      amount: amt,
      memo: memo,
      ts: ts,
      sigFrom: j['sf'] is String ? j['sf'] as String : '',
      sigTo: j['st'] is String ? j['st'] as String : '',
    );
  }

  /// Checks shape and how it extends [last] (null for the first entry).
  /// Signatures are checked separately because they are async.
  String? problem({required String me, required String peer, LedgerEntry? last, int? now}) {
    if (pair != Credits.pairId(me, peer)) return 'wrong pair';
    if (!({from, to}.containsAll([me, peer]) && from != to)) return 'not between these two people';
    if (amount <= 0 || amount > Credits.maxAmount) return 'bad amount';
    if (memo.length > Credits.maxMemo) return 'memo too long';
    final expectSeq = (last?.seq ?? 0) + 1;
    if (seq != expectSeq) return 'out of order';
    if (prev != (last?.hash ?? Credits.genesis)) return 'does not follow the last entry';
    final t = now ?? DateTime.now().millisecondsSinceEpoch;
    if (ts > t + const Duration(minutes: 10).inMilliseconds) return 'from the future';
    if (last != null && ts < last.ts - const Duration(minutes: 10).inMilliseconds) return 'older than the last entry';
    return null;
  }

  Future<bool> verifyFrom() async => sigFrom.isNotEmpty && await Identity.verify(from, utf8.encode(body), sigFrom);
  Future<bool> verifyTo() async => sigTo.isNotEmpty && await Identity.verify(to, utf8.encode(body), sigTo);
}

/// What [me] is owed by [peer] after [entries]; negative means [me] owes.
int balanceOf(String me, Iterable<LedgerEntry> entries) {
  var b = 0;
  for (final e in entries) {
    if (!e.complete) continue;
    if (e.to == me) b += e.amount;
    if (e.from == me) b -= e.amount;
  }
  return b;
}
