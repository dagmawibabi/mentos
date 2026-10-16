import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../net/pay/coin.dart';
import '../../state/calls.dart';
import '../../widgets/ui.dart';

class LedgerScreen extends ConsumerStatefulWidget {
  const LedgerScreen({super.key});
  @override
  ConsumerState<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends ConsumerState<LedgerScreen> {
  String query = '';
  String filter = 'all';
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    ref.watch(coinTickProvider);
    final coin = ref.watch(coinProvider);
    final p = context.pal;
    if (coin == null) return const Scaffold(body: Loading());
    final view = coin.view();
    final accepted = view.chains.values
        .expand((x) => x)
        .map((x) => x.hash)
        .toSet();
    final pool = coin.pool()..sort((a, b) => b.ts.compareTo(a.ts));
    final rows = pool
        .where(
          (t) =>
              (filter == 'all' ||
                  (filter == 'treasury'
                      ? t.to == Coin.treasury ||
                            t.isMint ||
                            t.kind == 'reward' ||
                            Coin.serviceFee(t.amount, t.memo) > 0
                      : !accepted.contains(t.hash))) &&
              '${t.hash} ${t.from} ${t.to} ${t.memo}'.toLowerCase().contains(
                query.toLowerCase(),
              ),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Mentos ledger')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: p.accentSoft,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('THE NETWORK’S WALLET', style: Txt.label(p.accent)),
                const SizedBox(height: 12),
                Text(
                  '${Coin.format(coin.balance(Coin.treasury))} Mentos',
                  style: Txt.display(p.ink),
                ),
                const SizedBox(height: 8),
                Text(
                  'Opened with ${Coin.format(Coin.supply)}. Checkmark ${Coin.format(Coin.badgePrice(coin.balance(Coin.treasury)))}, higher as this balance falls. No owner, no private key.',
                  style: Txt.body(p.inkSoft),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: Coin.treasury));
                    if (context.mounted) {
                      toast(context, 'Treasury address copied');
                    }
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy treasury address'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '${view.chains.length} identities · ${accepted.length} accepted records · ${Coin.format(view.balances.values.fold<int>(0, (a, b) => a + b))} supply',
            style: Txt.mono(p.muted),
          ),
          const SizedBox(height: 12),
          Text(
            'This is the ledger known to your device. Records are signed; conflicting payments can change the accepted view when peers synchronize. Grants are per identity, not per person.',
            style: Txt.small(p.muted),
          ),
          const SectionLabel('Contribution rewards'),
          Text(
            'Task and resource payments fund a 5% network fee. Receive 5% of a paid task or resource receipt, capped at 0.10 Mentos per receipt. Each receipt can be claimed once, while treasury funds last. Receipts prove payment, not the quality of work.',
            style: Txt.small(p.inkSoft),
          ),
          if (coin.rewardReceipts().isEmpty)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('No unclaimed rewards'),
              subtitle: Text(
                'Complete paid work to receive an eligible receipt.',
              ),
            ),
          for (final receipt in coin.rewardReceipts())
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${Coin.format(Coin.rewardAmount(receipt.amount))} Mentos',
              ),
              subtitle: Text(
                receipt.memo,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => busy = true);
                        try {
                          await coin.claimReward(receipt.hash);
                          if (context.mounted) {
                            toast(context, 'Reward recorded');
                          }
                        } catch (err) {
                          if (context.mounted) toast(context, '$err');
                        } finally {
                          if (mounted) setState(() => busy = false);
                        }
                      },
                child: const Text('Claim'),
              ),
            ),
          const SectionLabel('Explore records'),
          TextField(
            onChanged: (v) => setState(() => query = v.trim()),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Address, transaction hash, or note',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final option in const {
                'all': 'All records',
                'treasury': 'Treasury',
                'excluded': 'Not accepted',
              }.entries)
                ChoiceChip(
                  label: Text(option.value),
                  selected: filter == option.key,
                  onSelected: (_) => setState(() => filter = option.key),
                ),
            ],
          ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No records match your search.'),
            ),
          for (final tx in rows)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                tx.isMint
                    ? Icons.auto_awesome
                    : tx.kind == 'reward'
                    ? Icons.workspace_premium_outlined
                    : Icons.swap_horiz,
                color: p.accent,
              ),
              title: Text('${Coin.format(tx.amount)} Mentos · ${tx.kind}'),
              subtitle: Text(
                '${accepted.contains(tx.hash) ? 'Accepted in this view' : 'Pending or conflicting'}\n${tx.memo.isEmpty ? tx.hash : tx.memo}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (ctx) => SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Transaction details', style: Txt.title(p.ink)),
                        for (final entry in {
                          'Status': accepted.contains(tx.hash)
                              ? 'Accepted in current view'
                              : 'Pending / conflicting',
                          'Kind': tx.kind,
                          'Amount': '${Coin.format(tx.amount)} Mentos',
                          'Hash': tx.hash,
                          'From': tx.isMint || tx.kind == 'reward'
                              ? Coin.treasury
                              : tx.from,
                          'To': tx.to,
                          'Signed by': tx.from,
                          'Previous': tx.prev,
                          'Sequence': '${tx.seq}',
                          'Note': tx.memo,
                          'Signature': tx.sig,
                        }.entries) ...[
                          const SizedBox(height: 16),
                          Text(entry.key, style: Txt.small(p.muted)),
                          SelectableText(entry.value, style: Txt.mono(p.ink)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
