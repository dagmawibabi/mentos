import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/market/market.dart';
import '../../net/pay/coin.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/spark.dart';
import '../../widgets/ui.dart';
import 'market_cards.dart';
import 'market_kit.dart';

class ListingScreen extends ConsumerWidget {
  const ListingScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(marketProvider);
    ref.watch(marketTickProvider);
    final l = m?.listing(id);
    if (m == null || l == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.cloud_sync_outlined,
          title: 'Not on this phone yet',
          body: 'Listings arrive as phones sync. Try again in a moment.',
        ),
      );
    }
    final mine = l.author == m.me;
    return Scaffold(
      appBar: AppBar(
        title: Text(kindLabel(l.kind)),
        actions: [
          if (mine && !l.deleted)
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'edit') context.push('/market/sell/${l.kind}?id=${Uri.encodeComponent(l.id)}');
                if (v == 'withdraw') {
                  final ok = await confirm(context,
                      title: 'Withdraw listing?',
                      body: 'Every phone that has it will hide it. Open orders and holds are not affected.',
                      action: 'Withdraw',
                      danger: true);
                  if (ok && context.mounted) await attempt(context, () => m.withdraw(l.id), done: 'Withdrawn');
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'withdraw', child: Text('Withdraw')),
              ],
            ),
        ],
      ),
      body: l.deleted
          ? const EmptyState(icon: Icons.remove_shopping_cart_outlined, title: 'Withdrawn', body: 'The author took this listing down.')
          : switch (l.kind) {
              Kinds.item => _ItemView(l),
              Kinds.task => _TaskView(l),
              Kinds.ad => _AdView(l),
              Kinds.resource => _ResourceView(l),
              Kinds.exchange => _ExchangeView(l),
              _ => _PackView(l),
            },
    );
  }
}

Widget _section(BuildContext context, String title, Widget child) => Padding(
  padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.gutter, 0),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title.toUpperCase(), style: Txt.label(context.pal.muted)),
      const SizedBox(height: Space.md),
      child,
    ],
  ),
);

class _Reviews extends ConsumerWidget {
  const _Reviews(this.subject);
  final String subject;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider)!;
    final e = ref.watch(engineProvider);
    final list = m.reviewsOf(subject);
    if (list.isEmpty) return Text('No reviews yet. Reviews only come from people who paid through escrow.', style: Txt.small(p.muted));
    return Column(
      children: [
        for (final r in list.take(8))
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stars(r.stars.toDouble(), size: 13),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (r.text.isNotEmpty) Text(r.text, style: Txt.small(p.ink)),
                      Text('${e.nameOf(r.author)} · ${r.role} · ${timeAgo(r.ts)}', style: Txt.mono(p.muted, size: 11)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// shop item

class _ItemView extends ConsumerStatefulWidget {
  const _ItemView(this.l);
  final Listing l;
  @override
  ConsumerState<_ItemView> createState() => _ItemViewState();
}

class _ItemViewState extends ConsumerState<_ItemView> {
  int _qty = 1;
  int _page = 0;
  final _options = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final l = widget.l;
    final m = ref.watch(marketProvider)!;
    final mine = l.author == m.me;
    final stock = l.body['stock'] as int? ?? -1;
    final soldOut = stock == 0 || l.status == 'sold out';
    final options = (l.body['options'] as List? ?? const []).whereType<Map>().toList();
    final delivery = (l.body['delivery'] as List).whereType<Map>().toList();
    final media = l.media.where((x) => x.isImage).toList();
    final ready = options.every((o) => _options.containsKey(o['name']));
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              AspectRatio(
                aspectRatio: 1.1,
                child: Stack(
                  children: [
                    PageView.builder(
                      itemCount: math.max(1, media.length),
                      onPageChanged: (i) => setState(() => _page = i),
                      itemBuilder: (_, i) => MarketImage(
                        media: media.isEmpty ? null : media[i],
                        sources: [l.author, m.via(l.id) ?? ''],
                        icon: Icons.shopping_bag_outlined,
                      ),
                    ),
                    if (media.length > 1)
                      Positioned(
                        bottom: 12,
                        left: 0,
                        right: 0,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < media.length; i++)
                              AnimatedContainer(
                                duration: Motion.fast,
                                margin: const EdgeInsets.symmetric(horizontal: 3),
                                width: i == _page ? 18 : 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: i == _page ? .95 : .5),
                                  borderRadius: BorderRadius.circular(Radii.pill),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        Pill(shopCategories[l.category] ?? 'Other', fg: p.inkSoft, bg: p.raised, dot: false),
                        Pill(conditions[l.body['condition']] ?? '', fg: p.inkSoft, bg: p.raised, dot: false),
                        if (soldOut)
                          Pill('Sold out', fg: p.danger, bg: p.dangerSoft)
                        else if (stock > 0)
                          Pill('$stock in stock', fg: p.accent, bg: p.accentSoft),
                        if ('${l.body['location'] ?? ''}'.isNotEmpty)
                          Pill('${l.body['location']}', fg: p.inkSoft, bg: p.raised, icon: Icons.place_outlined),
                      ],
                    ),
                    const SizedBox(height: Space.md),
                    Text(l.title, style: Txt.title(p.ink)),
                    const SizedBox(height: Space.sm),
                    Amount(l.price, size: 30, color: p.ink),
                    if (l.about.isNotEmpty) ...[
                      const SizedBox(height: Space.md),
                      Text(l.about, style: Txt.body(p.inkSoft)),
                    ],
                  ],
                ),
              ),
              for (final o in options)
                _section(
                  context,
                  '${o['name']}',
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final v in (o['values'] as List).whereType<String>())
                        ChoiceChip(
                          label: Text(v),
                          selected: _options[o['name']] == v,
                          onSelected: (_) => setState(() => _options['${o['name']}'] = v),
                        ),
                    ],
                  ),
                ),
              _section(
                context,
                'Delivery',
                Column(
                  children: [
                    for (final d in delivery)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Space.sm),
                        child: Row(
                          children: [
                            Icon(
                              switch (d['kind']) {
                                'ship' => Icons.local_shipping_outlined,
                                'pickup' => Icons.storefront_outlined,
                                'meet' => Icons.handshake_outlined,
                                _ => Icons.bolt_rounded,
                              },
                              size: 20,
                              color: p.inkSoft,
                            ),
                            const SizedBox(width: Space.md),
                            Expanded(
                              child: Text(
                                '${d['label']}${(d['days'] as int) > 0 ? ' · ${d['days']} days' : ''}',
                                style: Txt.body(p.ink),
                              ),
                            ),
                            (d['price'] as int) == 0
                                ? Text('Free', style: Txt.bodyStrong(p.accent))
                                : Amount(d['price'] as int, size: 14),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              _section(
                context,
                'Buyer protection',
                MCard(
                  color: p.accentSoft,
                  border: false,
                  child: Row(
                    children: [
                      Icon(Icons.shield_outlined, color: p.accent),
                      const SizedBox(width: Space.md),
                      Expanded(
                        child: Text(
                          'You pay into escrow, not to the seller. They are paid when you confirm, or automatically '
                          '${l.body['holdDays']} days after delivery if you do not open a dispute.',
                          style: Txt.small(p.inkSoft),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _section(context, 'Seller', TraderChip(l.author, onTap: () => context.push('/u/${l.author}'))),
              _section(context, 'Reviews', _Reviews(l.author)),
              if (mine) _section(context, 'Your orders', _SellerOrders(l.id)),
              const SizedBox(height: Space.xxl),
            ],
          ),
        ),
        if (!mine && !ready && !soldOut)
          Container(
            width: double.infinity,
            color: MarketColors(p).amberSoft,
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.sm),
            child: Text(
              'Choose ${options.where((o) => !_options.containsKey(o['name'])).map((o) => '${o['name']}'.toLowerCase()).join(' and ')} to buy',
              style: Txt.small(p.inkSoft),
            ),
          ),
        if (!mine)
          _BuyBar(
            children: [
              _Stepper(
                value: _qty,
                max: stock < 0 ? 99 : math.max(1, stock),
                onChanged: (v) => setState(() => _qty = v),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: OutlinedButton(
                  onPressed: soldOut || !ready
                      ? null
                      : () {
                          m.addToCart(l, qty: _qty, options: Map.of(_options));
                          toast(context, 'Added to cart');
                        },
                  child: const Text('Add to cart'),
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: FilledButton(
                  onPressed: soldOut || !ready
                      ? null
                      : () {
                          m.addToCart(l, qty: _qty, options: Map.of(_options));
                          context.push('/market/cart?seller=${l.author}');
                        },
                  child: const Text('Buy now'),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _SellerOrders extends ConsumerWidget {
  const _SellerOrders(this.listingId);
  final String listingId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider)!;
    final orders = m.orders(role: 'seller').where((o) =>
        (o['lines'] as List).whereType<Map>().any((x) => x['listing'] == listingId)).toList();
    if (orders.isEmpty) return Text('No orders yet.', style: Txt.small(p.muted));
    return Column(
      children: [
        for (final o in orders)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(ref.read(engineProvider).nameOf(o['buyer'] as String)),
            subtitle: Text(timeAgo(o['created'] as int? ?? 0)),
            trailing: Pill.stage(context, m.orderStage(o)),
            onTap: () => context.push('/market/r/order/${o['id']}'),
          ),
      ],
    );
  }
}

class _BuyBar extends StatelessWidget {
  const _BuyBar({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      decoration: BoxDecoration(color: p.surface, border: Border(top: BorderSide(color: p.line))),
      padding: EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.md + MediaQuery.of(context).padding.bottom),
      child: Row(children: children),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.max, required this.onChanged});
  final int value;
  final int max;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconBtn(Icons.remove_rounded, size: 18, onTap: value > 1 ? () => onChanged(value - 1) : null),
          Text('$value', style: Txt.bodyStrong(p.ink)),
          IconBtn(Icons.add_rounded, size: 18, onTap: value < max ? () => onChanged(value + 1) : null),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// task

class _TaskView extends ConsumerWidget {
  const _TaskView(this.l);
  final Listing l;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final mc = MarketColors(p);
    final m = ref.watch(marketProvider)!;
    final mine = l.author == m.me;
    final rec = m.taskRecord(l.id);
    final criteria = (l.body['criteria'] as List? ?? const []).whereType<String>().toList();
    final evidence = (l.body['evidence'] as List? ?? const []).whereType<String>().toList();
    final deadline = l.body['deadline'] as int;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: Space.xxl),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
                child: Container(
                  padding: const EdgeInsets.all(Space.lg),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: LinearGradient(colors: [mc.amberSoft, p.surface], begin: Alignment.topLeft, end: Alignment.bottomRight),
                    border: Border.all(color: p.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Pill(taskCategories[l.category] ?? 'Task', fg: mc.amber, bg: p.surface, dot: false),
                          const SizedBox(width: 6),
                          Pill.stage(context, l.status),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      Text(l.title, style: Txt.title(p.ink)),
                      const SizedBox(height: Space.lg),
                      FactRow([
                        Fact('Reward', '', child: Amount(l.price, size: 24, color: p.accent)),
                        Fact('Deadline', timeLeft(deadline)),
                        Fact('Applicants', '${l.body['applicants'] ?? 0}'),
                      ]),
                    ],
                  ),
                ),
              ),
              if (l.about.isNotEmpty) _section(context, 'Brief', Text(l.about, style: Txt.body(p.inkSoft))),
              _section(
                context,
                'Done means',
                Column(
                  children: [
                    for (final c in criteria)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Space.sm),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.check_circle_outline_rounded, size: 20, color: p.accent),
                            const SizedBox(width: Space.md),
                            Expanded(child: Text(c, style: Txt.body(p.ink))),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              _section(
                context,
                'Evidence to submit',
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final x in evidence) Pill(evidenceKinds[x] ?? x, fg: p.inkSoft, bg: p.raised, dot: false)],
                ),
              ),
              _section(
                context,
                'How payment works',
                Text(
                  'When the owner picks you, the reward moves into escrow for you. Approve releases it. '
                  'If your submission is not reviewed within ${l.body['reviewDays']} days after the deadline, you can claim it.',
                  style: Txt.small(p.muted),
                ),
              ),
              _section(context, 'Posted by', TraderChip(l.author, onTap: () => context.push('/u/${l.author}'))),
            ],
          ),
        ),
        _BuyBar(
          children: [
            Expanded(
              child: mine || rec != null
                  ? FilledButton(
                      onPressed: () => context.push('/market/r/task/${Uri.encodeComponent(l.id)}'),
                      child: Text(mine ? 'Manage task' : 'Open your work'),
                    )
                  : FilledButton(
                      onPressed: l.status == 'open' || l.status == 'active'
                          ? () async {
                              final pitch = await prompt(context,
                                  title: 'Apply',
                                  body: 'Tell them why you are a good fit.',
                                  hint: 'I can do this because…',
                                  action: 'Send application',
                                  maxLength: 1000,
                                  multiline: true,
                                  minLines: 3,
                                  allowEmpty: false);
                              if (pitch == null || !context.mounted) return;
                              await attempt(context, () => m.apply(l, pitch), done: 'Application sent');
                            }
                          : null,
                      child: const Text('Apply'),
                    ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// ad campaign

class _AdView extends ConsumerWidget {
  const _AdView(this.l);
  final Listing l;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final mc = MarketColors(p);
    final m = ref.watch(marketProvider)!;
    final mine = l.author == m.me;
    final rec = m.campaign(l.id);
    final budget = l.body['budget'] as int;
    final spent = rec['spent'] as int;
    final views = rec['views'] as int, clicks = rec['clicks'] as int;
    final days = (rec['days'] as Map).cast<String, dynamic>();
    final keys = days.keys.toList()..sort();
    final series = [for (final k in keys) ((days[k] as Map)['v'] as int).toDouble()];
    return ListView(
      padding: const EdgeInsets.only(bottom: Space.xxl),
      children: [
        const SizedBox(height: Space.sm),
        SponsoredCard(l, preview: true),
        if (mine) ...[
          _section(
            context,
            'Performance',
            MCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FactRow([
                    Fact('Views', '$views'),
                    Fact('Clicks', '$clicks'),
                    Fact('Click rate', views == 0 ? '—' : '${(clicks * 100 / views).toStringAsFixed(1)}%'),
                  ]),
                  const SizedBox(height: Space.lg),
                  FactRow([
                    Fact('Reach', '${rec['viewers']}'),
                    Fact('Spent', '', child: Amount(spent, size: 15)),
                    Fact('Budget', '', child: Amount(budget, size: 15)),
                  ]),
                  const SizedBox(height: Space.lg),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    child: LinearProgressIndicator(
                      value: budget == 0 ? 0 : spent / budget,
                      minHeight: 8,
                      color: mc.violet,
                      backgroundColor: p.raised,
                    ),
                  ),
                  if (series.length > 1) ...[
                    const SizedBox(height: Space.lg),
                    Text('VIEWS PER DAY', style: Txt.label(p.muted)),
                    const SizedBox(height: Space.sm),
                    SparkLine(points: series, height: 56),
                  ],
                ],
              ),
            ),
          ),
          _section(
            context,
            'Pricing',
            Text(
              '${Coin.format(l.body['perView'] as int)} per view · ${Coin.format(l.body['perClick'] as int)} per click · '
              '${l.body['viewerShare']}% to the viewer, the rest to the carrier · '
              'up to ${l.body['dailyCap']} views a day · ends ${timeAgo(l.body['until'] as int)}',
              style: Txt.small(p.inkSoft),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.gutter, 0),
            child: Row(
              children: [
                if (l.status == 'active')
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => attempt(context, () => m.setAdStatus(l.id, 'paused'), done: 'Paused'),
                      child: const Text('Pause'),
                    ),
                  ),
                if (l.status == 'paused')
                  Expanded(
                    child: FilledButton(
                      onPressed: () => attempt(context, () => m.setAdStatus(l.id, 'active'), done: 'Running'),
                      child: const Text('Resume'),
                    ),
                  ),
                if (l.status != 'ended') ...[
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => attempt(context, () => m.setAdStatus(l.id, 'ended'), done: 'Ended'),
                      child: const Text('End campaign'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ] else
          _section(context, 'Advertiser', TraderChip(l.author, onTap: () => context.push('/u/${l.author}'))),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// resources

class _ResourceView extends ConsumerWidget {
  const _ResourceView(this.l);
  final Listing l;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final mc = MarketColors(p);
    final m = ref.watch(marketProvider)!;
    final mine = l.author == m.me;
    final bench = (l.body['bench'] as Map?)?.cast<String, dynamic>() ?? const {};
    final net = (bench['net'] as Map?)?.cast<String, dynamic>() ?? const {};
    final storage = (l.body['storage'] as Map?)?.cast<String, dynamic>();
    final compute = (l.body['compute'] as Map?)?.cast<String, dynamic>();
    return ListView(
      padding: const EdgeInsets.only(bottom: Space.xxl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
          child: Text(l.title, style: Txt.title(p.ink)),
        ),
        if (l.about.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            child: Text(l.about, style: Txt.body(p.inkSoft)),
          ),
        _section(
          context,
          'Measured on the device',
          MCard(
            child: Column(
              children: [
                _BenchBar('Compute score', '${bench['score'] ?? '—'}', ((bench['score'] as int? ?? 0) / 60000).clamp(0, 1).toDouble(), mc.blue),
                _BenchBar('Single core', '${bench['cpu1'] ?? '—'} MB/s', ((bench['cpu1'] as int? ?? 0) / 2000).clamp(0, 1).toDouble(), mc.blue),
                _BenchBar('Free storage', '${bench['freeGb'] ?? '—'} GB', ((bench['freeGb'] as int? ?? 0) / 512).clamp(0, 1).toDouble(), p.accent),
                _BenchBar('Disk write', '${bench['diskW'] ?? '—'} MB/s', ((bench['diskW'] as int? ?? 0) / 1500).clamp(0, 1).toDouble(), p.accent),
                _BenchBar('Memory', bench['ramMb'] == null ? '—' : '${((bench['ramMb'] as int) / 1024).toStringAsFixed(1)} GB',
                    ((bench['ramMb'] as int? ?? 0) / 16384).clamp(0, 1).toDouble(), mc.violet),
                const SizedBox(height: Space.sm),
                Text(
                  [
                    '${bench['platform'] ?? ''}',
                    if (bench['cores'] != null) '${bench['cores']} cores',
                    if (net['mode'] != null) 'network ${net['mode']}',
                    if (net['relayMs'] != null) 'relay ${net['relayMs']} ms',
                    if (bench['ts'] != null) 'measured ${timeAgo(bench['ts'] as int)} ago',
                  ].join(' · '),
                  style: Txt.mono(p.muted, size: 11),
                ),
              ],
            ),
          ),
        ),
        if (storage != null)
          _section(
            context,
            'Storage',
            MCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.sd_storage_outlined, color: p.accent),
                      const SizedBox(width: Space.sm),
                      Expanded(child: Text('Up to ${storage['gb']} GB', style: Txt.bodyStrong(p.ink))),
                      Amount(storage['perGbDay'] as int, size: 15),
                      Text(' / GB / day', style: Txt.mono(p.muted, size: 11)),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  Text(
                    'Files are encrypted on your phone first; the provider never has the key. '
                    'Your phone audits them every 12 hours and pays only for days that pass.',
                    style: Txt.small(p.muted),
                  ),
                  if (!mine) ...[
                    const SizedBox(height: Space.md),
                    FilledButton.icon(
                      onPressed: () => _rent(context, ref, l, storage),
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('Rent storage'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (compute != null)
          _section(
            context,
            'Compute',
            MCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final j in (compute['jobs'] as List).whereType<String>())
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.sm),
                      child: Row(
                        children: [
                          Icon(Icons.bolt_rounded, size: 18, color: mc.blue),
                          const SizedBox(width: Space.sm),
                          Expanded(child: Text(jobTypes[j] ?? j, style: Txt.body(p.ink))),
                        ],
                      ),
                    ),
                  Text(
                    '${Coin.format(compute['perUnit'] as int)} per unit (1 MB of input, or one difficulty step) · files up to ${compute['maxMb']} MB. '
                    'Your phone checks each result before paying.',
                    style: Txt.small(p.muted),
                  ),
                  if (!mine) ...[
                    const SizedBox(height: Space.md),
                    FilledButton.icon(
                      onPressed: () => _job(context, ref, l, compute),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Run a job'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        _section(context, 'Provider', TraderChip(l.author, onTap: () => context.push('/u/${l.author}'))),
        _section(context, 'Reviews', _Reviews(l.author)),
      ],
    );
  }

  Future<void> _rent(BuildContext context, WidgetRef ref, Listing l, Map<String, dynamic> storage) async {
    final m = ref.read(marketProvider)!;
    final maxGb = storage['gb'] as int;
    var gb = math.min(5, maxGb);
    var days = 30;
    final ok = await showInputSheet<bool>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          final p = ctx.pal;
          final cost = m.leaseCost(gb, days, storage['perGbDay'] as int);
          final enough = (ref.read(coinProvider)?.balance() ?? 0) >= cost;
          return InputSheet(
            title: 'Rent storage',
            body: 'The full term goes into escrow and is released day by day as audits pass.',
            action: 'Pay ${Coin.format(cost)} into escrow',
            enabled: enough,
            onAction: () => Navigator.pop(ctx, true),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$gb GB', style: Txt.heading(p.ink)),
                Slider(value: gb.toDouble(), min: 1, max: maxGb.toDouble(), divisions: math.max(1, maxGb - 1),
                    onChanged: (v) => set(() => gb = v.round())),
                Text('$days days', style: Txt.heading(p.ink)),
                Slider(value: days.toDouble(), min: 1, max: 365, divisions: 364, onChanged: (v) => set(() => days = v.round())),
                if (!enough) Text('Your balance does not cover this.', style: Txt.small(p.danger)),
              ],
            ),
          );
        },
      ),
    );
    if (ok != true || !context.mounted) return;
    await attempt(context, () async {
      final r = await m.rentStorage(l, gb: gb, days: days);
      if (context.mounted) context.push('/market/r/lease/${r['lid']}');
    });
  }

  Future<void> _job(BuildContext context, WidgetRef ref, Listing l, Map<String, dynamic> compute) async {
    final m = ref.read(marketProvider)!;
    final jobs = (compute['jobs'] as List).whereType<String>().toList();
    var type = jobs.first;
    var bits = 18;
    var maxSide = 1280;
    String? path;
    var size = 0;
    final ok = await showInputSheet<bool>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          final p = ctx.pal;
          final units = m.jobUnits(type, size, {'bits': bits});
          final price = units * (compute['perUnit'] as int);
          final needsFile = type != 'pow';
          return InputSheet(
            title: 'Run a job',
            body: 'The price goes into escrow. If the result fails your phone’s check, payment is disputed.',
            action: 'Pay ${Coin.format(price)} and send',
            enabled: !needsFile || path != null,
            onAction: () => Navigator.pop(ctx, true),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final j in jobs)
                      ChoiceChip(label: Text(jobTypes[j] ?? j), selected: type == j, onSelected: (_) => set(() => type = j)),
                  ],
                ),
                const SizedBox(height: Space.md),
                if (type == 'pow') ...[
                  Text('Difficulty: $bits bits', style: Txt.bodyStrong(p.ink)),
                  Slider(value: bits.toDouble(), min: 12, max: 28, divisions: 16, onChanged: (v) => set(() => bits = v.round())),
                  Text('Each extra bit doubles the work. A stamp proves effort, useful against spam.', style: Txt.small(p.muted)),
                ] else ...[
                  OutlinedButton.icon(
                    onPressed: () async {
                      final r = await FilePicker.pickFiles(type: type == 'image' ? FileType.image : FileType.any);
                      final f = r.singleOrNull;
                      if (f?.path == null) return;
                      final picked = f!.path!;
                      final length = await File(picked).length();
                      set(() {
                        path = picked;
                        size = length;
                      });
                    },
                    icon: const Icon(Icons.attach_file_rounded),
                    label: Text(path == null ? 'Choose a file' : '${path!.split(RegExp(r'[\\/]')).last} · ${bytes(size)}'),
                  ),
                  if (type == 'image') ...[
                    const SizedBox(height: Space.md),
                    Text('Longest side: $maxSide px', style: Txt.bodyStrong(p.ink)),
                    Slider(value: maxSide.toDouble(), min: 320, max: 4096, divisions: 30, onChanged: (v) => set(() => maxSide = v.round())),
                  ],
                ],
              ],
            ),
          );
        },
      ),
    );
    if (ok != true || !context.mounted) return;
    await attempt(context, () async {
      final r = await m.submitJob(
        l,
        type,
        input: path == null ? null : File(path!),
        params: switch (type) {
          'pow' => {'challenge': toHexChallenge(), 'bits': bits},
          'image' => {'max': maxSide, 'q': 80},
          _ => <String, dynamic>{},
        },
      );
      if (context.mounted) context.push('/market/r/job/${r['jid']}');
    });
  }
}

String toHexChallenge() => 'mentos-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

class _BenchBar extends StatelessWidget {
  const _BenchBar(this.label, this.value, this.fraction, this.color);
  final String label;
  final String value;
  final double fraction;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: Txt.small(p.inkSoft))),
              Text(value, style: Txt.mono(p.ink, size: 12, w: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(value: fraction, minHeight: 6, color: color, backgroundColor: p.raised),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// exchange

class _ExchangeView extends ConsumerWidget {
  const _ExchangeView(this.l);
  final Listing l;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider)!;
    final mine = l.author == m.me;
    final sells = l.body['side'] == 'sell';
    final rate = l.body['rate'] as int;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: Space.xxl),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
                child: MCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Pill(sells ? 'Selling Mentos' : 'Buying Mentos', fg: sells ? p.accent : p.danger, bg: sells ? p.accentSoft : p.dangerSoft),
                      const SizedBox(height: Space.md),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text((rate / 100).toStringAsFixed(2), style: Txt.display(p.ink)),
                          const SizedBox(width: 6),
                          Text('birr per Mentos', style: Txt.small(p.muted)),
                        ],
                      ),
                      const SizedBox(height: Space.lg),
                      FactRow([
                        Fact('Minimum', '${Coin.format(l.body['min'] as int)} MNT'),
                        Fact('Maximum', '${Coin.format(l.body['max'] as int)} MNT'),
                        Fact('Pay within', '${l.body['windowMins']} min'),
                      ]),
                    ],
                  ),
                ),
              ),
              _section(
                context,
                'Payment methods',
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final x in (l.body['methods'] as List).whereType<String>()) Pill(x, fg: p.inkSoft, bg: p.raised, dot: false),
                ]),
              ),
              if ('${l.body['terms'] ?? ''}'.isNotEmpty) _section(context, 'Terms', Text('${l.body['terms']}', style: Txt.body(p.inkSoft))),
              _section(
                context,
                'How it stays safe',
                Text(
                  sells
                      ? 'They lock the Mentos in escrow for you first. Only pay birr once the lock appears in the trade. '
                          'If they never release after you paid, you can claim the coins when the window closes.'
                      : 'You lock the Mentos for them. Release only once the birr is in your account. '
                          'If it never arrives, dispute before the window closes.',
                  style: Txt.small(p.muted),
                ),
              ),
              _section(context, 'Trader', TraderChip(l.author, onTap: () => context.push('/u/${l.author}'))),
              _section(context, 'Reviews', _Reviews(l.author)),
            ],
          ),
        ),
        if (!mine)
          _BuyBar(children: [
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: sells ? p.accent : p.danger, foregroundColor: sells ? p.accentInk : Colors.white),
                onPressed: () => _trade(context, ref),
                child: Text(sells ? 'Buy Mentos' : 'Sell Mentos'),
              ),
            ),
          ]),
      ],
    );
  }

  Future<void> _trade(BuildContext context, WidgetRef ref) async {
    final m = ref.read(marketProvider)!;
    final methods = (l.body['methods'] as List).whereType<String>().toList();
    final ctrl = TextEditingController();
    var method = methods.first;
    final sells = l.body['side'] == 'sell';
    final ok = await showInputSheet<bool>(
      context,
      (ctx) => StatefulBuilder(builder: (ctx, set) {
        final p = ctx.pal;
        final amount = Coin.parse(ctrl.text) ?? 0;
        final min = l.body['min'] as int, max = l.body['max'] as int;
        final fits = amount >= min && amount <= max;
        final balanceOk = sells || (ref.read(coinProvider)?.balance() ?? 0) >= amount;
        return InputSheet(
          title: sells ? 'Buy Mentos' : 'Sell Mentos',
          action: fits ? 'Open trade' : 'Enter an amount',
          enabled: fits && balanceOk,
          onAction: () => Navigator.pop(ctx, true),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Mentos', helperText: 'Between ${Coin.format(min)} and ${Coin.format(max)}'),
                onChanged: (_) => set(() {}),
              ),
              const SizedBox(height: Space.md),
              Text(
                'You ${sells ? 'pay' : 'receive'} ${Exchange.birr(Exchange.birrFor(amount, l.body['rate'] as int))}',
                style: Txt.heading(p.ink),
              ),
              if (!balanceOk) Text('Not enough Mentos to lock.', style: Txt.small(p.danger)),
              const SizedBox(height: Space.md),
              Wrap(spacing: 8, children: [
                for (final x in methods) ChoiceChip(label: Text(x), selected: x == method, onSelected: (_) => set(() => method = x)),
              ]),
            ],
          ),
        );
      }),
    );
    if (ok != true || !context.mounted) return;
    final amount = Coin.parse(ctrl.text)!;
    await attempt(context, () async {
      final r = await m.openTrade(l, amount, method);
      if (context.mounted) context.push('/market/r/trade/${r['tid']}');
    });
  }
}

// ---------------------------------------------------------------------------
// plugin pack

class _PackView extends ConsumerWidget {
  const _PackView(this.l);
  final Listing l;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider)!;
    final e = ref.watch(engineProvider);
    final pack = (l.body['pack'] as Map?) ?? const {};
    final installed = e.pluginInstalled(l.id);
    return ListView(
      padding: const EdgeInsets.all(Space.gutter),
      children: [
        Text(l.title, style: Txt.title(p.ink)),
        const SizedBox(height: Space.sm),
        Text(l.about, style: Txt.body(p.inkSoft)),
        const SizedBox(height: Space.lg),
        MCard(
          child: switch (l.body['plugin']) {
            'stickers' => Text(((pack['emoji'] as List?) ?? const []).join('  '), style: const TextStyle(fontSize: 30)),
            'phrases' => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final x in (pack['lines'] as List? ?? const [])) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('“$x”', style: Txt.body(p.ink)))],
            ),
            _ => Text('Accent colour: ${pack['accent']}', style: Txt.body(p.ink)),
          },
        ),
        const SizedBox(height: Space.lg),
        TraderChip(l.author),
        const SizedBox(height: Space.xl),
        FilledButton(
          onPressed: installed
              ? () {
                  e.removePlugin(l.id);
                  toast(context, 'Removed');
                }
              : () => attempt(context, () => m.getPack(l), done: 'Installed'),
          child: Text(installed ? 'Remove' : (l.price == 0 ? 'Install' : 'Buy for ${Coin.format(l.price)}')),
        ),
      ],
    );
  }
}
