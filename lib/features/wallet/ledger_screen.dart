import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/pay/coin.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import '../market/market_kit.dart';
import 'coin_wallet_screen.dart';

/// The whole ledger as this phone sees it: the treasury, network health,
/// rewards to claim, and every signed record.
class LedgerScreen extends ConsumerStatefulWidget {
  const LedgerScreen({super.key});
  @override
  ConsumerState<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends ConsumerState<LedgerScreen> {
  String _query = '';
  String _filter = 'all';
  int _shown = 60;
  bool _busy = false;

  static const _filters = {
    'all': 'All',
    'payments': 'Payments',
    'escrow': 'Escrow',
    'treasury': 'Treasury',
    'excluded': 'Not accepted',
  };

  @override
  Widget build(BuildContext context) {
    ref.watch(coinTickProvider);
    final coin = ref.watch(coinProvider);
    final e = ref.watch(maybeEngineProvider);
    final p = context.pal;
    if (coin == null || e == null) return const Scaffold(body: Loading());
    final view = coin.view();
    final pool = coin.pool()..sort((a, b) => b.ts.compareTo(a.ts));
    final treasury = coin.balance(Coin.treasury);
    final q = _query.toLowerCase();
    final rows = pool.where((t) {
      final ok = switch (_filter) {
        'payments' => t.kind == 'send',
        'escrow' => t.kind == 'lock' || t.isEscrowOp,
        'treasury' => t.to == Coin.treasury || t.isMint || t.kind == 'reward' || Coin.serviceFee(t.amount, t.memo) > 0,
        'excluded' => !view.contains(t.hash),
        _ => true,
      };
      return ok && (q.isEmpty || '${t.hash} ${t.from} ${t.to} ${t.memo} ${t.kind}'.toLowerCase().contains(q));
    }).toList();
    final rewards = coin.rewardReceipts();
    final votes = coin.votes().length;

    return Scaffold(
      appBar: AppBar(title: const Text('Mentos ledger')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            child: _TreasuryCard(treasury: treasury, price: Coin.badgePrice(treasury)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: Space.sm,
              crossAxisSpacing: Space.sm,
              childAspectRatio: 1.15,
              children: [
                _Tile(Icons.people_alt_outlined, '${view.chains.length}', 'Accounts'),
                _Tile(Icons.receipt_long_outlined, '${view.all.length}', 'Records'),
                _Tile(Icons.lock_outline_rounded, Coin.format(view.escrowed), 'In escrow'),
                _Tile(Icons.how_to_vote_outlined, '$votes', 'Witness votes'),
                _Tile(Icons.call_split_rounded, '${view.conflicts.length}', 'Conflicts', warn: view.conflicts.isNotEmpty),
                _Tile(Icons.report_gmailerrorred_rounded, '${view.flagged.length}', 'Flagged', warn: view.flagged.isNotEmpty),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 15, color: p.faint),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    'The ledger as this phone knows it. Every record is signed; phones that have not met can disagree '
                    'until they sync, and a double spend only stands with more witness stake.',
                    style: Txt.small(p.muted),
                  ),
                ),
              ],
            ),
          ),
          SectionLabel('Contribution rewards', trailing: rewards.isEmpty ? null : Text('${rewards.length}', style: Txt.mono(p.muted, size: 11))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: MCard(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.sm, Space.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.workspace_premium_outlined, color: MarketColors(p).amber),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          rewards.isEmpty ? 'Nothing to claim' : '${rewards.length} ready to claim',
                          style: Txt.bodyStrong(p.ink),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(right: Space.sm),
                    child: Text(
                      'Paid task and resource receipts earn 5% back from the treasury, up to 0.10 each, once per receipt.',
                      style: Txt.small(p.muted),
                    ),
                  ),
                  for (final receipt in rewards)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('${Coin.format(Coin.rewardAmount(receipt.amount))} MNT', style: Txt.bodyStrong(p.ink)),
                      subtitle: Text(receipt.memo, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: FilledButton(
                        onPressed: _busy ? null : () => _claim(receipt.hash),
                        child: const Text('Claim'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SectionLabel('Records', trailing: Text('${rows.length}', style: Txt.mono(p.muted, size: 11))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: TextField(
              onChanged: (v) => setState(() {
                _query = v.trim();
                _shown = 60;
              }),
              decoration: InputDecoration(
                hintText: 'Address, hash or note',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: p.raised,
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 8),
              children: [
                for (final f in _filters.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.value),
                      selected: _filter == f.key,
                      showCheckmark: false,
                      onSelected: (_) => setState(() {
                        _filter = f.key;
                        _shown = 60;
                      }),
                    ),
                  ),
              ],
            ),
          ),
          if (rows.isEmpty)
            const EmptyState(icon: Icons.search_off_rounded, title: 'No records match', compact: true),
          for (final tx in rows.take(_shown)) _Record(tx: tx, view: view, me: e.me.id),
          if (rows.length > _shown)
            Padding(
              padding: const EdgeInsets.all(Space.gutter),
              child: OutlinedButton(
                onPressed: () => setState(() => _shown += 100),
                child: Text('Show more (${rows.length - _shown} left)'),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _claim(String hash) async {
    final coin = ref.read(coinProvider);
    if (coin == null) return;
    setState(() => _busy = true);
    await attempt(context, () => coin.claimReward(hash), done: 'Reward recorded');
    if (mounted) setState(() => _busy = false);
  }
}

/// The network's own account: what is left of the supply, and the
/// checkmark price that follows it.
class _TreasuryCard extends StatelessWidget {
  const _TreasuryCard({required this.treasury, required this.price});
  final int treasury;
  final int price;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final left = Coin.supply == 0 ? 0.0 : treasury / Coin.supply;
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: Container(
        decoration: BoxDecoration(
          border: p.isDark ? Border.all(color: p.line) : null,
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            colors: p.isDark
                ? const [Color(0xFF10251D), Color(0xFF0E1211)]
                : const [Color(0xFF0D1110), Color(0xFF1C2A25)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: -70,
              bottom: -90,
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [p.accent.withValues(alpha: .28), p.accent.withValues(alpha: 0)]),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.xl, Space.lg, Space.lg, Space.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('NETWORK TREASURY', style: Txt.mono(p.accent, size: 11, w: FontWeight.w500).copyWith(letterSpacing: 1.6)),
                      const Spacer(),
                      _HeroPill(Icons.key_off_outlined, 'no owner · no key'),
                    ],
                  ),
                  const SizedBox(height: Space.xl),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          _grouped(treasury),
                          style: Txt.display(Colors.white).copyWith(
                            fontSize: 38,
                            letterSpacing: -1.2,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text('MNT', style: Txt.mono(Colors.white54, size: 13, w: FontWeight.w500)),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    child: LinearProgressIndicator(
                      value: left.clamp(0, 1).toDouble(),
                      minHeight: 6,
                      color: p.accent,
                      backgroundColor: Colors.white.withValues(alpha: .1),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    left > .9999
                        ? 'Over 99.99% of the ${_grouped(Coin.supply)} supply is still in the treasury'
                        : '${(left * 100).toStringAsFixed(2)}% of the ${_grouped(Coin.supply)} supply is still in the treasury',
                    style: Txt.small(Colors.white60),
                  ),
                  const SizedBox(height: Space.lg),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Checkmark price', style: Txt.small(Colors.white54)),
                            const SizedBox(height: 2),
                            Text('${Coin.format(price)} MNT', style: Txt.bodyStrong(Colors.white)),
                          ],
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            await Clipboard.setData(ClipboardData(text: Coin.treasury));
                            if (context.mounted) toast(context, 'Treasury address copied');
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Address', style: Txt.small(Colors.white54)),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      '${Coin.treasury.substring(0, 6)}…${Coin.treasury.substring(58)}',
                                      overflow: TextOverflow.ellipsis,
                                      style: Txt.mono(Colors.white, size: 12, w: FontWeight.w500),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.copy_rounded, size: 12, color: Colors.white54),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .08), borderRadius: BorderRadius.circular(Radii.pill)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: Colors.white70),
        const SizedBox(width: 5),
        Text(text, style: Txt.mono(Colors.white70, size: 10.5)),
      ],
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile(this.icon, this.value, this.label, {this.warn = false});
  final IconData icon;
  final String value;
  final String label;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final fg = warn ? p.danger : p.ink;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: warn ? p.dangerSoft : p.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: warn ? p.danger.withValues(alpha: .25) : p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, size: 18, color: warn ? p.danger : p.muted),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: Txt.heading(fg).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              ),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted).copyWith(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

/// One signed record: what it did, between whom, and how settled it is.
class _Record extends ConsumerWidget {
  const _Record({required this.tx, required this.view, required this.me});
  final CoinTx tx;
  final CoinView view;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    String who(String id) => id == Coin.treasury ? 'Treasury' : (id == me ? 'You' : e.nameOf(id));
    final accepted = view.contains(tx.hash);
    final conf = view.confirmation(tx.hash);
    final voided = view.voided.contains(tx.hash);
    final (icon, label) = switch (tx.kind) {
      'mint' => (Icons.auto_awesome_rounded, 'Welcome grant'),
      'reward' => (Icons.workspace_premium_outlined, 'Reward'),
      'send' => (Icons.swap_horiz_rounded, tx.to == Coin.treasury ? 'Paid the treasury' : 'Payment'),
      'lock' => (Icons.lock_outline_rounded, 'Escrow opened'),
      'ack' => (Icons.handshake_outlined, 'Escrow accepted'),
      'release' => (Icons.lock_open_rounded, 'Escrow released'),
      'refund' => (Icons.undo_rounded, 'Escrow refunded'),
      'cancel' => (Icons.undo_rounded, 'Escrow cancelled'),
      'claim' => (Icons.lock_open_rounded, 'Escrow claimed'),
      'dispute' => (Icons.gavel_rounded, 'Escrow disputed'),
      _ => (Icons.receipt_long_outlined, tx.kind),
    };
    final route = switch (tx.kind) {
      'mint' || 'reward' => 'Treasury → ${who(tx.from)}',
      'ack' || 'dispute' || 'cancel' || 'claim' => 'by ${who(tx.from)}',
      _ => '${who(tx.from)} → ${who(tx.to)}',
    };
    final (stage, fg, bg) = !accepted
        ? ('Not accepted', p.danger, p.dangerSoft)
        : voided
            ? ('No effect', p.muted, p.raised)
            : switch (conf.state) {
                Settle.final_ => ('Final', p.accent, p.accentSoft),
                Settle.witnessed => ('Witnessed', MarketColors(p).blue, MarketColors(p).blueSoft),
                Settle.conflicted => ('Conflicted', p.danger, p.dangerSoft),
                _ => ('Accepted', p.inkSoft, p.raised),
              };
    return InkWell(
      onTap: () => showTxSheet(context, tx, me),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(13)),
              child: Icon(icon, size: 19, color: p.inkSoft),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Txt.bodyStrong(p.ink)),
                  const SizedBox(height: 1),
                  Text(
                    [route, if (tx.ts > 0) timeAgo(tx.ts)].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.small(p.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(tx.amount == 0 ? '—' : Coin.format(tx.amount), style: Txt.mono(p.ink, size: 13, w: FontWeight.w500)),
                const SizedBox(height: 4),
                Pill(stage, fg: fg, bg: bg),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 99999990.00 → 99,999,990.00, for amounts too long to read at a glance.
String _grouped(int minor) {
  final s = Coin.format(minor);
  final dot = s.indexOf('.');
  final whole = dot < 0 ? s : s.substring(0, dot);
  final buf = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
    buf.write(whole[i]);
  }
  return dot < 0 ? '$buf' : '$buf${s.substring(dot)}';
}
