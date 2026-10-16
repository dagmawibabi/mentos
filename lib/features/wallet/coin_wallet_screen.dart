import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/pay/coin.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import 'ledger_screen.dart';

/// Opens the send page. [preset] preselects that person's address.
Future<void> sendMentos(BuildContext context, {String? preset}) {
  final to = preset == null || preset.isEmpty ? '' : '?to=${Uri.encodeQueryComponent(preset)}';
  return context.push('/send$to');
}

class CoinWalletScreen extends ConsumerWidget {
  const CoinWalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    ref.watch(coinTickProvider);
    final coin = ref.watch(coinProvider);
    final e = ref.watch(maybeEngineProvider);
    if (coin == null || e == null) return const Scaffold(body: Loading());
    final balance = coin.balance();
    final rows = coin.history();
    var received = 0;
    var sent = 0;
    for (final tx in rows) {
      if (tx.isMint) continue;
      if (tx.to == e.me.id) received += tx.amount;
      if (tx.from == e.me.id && tx.kind == 'send') {
        sent += tx.amount + Coin.serviceFee(tx.amount, tx.memo);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet'),
        actions: [
          IconBtn(
            Icons.help_outline_rounded,
            tooltip: 'How Mentos works',
            onTap: () => _explain(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.md,
              Space.gutter,
              0,
            ),
            child: Container(
              padding: const EdgeInsets.all(Space.lg),
              decoration: BoxDecoration(
                color: p.accentSoft,
                borderRadius: BorderRadius.circular(Radii.lg),
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
                      const Spacer(),
                      Text(
                        '${coin.accounts} on this ledger',
                        style: Txt.mono(p.inkSoft, size: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Coin.format(balance),
                    style: Txt.display(p.ink)
                        .copyWith(fontSize: 48, height: 1.02),
                  ),
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: e.me.id));
                      toast(context, 'Address copied');
                    },
                    child: Text(e.me.id, style: Txt.mono(p.inkSoft, size: 11)),
                  ),
                  const SizedBox(height: Space.lg),
                  Row(
                    children: [
                      _Stat('In', Coin.format(received)),
                      _Stat('Out', Coin.format(sent)),
                      _Stat(
                        'Payments',
                        '${rows.where((t) => !t.isMint).length}',
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.lg),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => sendMentos(context),
                          icon: const Icon(Icons.north_east_rounded, size: 18),
                          label: const Text('Send'),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _receive(context, e.me.id),
                          icon: const Icon(Icons.south_west_rounded, size: 18),
                          label: const Text('Receive'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.md,
              Space.gutter,
              0,
            ),
            child: Material(
              color: p.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.lg),
                side: BorderSide(color: p.line),
              ),
              child: InkWell(
                onTap: () => context.push('/market'),
                borderRadius: BorderRadius.circular(Radii.lg),
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Row(
                    children: [
                      Icon(Icons.storefront_outlined, color: p.ink),
                      const SizedBox(width: Space.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Marketplace', style: Txt.heading(p.ink)),
                            Text(
                              '${e.marketBoard().length} listed · plugins, ads, Mentos, tasks',
                              style: Txt.small(p.muted),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: p.faint),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.hub_outlined, color: p.accent),
            title: const Text('Explore the Mentos network'),
            subtitle: Text('Ledger, treasury and contribution rewards', style: Txt.small(p.muted)),
            trailing: const Icon(Icons.arrow_forward),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LedgerScreen()),
            ),
          ),
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
          for (final tx in rows) _Entry(tx: tx, me: e.me.id),
          const Hairline(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.md,
              Space.gutter,
              0,
            ),
            child: Text(
              'Every payment is signed by the sender and chained to their previous one. '
              'Open a row to read the signature, the previous hash, and the exact bytes.',
              style: Txt.small(p.muted),
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
                  'If two payments try to spend the same coins, the ledger keeps the one with the lower id. '
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

class _Entry extends ConsumerWidget {
  const _Entry({required this.tx, required this.me});
  final CoinTx tx;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final incoming = tx.to == me && (tx.from != me || tx.kind == 'reward');
    final title = tx.isMint
        ? 'Welcome grant'
        : tx.kind == 'reward' ? 'Network contribution reward' : incoming
        ? 'From ${e.nameOf(tx.from)}'
        : 'To ${e.nameOf(tx.to)}';
    final when = tx.ts == 0 ? 'with this identity' : timeAgo(tx.ts);
    final detail = tx.isMint
        ? 'from the network treasury · $when'
        : tx.memo.isEmpty
        ? when
        : '${tx.memo} · $when';
    final shown = tx.isMint || incoming
        ? tx.amount
        : -(tx.amount + Coin.serviceFee(tx.amount, tx.memo));
    return ListTile(
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _TxSheet(tx: tx, me: me),
      ),
      leading: CircleAvatar(
        backgroundColor: incoming || tx.isMint ? p.accentSoft : p.raised,
        child: Icon(
          tx.isMint
              ? Icons.auto_awesome_rounded
              : incoming
              ? Icons.south_west_rounded
              : Icons.north_east_rounded,
          size: 18,
          color: incoming || tx.isMint ? p.accent : p.inkSoft,
        ),
      ),
      title: Text(title),
      subtitle: Text(detail, style: Txt.small(p.muted)),
      trailing: Text(
        Coin.format(shown, sign: true),
        style: Txt.mono(
          incoming || tx.isMint ? p.accent : p.ink,
          size: 13,
          w: FontWeight.w500,
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Txt.heading(p.ink)),
          Text(label, style: Txt.mono(p.inkSoft, size: 11)),
        ],
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
    final shown = tx.isMint || incoming
        ? tx.amount
        : -(tx.amount + Coin.serviceFee(tx.amount, tx.memo));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .82,
      minChildSize: .4,
      maxChildSize: .95,
      builder: (_, scroll) => Material(
        color: p.bg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.lg),
        ),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(
            Space.gutter,
            Space.md,
            Space.gutter,
            Space.xl,
          ),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: p.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: Space.lg),
            Text(
              tx.isMint
                  ? 'WELCOME GRANT'
                  : incoming
                  ? 'RECEIVED'
                  : 'SENT',
              style: Txt.mono(p.faint, size: 11, w: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              Coin.format(shown, sign: true),
              style: Txt.display(incoming || tx.isMint ? p.accent : p.ink)
                  .copyWith(fontSize: 40, height: 1.05),
            ),
            const SizedBox(height: 6),
            Text(
              tx.isMint ? 'Signed by this identity, once' : written(tx.ts),
              style: Txt.small(p.muted),
            ),
            const SizedBox(height: Space.lg),
            _Line(
              'from',
              e.nameOf(tx.from),
              onOpen: () => context.push('/u/${tx.from}'),
            ),
            _Line('from address', tx.from, copy: tx.from),
            _Line(
              'to',
              e.nameOf(tx.to),
              onOpen: () => context.push('/u/${tx.to}'),
            ),
            _Line('to address', tx.to, copy: tx.to),
            _Line(
              'amount',
              '${Coin.format(tx.amount)} Mentos · ${tx.amount} minor units',
              copy: '${tx.amount}',
            ),
            if (tx.kind == 'send')
              _Line(
                'network fee',
                '${Coin.format(Coin.serviceFee(tx.amount, tx.memo))} Mentos',
              ),
            _Line('note', tx.memo.isEmpty ? '—' : tx.memo, copy: tx.memo),
            _Line('kind', tx.kind, copy: ''),
            _Line('sequence', '${tx.seq}', copy: '${tx.seq}'),
            _Line(
              'place in chain',
              index < 0
                  ? 'not in the kept chain'
                  : '${index + 1} of ${chain.length}',
              copy: '',
            ),
            _Line(
              'previous',
              tx.prev == Coin.genesis ? 'genesis' : tx.prev,
              copy: tx.prev,
            ),
            _Line('hash', tx.hash, copy: tx.hash),
            _Line(
              'signature',
              _signed == null
                  ? 'checking'
                  : _signed!
                  ? 'Ed25519, valid'
                  : 'does not verify',
              copy: tx.sig,
            ),
            _Line('shape', shape ?? 'accepted by the ledger rules', copy: ''),
            _Line(
              'signed at',
              written(tx.ts),
              copy: tx.ts == 0 ? '' : '${tx.ts}',
            ),
            _Line('topic', Coin.topicLabel, copy: Coin.topic),
            const SizedBox(height: Space.md),
            Text('Signed bytes', style: Txt.mono(p.faint, size: 11)),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: tx.body));
                toast(context, 'Signed bytes copied');
              },
              child: Text(tx.body, style: Txt.mono(p.ink, size: 11)),
            ),
            const SizedBox(height: Space.md),
            Text(
              'Phones that have seen this payment and the ones before it count the same balance. '
              'A second payment that spends the same coins loses if its hash is higher.',
              style: Txt.small(p.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.copy = '', this.onOpen});
  final String label;
  final String value;
  final String copy;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return InkWell(
      onTap:
          onOpen ??
          (copy.isEmpty
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: copy));
                  toast(context, 'Copied');
                }),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 108,
              child: Text(label, style: Txt.mono(p.faint, size: 11)),
            ),
            Expanded(child: Text(value, style: Txt.mono(p.ink, size: 11.5))),
          ],
        ),
      ),
    );
  }
}
