import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/market/market.dart';
import '../../net/pay/coin.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import 'deal_screens.dart';
import 'market_kit.dart';

/// Everything this phone is doing in the market, by kind.
class MarketHubScreen extends ConsumerWidget {
  const MarketHubScreen({super.key, this.tab});
  final String? tab;

  static const _tabs = ['buying', 'selling', 'tasks', 'trades', 'resources', 'listings', 'cases'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(marketProvider);
    ref.watch(marketTickProvider);
    if (m == null) return const Scaffold(body: Loading());
    final e = ref.watch(engineProvider);
    final cases = [
      ...m.orders(role: 'arbiter'),
      ...m.taskRecords(role: 'arbiter'),
    ];
    final initial = _tabs.indexOf(tab ?? 'buying').clamp(0, _tabs.length - 1);
    return DefaultTabController(
      length: _tabs.length,
      initialIndex: initial,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My market'),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              const Tab(text: 'Buying'),
              const Tab(text: 'Selling'),
              const Tab(text: 'Tasks'),
              const Tab(text: 'Trades'),
              const Tab(text: 'Rentals'),
              const Tab(text: 'Listings'),
              Tab(text: cases.isEmpty ? 'Cases' : 'Cases (${cases.length})'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _list(
              [
                for (final o in m.orders(role: 'buyer'))
                  DealRow(
                    title: _orderTitle(o),
                    subtitle: 'from ${e.nameOf(o['seller'] as String)} · ${timeAgo(o['created'] as int? ?? 0)}',
                    stage: m.orderStage(o),
                    amount: o['total'] as int?,
                    route: '/market/r/order/${o['id']}',
                    icon: Icons.shopping_bag_outlined,
                  ),
              ],
              'No purchases yet',
              'Anything you buy shows up here with its escrow.',
            ),
            _list(
              [
                for (final o in m.orders(role: 'seller'))
                  DealRow(
                    title: _orderTitle(o),
                    subtitle: 'to ${e.nameOf(o['buyer'] as String)} · ${timeAgo(o['created'] as int? ?? 0)}',
                    stage: m.orderStage(o),
                    amount: o['total'] as int?,
                    route: '/market/r/order/${o['id']}',
                    icon: Icons.storefront_outlined,
                  ),
              ],
              'No sales yet',
              'Orders for your listings land here.',
            ),
            _list(
              [
                for (final t in m.taskRecords().where((t) => t['role'] != 'arbiter'))
                  DealRow(
                    title: '${t['title']}',
                    subtitle: t['role'] == 'owner'
                        ? 'You posted · ${(t['applications'] as List? ?? const []).length} applied'
                        : 'For ${e.nameOf(t['owner'] as String)}',
                    stage: m.taskStage(t),
                    amount: t['reward'] as int?,
                    route: '/market/r/task/${Uri.encodeComponent(t['listing'] as String)}',
                    icon: Icons.task_alt_rounded,
                  ),
              ],
              'No tasks',
              'Tasks you post or apply to are tracked here.',
            ),
            _list(
              [
                for (final t in m.trades())
                  DealRow(
                    title: '${t['seller'] == e.me.id ? 'Sell' : 'Buy'} ${Coin.format(t['amount'] as int)} MNT',
                    subtitle: '${Exchange.birr(t['birr'] as int)} · ${t['method']} · ${e.nameOf((t['role'] == 'maker' ? t['taker'] : t['maker']) as String)}',
                    stage: m.tradeStage(t),
                    route: '/market/r/trade/${t['tid']}',
                    icon: Icons.currency_exchange_rounded,
                  ),
              ],
              'No trades',
              'Mentos-for-birr trades show here with their escrow.',
            ),
            _list(
              [
                for (final l in m.leases())
                  DealRow(
                    title: '${l['gb']} GB storage · ${l['days']} days',
                    subtitle: '${l['role'] == 'renter' ? 'Rented from' : 'Rented by'} ${e.nameOf((l['role'] == 'renter' ? l['provider'] : l['renter']) as String)}',
                    stage: m.leaseStage(l),
                    amount: l['total'] as int?,
                    route: '/market/r/lease/${l['lid']}',
                    icon: Icons.sd_storage_outlined,
                  ),
                for (final j in m.jobs())
                  DealRow(
                    title: jobTypes[j['type']] ?? '${j['type']}',
                    subtitle: '${j['role'] == 'renter' ? 'Run by' : 'Run for'} ${e.nameOf((j['role'] == 'renter' ? j['provider'] : j['renter']) as String)}',
                    stage: m.jobStage(j),
                    amount: j['price'] as int?,
                    route: '/market/r/job/${j['jid']}',
                    icon: Icons.bolt_rounded,
                  ),
              ],
              'No rentals',
              'Storage leases and compute jobs, from either side.',
            ),
            _list(
              [
                for (final l in m.mine().where((l) => !l.deleted))
                  _ListingRow(l),
              ],
              'Nothing listed',
              'Your listings are signed by you and travel to every phone on the network.',
            ),
            _list(
              [
                for (final c in cases)
                  DealRow(
                    title: c['kind'] == 'order' ? 'Order dispute' : 'Task dispute: ${c['title']}',
                    subtitle: c['kind'] == 'order'
                        ? '${e.nameOf(c['buyer'] as String)} vs ${e.nameOf(c['seller'] as String)}'
                        : '${e.nameOf(c['owner'] as String)} vs ${e.nameOf((c['worker'] ?? '') as String)}',
                    stage: c['kind'] == 'order' ? m.orderStage(c) : m.taskStage(c),
                    route: c['kind'] == 'order' ? '/market/r/order/${c['id']}' : '/market/r/task/${Uri.encodeComponent(c['listing'] as String)}',
                    icon: Icons.gavel_rounded,
                  ),
              ],
              'No cases',
              'When someone names you as their arbiter and a dispute opens, it comes here.',
            ),
          ],
        ),
      ),
    );
  }

  String _orderTitle(Rec o) {
    final lines = (o['lines'] as List).whereType<Map>().toList();
    return lines.length == 1 ? '${lines.first['title']}' : '${lines.first['title']} +${lines.length - 1}';
  }

  Widget _list(List<Widget> rows, String title, String body) => rows.isEmpty
      ? EmptyState(icon: Icons.inbox_outlined, title: title, body: body)
      : ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const Hairline(indent: Space.gutter + 52),
          itemBuilder: (_, i) => rows[i],
        );
}

class _ListingRow extends ConsumerWidget {
  const _ListingRow(this.l);
  final Listing l;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider)!;
    return InkWell(
      onTap: () => context.push('/market/l/${Uri.encodeComponent(l.id)}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.md),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 40,
                height: 40,
                child: l.cover == null
                    ? Container(color: p.raised, child: Icon(kindIcon(l.kind), size: 20, color: p.inkSoft))
                    : MarketImage(media: l.cover, sources: [m.me]),
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(p.ink)),
                  Text('${kindLabel(l.kind)} · revision ${l.rev} · refreshed ${timeAgo(l.ts)}', style: Txt.small(p.muted)),
                ],
              ),
            ),
            Pill.stage(context, l.expired ? 'expired' : l.status),
          ],
        ),
      ),
    );
  }
}
