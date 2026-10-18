import 'package:flutter/material.dart';
import '../plugins/plugins_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/pay/coin.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import '../market/market_kit.dart';
import 'ledger_screen.dart';

/// Opens the send page. [preset] preselects that person's address.
Future<void> sendMentos(BuildContext context, {String? preset}) {
  final to = preset == null || preset.isEmpty
      ? ''
      : '?to=${Uri.encodeQueryComponent(preset)}';
  return context.push('/send$to');
}

/// Hides amounts and the address on this phone, for using the wallet in public.
final walletHiddenProvider = NotifierProvider<_WalletHidden, bool>(
  _WalletHidden.new,
);

class _WalletHidden extends Notifier<bool> {
  @override
  bool build() {
    final e = ref.watch(maybeEngineProvider);
    // Hidden until the person chooses to show it.
    return e?.db.getKv('wallet:hidden') != '0';
  }

  void toggle() {
    state = !state;
    ref.read(maybeEngineProvider)?.db.setKv('wallet:hidden', state ? '1' : '0');
  }
}

const _dots = '••••••';

String _short(String id) =>
    '${id.substring(0, 6)}…${id.substring(id.length - 6)}';

class CoinWalletScreen extends ConsumerWidget {
  const CoinWalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    ref.watch(coinTickProvider);
    final coin = ref.watch(coinProvider);
    final e = ref.watch(maybeEngineProvider);
    final hidden = ref.watch(walletHiddenProvider);
    if (coin == null || e == null) return const Scaffold(body: Loading());
    final balance = coin.balance();
    final rows = coin.history();
    final view = coin.view();
    final holds = view.holds(e.me.id);
    final open = coin.escrows().where((h) => h.remaining > 0).toList();
    var received = 0;
    var sent = 0;
    for (final tx in rows) {
      final d = walletDelta(view, tx, e.me.id);
      if (tx.isMint) continue;
      if (d > 0) received += d;
      if (d < 0) sent -= d;
    }
    // Activity grouped under day headers.
    final days = <String, List<CoinTx>>{};
    for (final tx in rows) {
      (days[tx.ts == 0 ? 'When this identity was made' : dayLabel(tx.ts)] ??=
              [])
          .add(tx);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet'),
        actions: [
          IconBtn(
            hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            tooltip: hidden ? 'Show balance' : 'Hide balance',
            onTap: () => ref.read(walletHiddenProvider.notifier).toggle(),
          ),
          IconBtn(
            Icons.help_outline_rounded,
            tooltip: 'How Mentos works',
            onTap: () => _explain(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        // Plugin cards sit under the balance.
        key: const PageStorageKey('wallet'),
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.sm,
              Space.gutter,
              0,
            ),
            child: _Hero(
              balance: balance,
              hidden: hidden,
              id: e.me.id,
              accounts: coin.accounts,
              outgoing: holds.outgoing,
              incoming: holds.incoming,
              received: received,
              sent: sent,
              badge: coin.hasBadge(e.me.id),
              onToggle: () => ref.read(walletHiddenProvider.notifier).toggle(),
            ),
          ),
          const PluginSlotView('wallet.top'),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.lg,
              Space.gutter,
              0,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Quick(
                  Icons.north_east_rounded,
                  'Send',
                  () => sendMentos(context),
                  primary: true,
                ),
                _Quick(
                  Icons.south_west_rounded,
                  'Receive',
                  () => _receive(context, e.me.id),
                ),
                _Quick(
                  Icons.storefront_outlined,
                  'Market',
                  () => context.push('/market'),
                ),
                _Quick(
                  Icons.currency_exchange_rounded,
                  'Get MNT',
                  () => context.push('/market?tab=exchange'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.xl,
              Space.gutter,
              0,
            ),
            child: _LinkCard(
              icon: Icons.hub_outlined,
              title: 'Explore the Mentos network',
              subtitle: 'Ledger, treasury and contribution rewards',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const LedgerScreen()),
              ),
            ),
          ),
          if (open.isNotEmpty) ...[
            SectionLabel(
              'In escrow',
              trailing: Text(
                '${open.length}',
                style: Txt.mono(p.muted, size: 11),
              ),
            ),
            for (final h in open)
              _HoldRow(hold: h, me: e.me.id, hidden: hidden),
          ],
          SectionLabel('Activity'),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Text(
                coin.pool().any((t) => t.isMint && t.from == e.me.id)
                    ? 'The treasury cannot cover the 5.00 welcome grant yet. It is paid when checkmarks and fees refill it.'
                    : 'Your welcome grant appears here once this phone finishes signing it.',
                style: Txt.small(p.muted),
              ),
            ),
          for (final day in days.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.gutter,
                Space.md,
                Space.gutter,
                2,
              ),
              child: Text(
                day.key,
                style: Txt.small(p.muted).copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            for (final tx in day.value)
              _Entry(tx: tx, me: e.me.id, hidden: hidden),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.lg,
              Space.gutter,
              0,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.verified_user_outlined, size: 16, color: p.faint),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    'Every payment is signed by the sender and chained to their previous one. '
                    'Open a row to read the signature, the previous hash, and the exact bytes.',
                    style: Txt.small(p.muted),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _explain(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final p = ctx.pal;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              0,
              Space.gutter,
              Space.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Mentos', style: Txt.title(p.ink)),
                const SizedBox(height: Space.sm),
                Text(
                  'Mentos is a ledger the phones on this network keep together. The treasury starts with ${Coin.format(Coin.supply)} and that is the whole supply. '
                  'A new identity draws 5.00 from it, signed by its own key, and that draw can be written only once. '
                  'When the treasury cannot cover 5.00, the new identity waits until checkmarks or service fees refill it.\n\n'
                  'A checkmark pays the treasury. The price is 10.00 while the treasury is full, then 0.01 higher for every 5.00 that has been drawn out, and lower again as those coins are paid back.\n\n'
                  'When you send coins, your phone signs the payment and chains it to your previous one, then '
                  'shares it with connected peers. Every phone that has seen the same payments works out the same balance.\n\n'
                  'Escrow is built in: a hold moves coins out of your balance for someone, and only you can release it to them. '
                  'They can hand it back; if they accepted and you never disputed, they can claim it after its deadline. '
                  'An arbiter you both agreed on can split a disputed hold.\n\n'
                  'Every phone signs a vote for the first payment it sees at each place in a chain. '
                  'If someone signs two payments that spend the same coins, the one backed by more stake wins, '
                  'the account is flagged as a double spender, and the payment shows as conflicted. '
                  'A payment is final once enough other phones have witnessed it.\n\n'
                  'Nothing here is a bank, and coins are not redeemable outside Mentos.',
                  style: Txt.body(p.inkSoft),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _receive(BuildContext context, String id) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final p = ctx.pal;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              0,
              Space.gutter,
              Space.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Your address', style: Txt.title(p.ink)),
                const SizedBox(height: Space.md),
                Container(
                  padding: const EdgeInsets.all(Space.md),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: QrImageView(
                    data: id,
                    size: 200,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: Space.md),
                Text(
                  id,
                  textAlign: TextAlign.center,
                  style: Txt.mono(p.muted, size: 11),
                ),
                const SizedBox(height: Space.md),
                FilledButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: id));
                    Navigator.pop(ctx);
                    toast(context, 'Address copied');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy address'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// How much [tx] changed [me]'s spendable balance.
int walletDelta(CoinView v, CoinTx tx, String me) {
  final hold = tx.isEscrowOp ? v.escrows[tx.esc] : null;
  switch (tx.kind) {
    case 'mint':
    case 'reward':
      return tx.from == me ? tx.amount : 0;
    case 'send':
      if (tx.from == me)
        return -(tx.amount + Coin.serviceFee(tx.amount, tx.memo));
      return tx.to == me ? tx.amount : 0;
    case 'lock':
      return tx.from == me ? -tx.amount : 0;
    case 'release':
      if (v.voided.contains(tx.hash) || tx.to != me) return 0;
      return tx.amount - Coin.tradeFee(tx.amount, tx.memo);
    case 'refund':
      return !v.voided.contains(tx.hash) && tx.to == me ? tx.amount : 0;
    case 'claim':
      if (hold == null || v.voided.contains(tx.hash) || hold.payee != me)
        return 0;
      final released = hold.steps
          .where((t) => t.kind == 'release')
          .fold<int>(0, (s, t) => s + t.amount);
      final claimed = hold.released - released;
      return claimed - Coin.tradeFee(claimed, hold.memo);
    case 'cancel':
      if (hold == null || v.voided.contains(tx.hash) || hold.payer != me)
        return 0;
      return hold.amount -
          hold.released -
          hold.steps
              .where((t) => t.kind == 'refund')
              .fold<int>(0, (s, t) => s + t.amount);
  }
  return 0;
}

class _Entry extends ConsumerWidget {
  const _Entry({required this.tx, required this.me, this.hidden = false});
  final CoinTx tx;
  final String me;
  final bool hidden;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final coin = ref.watch(coinProvider)!;
    final v = coin.view();
    final shown = walletDelta(v, tx, me);
    final hold = tx.isEscrowOp
        ? v.escrows[tx.esc]
        : (tx.kind == 'lock' ? v.escrows[tx.hash] : null);
    final other = hold == null
        ? ''
        : (hold.payer == me ? hold.payee : hold.payer);
    final title = switch (tx.kind) {
      'mint' => 'Welcome grant',
      'reward' => 'Network contribution reward',
      'send' =>
        tx.to == me ? 'From ${e.nameOf(tx.from)}' : 'To ${e.nameOf(tx.to)}',
      'lock' =>
        tx.from == me
            ? 'Held for ${e.nameOf(tx.to)}'
            : '${e.nameOf(tx.from)} is holding for you',
      'ack' =>
        tx.from == me ? 'You accepted a hold' : '${e.nameOf(tx.from)} accepted',
      'release' =>
        tx.to == me
            ? 'Released by ${e.nameOf(tx.from)}'
            : 'Released to ${e.nameOf(tx.to)}',
      'refund' =>
        tx.to == me
            ? 'Refund from ${e.nameOf(tx.from)}'
            : 'Refunded to ${e.nameOf(tx.to)}',
      'claim' =>
        tx.from == me
            ? 'Claimed from ${e.nameOf(other)}'
            : '${e.nameOf(tx.from)} claimed',
      'cancel' =>
        tx.from == me
            ? 'You cancelled a hold'
            : '${e.nameOf(tx.from)} cancelled',
      'dispute' =>
        tx.from == me ? 'You disputed a hold' : '${e.nameOf(tx.from)} disputed',
      _ => tx.kind,
    };
    final when = tx.ts == 0 ? 'with this identity' : timeAgo(tx.ts);
    final conf = coin.confirmation(tx.hash);
    final voided = v.voided.contains(tx.hash);
    final detail = [
      if (tx.isMint) 'from the network treasury',
      if (!tx.isMint &&
          tx.memo.isNotEmpty &&
          !tx.isEscrowOp &&
          tx.kind != 'lock')
        tx.memo,
      if (tx.kind == 'lock') 'escrow · ${_memoLabel(tx.memo)}',
      if (voided) 'had no effect',
      when,
    ].join(' · ');
    final positive = shown > 0;
    return ListTile(
      onTap: () => showTxSheet(context, tx, me),
      leading: CircleAvatar(
        backgroundColor: positive || tx.isMint ? p.accentSoft : p.raised,
        child: Icon(
          switch (tx.kind) {
            'mint' => Icons.auto_awesome_rounded,
            'lock' => Icons.lock_outline_rounded,
            'ack' => Icons.handshake_outlined,
            'dispute' => Icons.gavel_rounded,
            'cancel' || 'refund' => Icons.undo_rounded,
            'release' || 'claim' => Icons.lock_open_rounded,
            _ => positive ? Icons.south_west_rounded : Icons.north_east_rounded,
          },
          size: 18,
          color: positive || tx.isMint ? p.accent : p.inkSoft,
        ),
      ),
      title: Text(title),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              detail,
              style: Txt.small(p.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (conf.state == Settle.conflicted) ...[
            const SizedBox(width: 6),
            Icon(Icons.warning_amber_rounded, size: 14, color: p.danger),
          ] else if (conf.state == Settle.final_ && !tx.isMint) ...[
            const SizedBox(width: 6),
            Icon(Icons.verified_outlined, size: 13, color: p.accent),
          ],
        ],
      ),
      trailing: Text(
        shown == 0 ? '·' : (hidden ? '••••' : Coin.format(shown, sign: true)),
        style: Txt.mono(
          positive || tx.isMint ? p.accent : p.ink,
          size: 13,
          w: FontWeight.w500,
        ),
      ),
    );
  }
}

/// A hold this phone is part of, with what it can sign next.
class _HoldRow extends ConsumerWidget {
  const _HoldRow({required this.hold, required this.me, this.hidden = false});
  final Escrow hold;
  final String me;
  final bool hidden;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final other = hold.payer == me ? hold.payee : hold.payer;
    final route = _dealRoute(hold.memo);
    final label = switch (hold.state) {
      HoldState.open => 'waiting to be accepted',
      HoldState.accepted => 'auto-release ${relativeTime(hold.until)}',
      HoldState.disputed => 'disputed',
      _ => '',
    };
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: hold.disputed ? p.dangerSoft : p.raised,
        child: Icon(
          hold.disputed ? Icons.gavel_rounded : Icons.lock_clock_outlined,
          size: 18,
          color: hold.disputed ? p.danger : p.inkSoft,
        ),
      ),
      title: Text(
        hold.payer == me
            ? 'Holding for ${e.nameOf(other)}'
            : '${e.nameOf(other)} holds for you',
      ),
      subtitle: Text(
        '${_memoLabel(hold.memo)} · $label',
        style: Txt.small(p.muted),
      ),
      trailing: hidden
          ? Text('••••', style: Txt.mono(p.ink, size: 13))
          : Amount(hold.remaining, size: 13, unit: false),
      onTap: () => route != null
          ? context.push(route)
          : showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => _HoldSheet(hold: hold, me: me),
            ),
    );
  }
}

String _memoLabel(String memo) => switch (memo.split(':').first) {
  'order' => 'Shop order',
  'task' => 'Task reward',
  'resource' => memo.contains(':lease:') ? 'Storage lease' : 'Compute job',
  'exchange' => 'Birr exchange',
  _ => memo.isEmpty ? 'Hold' : memo,
};

String? _dealRoute(String memo) {
  final parts = memo.split(':');
  if (parts.length < 2) return null;
  return switch (parts[0]) {
    'order' => '/market/r/order/${parts[1]}',
    'exchange' => '/market/r/trade/${parts[1]}',
    'resource' when parts.length >= 3 && parts[1] == 'lease' =>
      '/market/r/lease/${parts[2]}',
    'resource' when parts.length >= 3 && parts[1] == 'job' =>
      '/market/r/job/${parts[2]}',
    _ => null,
  };
}

/// Hold controls for holds that are not tied to a market record.
class _HoldSheet extends ConsumerWidget {
  const _HoldSheet({required this.hold, required this.me});
  final Escrow hold;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coin = ref.watch(coinProvider)!;
    final acts = hold.actionsFor(me, nowMs());
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          0,
          Space.gutter,
          Space.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EscrowPanel(
              lock: hold.id,
              payerLabel: 'Payer',
              payeeLabel: 'Payee',
            ),
            const SizedBox(height: Space.md),
            for (final a in const [
              'ack',
              'release',
              'refund',
              'claim',
              'cancel',
              'dispute',
            ])
              if (acts.contains(a))
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: OutlinedButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      await attempt(
                        context,
                        () => coin.step(hold.id, a),
                        done: 'Signed',
                      );
                    },
                    child: Text(switch (a) {
                      'ack' => 'Accept',
                      'release' => 'Release to the payee',
                      'refund' => 'Hand back to the payer',
                      'claim' => 'Claim',
                      'cancel' => 'Cancel',
                      _ => 'Dispute',
                    }),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// The balance card: dark, with the accent glowing in one corner.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.balance,
    required this.hidden,
    required this.id,
    required this.accounts,
    required this.outgoing,
    required this.incoming,
    required this.received,
    required this.sent,
    required this.badge,
    required this.onToggle,
  });
  final int balance;
  final bool hidden;
  final String id;
  final int accounts;
  final int outgoing;
  final int incoming;
  final int received;
  final int sent;
  final bool badge;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    const fg = Colors.white;
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
              right: -60,
              top: -70,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      p.accent.withValues(alpha: .35),
                      p.accent.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.xl,
                Space.lg,
                Space.lg,
                Space.xl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'MENTOS',
                        style: Txt.mono(
                          p.accent,
                          size: 11,
                          w: FontWeight.w500,
                        ).copyWith(letterSpacing: 1.8),
                      ),
                      if (badge) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.verified_rounded, size: 14, color: p.accent),
                      ],
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(Radii.pill),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: p.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '$accounts on the ledger',
                              style: Txt.mono(Colors.white70, size: 10.5),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.xl),
                  Text('Available', style: Txt.small(Colors.white60)),
                  const SizedBox(height: 2),
                  GestureDetector(
                    onTap: onToggle,
                    child: AnimatedSwitcher(
                      duration: Motion.base,
                      // Large balances shrink to fit rather than overflow.
                      child: FittedBox(
                        key: ValueKey(hidden),
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              hidden ? _dots : Coin.format(balance),
                              style: Txt.display(fg).copyWith(
                                fontSize: 46,
                                height: 1.05,
                                letterSpacing: hidden ? 4 : -1.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'MNT',
                              style: Txt.mono(
                                Colors.white54,
                                size: 13,
                                w: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (outgoing > 0 || incoming > 0) ...[
                    const SizedBox(height: Space.sm),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (outgoing > 0)
                          _chip(
                            Icons.lock_outline_rounded,
                            '${hidden ? _dots : Coin.format(outgoing)} held for others',
                          ),
                        if (incoming > 0)
                          _chip(
                            Icons.lock_clock_outlined,
                            '${hidden ? _dots : Coin.format(incoming)} coming to you',
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: Space.xl),
                  Row(
                    children: [
                      _figure(
                        'Received',
                        hidden ? '••••' : Coin.format(received),
                      ),
                      _figure('Sent', hidden ? '••••' : Coin.format(sent)),
                      Expanded(
                        flex: 2,
                        child: GestureDetector(
                          onTap: hidden
                              ? null
                              : () {
                                  Clipboard.setData(ClipboardData(text: id));
                                  toast(context, 'Address copied');
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
                                      hidden ? 'hidden' : _short(id),
                                      overflow: TextOverflow.ellipsis,
                                      style: Txt.mono(
                                        fg,
                                        size: 12,
                                        w: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  if (!hidden) ...[
                                    const SizedBox(width: 4),
                                    const Icon(
                                      Icons.copy_rounded,
                                      size: 12,
                                      color: Colors.white54,
                                    ),
                                  ],
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

  Widget _chip(IconData icon, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: Colors.white70),
        const SizedBox(width: 5),
        Text(text, style: Txt.mono(Colors.white70, size: 11)),
      ],
    ),
  );

  Widget _figure(String label, String value) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Txt.small(Colors.white54)),
        const SizedBox(height: 2),
        Text(value, style: Txt.bodyStrong(Colors.white)),
      ],
    ),
  );
}

/// Round quick action under the balance.
class _Quick extends StatelessWidget {
  const _Quick(this.icon, this.label, this.onTap, {this.primary = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Pressable(
      onTap: onTap,
      child: SizedBox(
        width: 76,
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: primary ? p.accent : p.surface,
                borderRadius: BorderRadius.circular(20),
                border: primary ? null : Border.all(color: p.line),
              ),
              child: Icon(icon, color: primary ? p.accentInk : p.ink, size: 22),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: Txt.small(p.inkSoft).copyWith(fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Material(
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: p.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: 14,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: p.raised,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: p.ink, size: 20),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Txt.bodyStrong(p.ink)),
                    Text(
                      subtitle,
                      style: Txt.small(p.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: p.faint),
            ],
          ),
        ),
      ),
    );
  }
}

class _TxSheet extends ConsumerStatefulWidget {
  const _TxSheet({required this.tx, required this.me});
  final CoinTx tx;
  final String me;

  @override
  ConsumerState<_TxSheet> createState() => _TxSheetState();
}

class _TxSheetState extends ConsumerState<_TxSheet> {
  bool? _signed;

  @override
  void initState() {
    super.initState();
    widget.tx.verify().then((ok) {
      if (mounted) setState(() => _signed = ok);
    });
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    toast(context, '$what copied');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final tx = widget.tx;
    final me = widget.me;
    final coin = ref.watch(coinProvider);
    final incoming = tx.to == me && (tx.from != me || tx.kind == 'reward');
    final chain = coin?.view().chains[tx.from] ?? const <CoinTx>[];
    final index = chain.indexWhere((t) => t.hash == tx.hash);
    final shape = tx.problem();
    final view = coin?.view();
    final shown = view == null ? (incoming ? tx.amount : -tx.amount) : walletDelta(view, tx, me);
    final conf = coin?.confirmation(tx.hash);
    final voided = view != null && view.voided.contains(tx.hash);

    final (String title, IconData icon, Color tint) = switch (tx.kind) {
      'mint' => ('Welcome grant', Icons.auto_awesome_rounded, p.accent),
      'lock' => ('Escrow hold', Icons.lock_outline_rounded, const Color(0xFFD97706)),
      'ack' => ('Hold accepted', Icons.handshake_outlined, const Color(0xFF0EA5E9)),
      'release' => ('Released from escrow', Icons.lock_open_rounded, p.accent),
      'refund' => ('Refunded', Icons.undo_rounded, const Color(0xFF6366F1)),
      'cancel' => ('Hold cancelled', Icons.block_rounded, p.muted),
      'claim' => ('Claimed', Icons.download_done_rounded, p.accent),
      'dispute' => ('Disputed', Icons.gavel_rounded, p.danger),
      'reward' => ('Reward', Icons.emoji_events_outlined, const Color(0xFFD97706)),
      _ => incoming ? ('Received', Icons.south_west_rounded, p.accent) : ('Sent', Icons.north_east_rounded, p.ink),
    };
    final (String status, IconData statusIcon, Color statusColor) = voided
        ? ('No effect', Icons.remove_circle_outline_rounded, p.muted)
        : switch (conf?.state) {
            Settle.final_ => ('Final', Icons.verified_rounded, p.accent),
            Settle.witnessed => ('Witnessed', Icons.task_alt_rounded, p.accent),
            Settle.accepted => ('Accepted', Icons.check_circle_outline_rounded, const Color(0xFF0EA5E9)),
            Settle.conflicted => ('Conflicted', Icons.warning_amber_rounded, p.danger),
            _ => ('Pending', Icons.schedule_rounded, const Color(0xFFD97706)),
          };

    Widget card(List<Widget> children) => Container(
      margin: const EdgeInsets.only(top: Space.md),
      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: p.line)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );

    Widget row(String label, String value, {String? copy, VoidCallback? onTap, Widget? trailing, bool first = false, bool mono = false}) => InkWell(
      onTap: onTap ?? (copy == null || copy.isEmpty ? null : () => _copy(copy, label)),
      child: Container(
        decoration: BoxDecoration(border: first ? null : Border(top: BorderSide(color: p.line))),
        padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 104, child: Text(label, style: Txt.small(p.muted))),
            Expanded(child: Text(value, style: mono ? Txt.mono(p.ink, size: 11.5) : Txt.body(p.ink).copyWith(fontSize: 14))),
            if (trailing != null) trailing else if (copy != null && copy.isNotEmpty) Icon(Icons.copy_rounded, size: 14, color: p.faint),
          ],
        ),
      ),
    );

    Widget party(String label, String id) => Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/u/$id'),
        child: Padding(
          padding: const EdgeInsets.all(Space.sm),
          child: Column(
            children: [
              Avatar(id: id, size: 46, presence: false),
              const SizedBox(height: 6),
              Text(label, style: Txt.label(p.faint)),
              const SizedBox(height: 2),
              Text(id == me ? 'You' : e.nameOf(id), maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(p.ink).copyWith(fontSize: 14)),
              Text('${id.substring(0, 6)}…${id.substring(id.length - 4)}', style: Txt.mono(p.muted, size: 10.5)),
            ],
          ),
        ),
      ),
    );

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .78,
      minChildSize: .4,
      maxChildSize: .95,
      builder: (_, scroll) => Material(
        color: p.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: ListView(
          controller: scroll,
          padding: EdgeInsets.zero,
          children: [
            // ---------------------------------------------------- hero
            Container(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.xl),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [tint.withValues(alpha: p.isDark ? .07 : .12), p.bg],
                ),
              ),
              child: Column(
                children: [
                  Container(width: 36, height: 4, decoration: BoxDecoration(color: p.line, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: Space.lg),
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(color: tint.withValues(alpha: .16), shape: BoxShape.circle),
                    child: Icon(icon, color: tint == p.ink ? p.inkSoft : tint, size: 28),
                  ),
                  const SizedBox(height: Space.md),
                  Text(title, style: Txt.bodyStrong(p.inkSoft)),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: Coin.format(shown, sign: true)),
                          TextSpan(text: ' MNT', style: Txt.heading(p.muted).copyWith(fontSize: 18)),
                        ],
                      ),
                      style: Txt.display(shown > 0 || tx.isMint ? p.accent : p.ink).copyWith(fontSize: 42, height: 1.05, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                  const SizedBox(height: Space.sm),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: statusColor.withValues(alpha: .12), borderRadius: BorderRadius.circular(Radii.pill)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(statusIcon, size: 14, color: statusColor),
                            const SizedBox(width: 5),
                            Text(status, style: Txt.small(statusColor).copyWith(fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                      Text(tx.ts == 0 ? 'at the start of this identity' : written(tx.ts), style: Txt.small(p.muted)),
                    ],
                  ),
                  if (tx.memo.isNotEmpty && !tx.isEscrowOp && tx.kind != 'lock') ...[
                    const SizedBox(height: Space.md),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.line)),
                      child: Text('“${tx.memo}”', textAlign: TextAlign.center, style: Txt.body(p.ink)),
                    ),
                  ],
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // -------------------------------------------- parties
                  if (!tx.isMint)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: Space.sm),
                      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: p.line)),
                      child: Row(
                        children: [
                          party('FROM', tx.from),
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(color: p.raised, shape: BoxShape.circle),
                            child: Icon(Icons.arrow_forward_rounded, size: 16, color: p.muted),
                          ),
                          party('TO', tx.to),
                        ],
                      ),
                    ),

                  // -------------------------------------------- details
                  card([
                    row('Amount', '${Coin.format(tx.amount)} MNT', copy: '${tx.amount}', first: true),
                    if (tx.kind == 'send') row('Network fee', '${Coin.format(Coin.serviceFee(tx.amount, tx.memo))} MNT'),
                    if (tx.kind == 'lock') row('For', _memoLabel(tx.memo)),
                    if (conf != null)
                      row(
                        'Ledger',
                        conf.state == Settle.pending ? 'Not counted by this phone yet' : '${conf.label} by ${conf.witnesses} witness${conf.witnesses == 1 ? '' : 'es'} holding ${Coin.format(conf.stake)} MNT',
                      ),
                    if (voided) row('Effect', 'None. The hold had already changed when this arrived.'),
                    if (tx.esc != null) row('Escrow', '${tx.esc!.substring(0, 12)}…', copy: tx.esc!),
                    if (tx.until != null) row('Deadline', written(tx.until!)),
                    if (tx.ackBy != null) row('Accept by', written(tx.ackBy!)),
                    if (tx.arbiter != null) row('Arbiter', e.nameOf(tx.arbiter!), onTap: () => context.push('/u/${tx.arbiter}'), trailing: Icon(Icons.chevron_right_rounded, size: 18, color: p.faint)),
                  ]),

                  // -------------------------------------------- proof
                  card([
                    Padding(
                      padding: const EdgeInsets.all(Space.md),
                      child: Row(
                        children: [
                          Icon(
                            _signed == null ? Icons.hourglass_top_rounded : (_signed! ? Icons.gpp_good_rounded : Icons.gpp_bad_rounded),
                            color: _signed == false ? p.danger : p.accent,
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _signed == null ? 'Checking the signature…' : (_signed! ? 'Signed and valid' : 'Signature does not verify'),
                                  style: Txt.bodyStrong(p.ink).copyWith(fontSize: 14),
                                ),
                                Text(
                                  [
                                    'Ed25519',
                                    index < 0 ? 'not in the kept chain' : 'payment ${index + 1} of ${chain.length} in the sender\'s chain',
                                    if (shape != null) shape,
                                  ].join(' · '),
                                  style: Txt.small(p.muted),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    row('Hash', '${tx.hash.substring(0, 20)}…', copy: tx.hash, mono: true),
                  ]),

                  // -------------------------------------------- technical
                  Container(
                    margin: const EdgeInsets.only(top: Space.md),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: p.line)),
                    clipBehavior: Clip.antiAlias,
                    child: Material(
                      color: p.surface,
                      child: Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: Space.md),
                        leading: Icon(Icons.data_object_rounded, color: p.muted, size: 20),
                        title: Text('Technical details', style: Txt.body(p.ink).copyWith(fontSize: 14)),
                        children: [
                          row('Kind', tx.kind),
                          row('Sequence', '${tx.seq}', copy: '${tx.seq}'),
                          row('Previous', tx.prev == Coin.genesis ? 'genesis' : '${tx.prev.substring(0, 20)}…', copy: tx.prev, mono: true),
                          row('Signature', '${tx.sig.substring(0, 20)}…', copy: tx.sig, mono: true),
                          row('From address', tx.from, copy: tx.from, mono: true),
                          row('To address', tx.to, copy: tx.to, mono: true),
                          row('Topic', Coin.topicLabel, copy: Coin.topic, mono: true),
                          row('Signed bytes', tx.body, copy: tx.body, mono: true),
                          Padding(
                            padding: const EdgeInsets.all(Space.md),
                            child: Text(
                              'Phones that have seen this payment and the ones before it count the same balance. Every phone votes for the first payment it sees at each place in a chain; a competing one only wins with more witness stake.',
                              style: Txt.small(p.muted),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ),
                  ),

                  // -------------------------------------------- actions
                  const SizedBox(height: Space.lg),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: const Text('Copy hash'),
                          onPressed: () => _copy(tx.hash, 'Hash'),
                        ),
                      ),
                      if (!tx.isMint && !tx.isEscrowOp && tx.kind != 'lock') ...[
                        const SizedBox(width: Space.sm),
                        Expanded(
                          child: FilledButton.icon(
                            icon: Icon(incoming ? Icons.reply_rounded : Icons.replay_rounded, size: 16),
                            label: Text(incoming ? 'Pay back' : 'Pay again'),
                            onPressed: () {
                              Navigator.pop(context);
                              sendMentos(context, preset: incoming ? tx.from : tx.to);
                            },
                          ),
                        ),
                      ],
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

/// Opens the signed details of [tx], as seen from [me].
Future<void> showTxSheet(BuildContext context, CoinTx tx, String me) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (_) => _TxSheet(tx: tx, me: me),
);
