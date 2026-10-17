import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/market/market.dart';
import '../../net/pay/coin.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import '../wallet/coin_wallet_screen.dart';
import 'market_cards.dart';
import 'market_kit.dart';

enum MarketTab { shop, tasks, exchange, resources, ads, plugins }

extension on MarketTab {
  String get label => switch (this) {
    MarketTab.shop => 'Shop',
    MarketTab.tasks => 'Tasks',
    MarketTab.exchange => 'Exchange',
    MarketTab.resources => 'Resources',
    MarketTab.ads => 'Ads',
    MarketTab.plugins => 'Plugins',
  };
  IconData get icon => switch (this) {
    MarketTab.shop => Icons.storefront_outlined,
    MarketTab.tasks => Icons.task_alt_rounded,
    MarketTab.exchange => Icons.currency_exchange_rounded,
    MarketTab.resources => Icons.memory_rounded,
    MarketTab.ads => Icons.campaign_outlined,
    MarketTab.plugins => Icons.extension_outlined,
  };
}

/// The marketplace: one place for goods, work, ads, spare phone capacity,
/// Mentos-for-birr trades and plugins, all paid through escrow.
class MarketScreen extends ConsumerStatefulWidget {
  const MarketScreen({super.key, this.initial = MarketTab.shop});
  final MarketTab initial;

  @override
  ConsumerState<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends ConsumerState<MarketScreen> {
  late MarketTab _tab = widget.initial;
  final _search = TextEditingController();
  String _category = '';
  String _sort = 'new';
  bool _buySide = true;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final m = ref.watch(marketProvider);
    ref.watch(marketTickProvider);
    if (m == null) return const Scaffold(body: Loading());
    final q = _search.text.trim().toLowerCase();
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: const Text('Market'),
            actions: [
              const _BalanceChip(),
              IconBtn(Icons.receipt_long_outlined, tooltip: 'My market', onTap: () => context.push('/market/hub')),
              _CartButton(count: m.cartCount),
              const SizedBox(width: 8),
            ],
          ),
          const SliverToBoxAdapter(child: _EscrowBanner()),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search the network',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => setState(_search.clear),
                        ),
                  filled: true,
                  fillColor: p.raised,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
              ),
            ),
          ),
          SliverPersistentHeader(pinned: true, delegate: _TabsHeader(tab: _tab, onTab: (t) => setState(() => _tab = t), bg: p.bg)),
          ...switch (_tab) {
            MarketTab.shop => _shop(m, q),
            MarketTab.tasks => _tasks(m, q),
            MarketTab.exchange => _exchange(m, q),
            MarketTab.resources => _resources(m, q),
            MarketTab.ads => _ads(m, q),
            MarketTab.plugins => _plugins(m, q),
          },
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
      floatingActionButton: _tab == MarketTab.plugins
          ? null
          : FloatingActionButton.extended(
              heroTag: 'market-sell',
              onPressed: () => context.push('/market/sell/${_sellKind()}'),
              icon: const Icon(Icons.add_rounded),
              label: Text(switch (_tab) {
                MarketTab.shop => 'Sell',
                MarketTab.tasks => 'Post a task',
                MarketTab.exchange => 'New offer',
                MarketTab.resources => 'Offer this phone',
                MarketTab.ads => 'Promote',
                MarketTab.plugins => '',
              }),
            ),
    );
  }

  String _sellKind() => switch (_tab) {
    MarketTab.shop => Kinds.item,
    MarketTab.tasks => Kinds.task,
    MarketTab.exchange => Kinds.exchange,
    MarketTab.resources => Kinds.resource,
    MarketTab.ads => Kinds.ad,
    MarketTab.plugins => Kinds.plugin,
  };

  List<Listing> _find(Market m, String kind, String q) => [
    for (final l in m.listings(kind: kind))
      if (!l.deleted && (q.isEmpty || l.haystack.contains(q))) l,
  ];

  Widget _empty(String title, String body, {IconData icon = Icons.travel_explore_rounded}) =>
      SliverToBoxAdapter(child: EmptyState(icon: icon, title: title, body: body, compact: true));

  // ---------------------------------------------------------------------------

  List<Widget> _shop(Market m, String q) {
    final p = context.pal;
    var items = _find(m, Kinds.item, q).where((l) => _category.isEmpty || l.category == _category).toList();
    final reps = {for (final l in items) l.author: m.reputation(l.author)};
    items.sort((a, b) => switch (_sort) {
      'low' => a.price.compareTo(b.price),
      'high' => b.price.compareTo(a.price),
      'top' => reps[b.author]!.stars.compareTo(reps[a.author]!.stars),
      _ => b.ts.compareTo(a.ts),
    });
    items = items.where((l) => l.status != 'sold out' || q.isNotEmpty).toList();
    final fresh = q.isEmpty && _category.isEmpty
        ? ([...items.where((l) => l.cover != null)]..sort((a, b) => b.ts.compareTo(a.ts))).take(6).toList()
        : const <Listing>[];
    return [
      if (fresh.length >= 2) ...[
        const SliverToBoxAdapter(child: MHeader('Fresh on the network', subtitle: 'Just listed by people near and far')),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 200,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              itemCount: fresh.length,
              separatorBuilder: (_, _) => const SizedBox(width: Space.md),
              itemBuilder: (_, i) => FeatureCard(fresh[i]),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: MHeader('Browse')),
      ] else
        const SliverToBoxAdapter(child: SizedBox(height: Space.sm)),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 4),
            children: [
              _chip('All', _category.isEmpty, () => setState(() => _category = '')),
              for (final c in shopCategories.entries) _chip(c.value, _category == c.key, () => setState(() => _category = c.key)),
            ],
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.sm, Space.md),
          child: Row(
            children: [
              Text('${items.length} ${items.length == 1 ? 'item' : 'items'}', style: Txt.small(p.muted)),
              const Spacer(),
              PopupMenuButton<String>(
                initialValue: _sort,
                onSelected: (v) => setState(() => _sort = v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'new', child: Text('Newest')),
                  PopupMenuItem(value: 'low', child: Text('Price: low to high')),
                  PopupMenuItem(value: 'high', child: Text('Price: high to low')),
                  PopupMenuItem(value: 'top', child: Text('Best rated sellers')),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Icon(Icons.sort_rounded, size: 18, color: p.inkSoft),
                      const SizedBox(width: 4),
                      Text(
                        switch (_sort) {
                          'low' => 'Lowest price',
                          'high' => 'Highest price',
                          'top' => 'Best rated',
                          _ => 'Newest',
                        },
                        style: Txt.small(p.inkSoft),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      if (items.isEmpty)
        _empty(
          q.isEmpty ? 'Nothing for sale yet' : 'No match',
          q.isEmpty
              ? 'Listings arrive from every phone on the network. Be the first: tap Sell.'
              : 'Try another word or category.',
          icon: Icons.storefront_outlined,
        )
      else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              mainAxisSpacing: Space.xl,
              crossAxisSpacing: Space.md,
              childAspectRatio: .62,
            ),
            delegate: SliverChildBuilderDelegate((_, i) => ProductCard(items[i]), childCount: items.length),
          ),
        ),
    ];
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(label: Text(label), selected: on, onSelected: (_) => onTap(), showCheckmark: false),
  );

  List<Widget> _tasks(Market m, String q) {
    final open = _find(m, Kinds.task, q).where((l) => l.status == 'open' || l.status == 'active').toList()
      ..sort((a, b) => b.price.compareTo(a.price));
    final mine = m.taskRecords();
    return [
      if (mine.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: MCard(
              onTap: () => context.push('/market/hub?tab=tasks'),
              child: Row(
                children: [
                  Icon(Icons.work_history_outlined, color: MarketColors(context.pal).amber),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Text('${mine.length} ${mine.length == 1 ? 'task' : 'tasks'} you posted or work on',
                        style: Txt.bodyStrong(context.pal.ink)),
                  ),
                  Icon(Icons.chevron_right_rounded, color: context.pal.faint),
                ],
              ),
            ),
          ),
        ),
      const SliverToBoxAdapter(
        child: MHeader('Open tasks', subtitle: 'Rewards sit in escrow from the moment someone is picked'),
      ),
      if (open.isEmpty)
        _empty('No open tasks', 'Post one: describe the work, set a reward and the evidence you need.',
            icon: Icons.task_alt_rounded)
      else
        SliverList.builder(itemCount: open.length, itemBuilder: (_, i) => TaskCard(open[i])),
    ];
  }

  List<Widget> _exchange(Market m, String q) {
    final p = context.pal;
    final offers = _find(m, Kinds.exchange, q).where((l) => l.body['side'] == (_buySide ? 'sell' : 'buy')).toList()
      ..sort((a, b) => _buySide
          ? (a.body['rate'] as int).compareTo(b.body['rate'] as int)
          : (b.body['rate'] as int).compareTo(a.body['rate'] as int));
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
          child: Segmented<bool>(
            value: _buySide,
            options: const {true: 'Buy Mentos', false: 'Sell Mentos'},
            onChanged: (v) => setState(() => _buySide = v),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
          child: Text(
            _buySide
                ? 'The seller locks Mentos in escrow before you pay birr. You only pay after the lock shows up.'
                : 'You lock Mentos for the buyer, they pay you birr, and you release once it arrives.',
            style: Txt.small(p.muted),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: Space.md)),
      if (offers.isEmpty)
        _empty('No offers yet', 'Post an offer with your rate, limits and how you take birr.',
            icon: Icons.currency_exchange_rounded)
      else
        SliverList.builder(itemCount: offers.length, itemBuilder: (_, i) => OfferRow(offers[i])),
    ];
  }

  List<Widget> _resources(Market m, String q) {
    final p = context.pal;
    final mc = MarketColors(p);
    final bench = m.lastBench;
    final providers = _find(m, Kinds.resource, q);
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
          child: Container(
            padding: const EdgeInsets.all(Space.lg),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                colors: [mc.blueSoft, p.surface],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: p.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.speed_rounded, color: mc.blue),
                    const SizedBox(width: Space.sm),
                    Text('This phone', style: Txt.heading(p.ink)),
                    const Spacer(),
                    if (bench != null) Text('score ${bench['score']}', style: Txt.mono(mc.blue, size: 12, w: FontWeight.w500)),
                  ],
                ),
                const SizedBox(height: Space.sm),
                Text(
                  bench == null
                      ? 'Measure processor, memory, storage and network, then rent out what you do not use.'
                      : '${bench['cores']} cores · ${bench['freeGb'] ?? '?'} GB free · ${bench['cpuN']} MB/s hashing',
                  style: Txt.small(p.inkSoft),
                ),
                const SizedBox(height: Space.md),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [
                    FilledButton.icon(
                      onPressed: () => context.push('/market/diagnostics'),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(bench == null ? 'Run diagnostics' : 'Run again'),
                    ),
                    if (bench != null)
                      OutlinedButton(
                        onPressed: () => context.push('/market/sell/resource'),
                        child: const Text('Offer resources'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      if (m.leases().isNotEmpty || m.jobs().isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: MCard(
              onTap: () => context.push('/market/hub?tab=resources'),
              child: Row(
                children: [
                  Icon(Icons.inventory_2_outlined, color: mc.blue),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Text('${m.leases().length} leases · ${m.jobs().length} jobs', style: Txt.bodyStrong(p.ink)),
                  ),
                  Icon(Icons.chevron_right_rounded, color: p.faint),
                ],
              ),
            ),
          ),
        ),
      const SliverToBoxAdapter(
        child: MHeader('Phones for rent', subtitle: 'Encrypted storage you can audit, and compute you verify before paying'),
      ),
      if (providers.isEmpty)
        _empty('Nobody is renting yet', 'Run diagnostics and offer part of this phone.', icon: Icons.memory_rounded)
      else
        SliverList.builder(itemCount: providers.length, itemBuilder: (_, i) => ProviderCard(providers[i])),
    ];
  }

  List<Widget> _ads(Market m, String q) {
    final p = context.pal;
    final mc = MarketColors(p);
    final running = _find(m, Kinds.ad, q).where((a) => a.active).toList();
    final mine = m.mine(kind: Kinds.ad).where((a) => !a.deleted).toList();
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
          child: MCard(
            color: mc.violetSoft,
            border: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Earn from ads', style: Txt.heading(p.ink))),
                    Switch(value: m.adsEnabled, onChanged: (v) => m.setAds(on: v)),
                  ],
                ),
                Text(
                  'Sponsored cards appear in your feed. Each one you see pays you, and pays the phone that passed it to you. '
                  'Nothing about you is shared beyond a signed “seen” receipt to the advertiser.',
                  style: Txt.small(p.inkSoft),
                ),
                const SizedBox(height: Space.md),
                Row(
                  children: [
                    Text('Earned', style: Txt.small(p.muted)),
                    const SizedBox(width: Space.sm),
                    Amount(m.adEarnings, size: 18, color: mc.violet),
                    const Spacer(),
                    TextButton(onPressed: () => _editInterests(m), child: Text('Interests (${m.adInterests.length})')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      if (mine.isNotEmpty) ...[
        const SliverToBoxAdapter(child: MHeader('Your campaigns')),
        SliverList.builder(
          itemCount: mine.length,
          itemBuilder: (_, i) {
            final a = mine[i];
            final rec = m.campaign(a.id);
            final budget = a.body['budget'] as int;
            final spent = rec['spent'] as int;
            return Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.md),
              child: MCard(
                onTap: () => openListing(context, a),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(a.title, style: Txt.bodyStrong(p.ink))),
                        Pill.stage(context, a.status),
                      ],
                    ),
                    const SizedBox(height: Space.sm),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.pill),
                      child: LinearProgressIndicator(
                        value: budget == 0 ? 0 : spent / budget,
                        minHeight: 6,
                        color: mc.violet,
                        backgroundColor: p.raised,
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Text('${rec['views']} views · ${rec['clicks']} clicks · ${Coin.format(spent)} of ${Coin.format(budget)} spent',
                        style: Txt.small(p.muted)),
                  ],
                ),
              ),
            );
          },
        ),
      ],
      const SliverToBoxAdapter(child: MHeader('Running now')),
      if (running.isEmpty)
        _empty('No campaigns running', 'Promote a listing, a profile or a link with a budget you control.',
            icon: Icons.campaign_outlined)
      else
        SliverList.builder(itemCount: running.length, itemBuilder: (_, i) => SponsoredCard(running[i], preview: true)),
    ];
  }

  Future<void> _editInterests(Market m) async {
    final text = await prompt(
      context,
      title: 'Interests',
      hint: 'food, music, phones',
      initial: m.adInterests.join(', '),
      action: 'Save',
    );
    if (text == null) return;
    m.setAds(interests: text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList());
  }

  List<Widget> _plugins(Market m, String q) {
    final e = ref.watch(engineProvider);
    final listed = _find(m, Kinds.plugin, q);
    return [
      const SliverToBoxAdapter(
        child: MHeader('Plugins', subtitle: 'Sticker, phrase and accent packs. Packs are data; none of them run code.'),
      ),
      for (final pack in Market.starterPacks)
        if (q.isEmpty || '${pack['title']} ${pack['about']}'.toLowerCase().contains(q))
          SliverToBoxAdapter(
            child: PackCard(
              title: pack['title'] as String,
              about: pack['about'] as String,
              kind: pack['plugin'] as String,
              pack: pack['pack'] as Map,
              price: 0,
              installed: e.pluginInstalled(pack['id'] as String),
              onTap: () => _toggleStarter(pack),
            ),
          ),
      for (final l in listed)
        SliverToBoxAdapter(
          child: PackCard(
            title: l.title,
            about: l.about,
            kind: '${l.body['plugin']}',
            pack: (l.body['pack'] as Map?) ?? const {},
            price: l.price,
            installed: e.pluginInstalled(l.id),
            onTap: () => openListing(context, l),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(Space.gutter),
          child: OutlinedButton.icon(
            onPressed: () => context.push('/market/sell/plugin'),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Publish a pack'),
          ),
        ),
      ),
    ];
  }

  Future<void> _toggleStarter(Map<String, dynamic> pack) async {
    final e = ref.read(engineProvider);
    final id = pack['id'] as String;
    if (e.pluginInstalled(id)) {
      e.removePlugin(id);
      toast(context, 'Removed');
    } else {
      await attempt(context, () => e.installPlugin({...pack, 'body': pack['pack'], 'minor': 0, 'from': ''}),
          done: 'Installed');
    }
    setState(() {});
  }
}

class _CartButton extends StatelessWidget {
  const _CartButton({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      IconBtn(Icons.shopping_cart_outlined, tooltip: 'Cart', onTap: () => context.push('/market/cart')),
      if (count > 0) Positioned(right: 4, top: 4, child: IgnorePointer(child: CountBadge(count))),
    ],
  );
}

/// Spendable balance in the app bar; opens the wallet.
class _BalanceChip extends ConsumerWidget {
  const _BalanceChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final coin = ref.watch(coinProvider);
    ref.watch(coinTickProvider);
    if (coin == null) return const SizedBox.shrink();
    final hidden = ref.watch(walletHiddenProvider);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: p.raised,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.pill),
          onTap: () => context.go('/wallet'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.account_balance_wallet_outlined, size: 15, color: p.accent),
                const SizedBox(width: 6),
                hidden
                    ? Text('••••', style: Txt.bodyStrong(p.ink))
                    : Amount(coin.balance(), size: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown only while coins are held: what is waiting, and where to act on it.
class _EscrowBanner extends ConsumerWidget {
  const _EscrowBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final coin = ref.watch(coinProvider);
    final e = ref.watch(maybeEngineProvider);
    ref.watch(coinTickProvider);
    if (coin == null || e == null) return const SizedBox.shrink();
    final open = coin.escrows().where((h) => h.remaining > 0).toList();
    if (open.isEmpty) return const SizedBox.shrink();
    final held = open.fold<int>(0, (s, h) => s + h.remaining);
    final waiting = open.where((h) => h.actionsFor(e.me.id, nowMs()).isNotEmpty).length;
    final hidden = ref.watch(walletHiddenProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xs, Space.gutter, Space.xs),
      child: Material(
        color: p.accentSoft,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.push('/market/hub'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.shield_outlined, size: 18, color: p.accent),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    '${hidden ? '••••' : Coin.format(held)} MNT in escrow across ${open.length} '
                    '${open.length == 1 ? 'deal' : 'deals'}${waiting > 0 ? ' · $waiting need you' : ''}',
                    style: Txt.small(p.inkSoft).copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 18, color: p.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabsHeader extends SliverPersistentHeaderDelegate {
  _TabsHeader({required this.tab, required this.onTab, required this.bg});
  final MarketTab tab;
  final ValueChanged<MarketTab> onTab;
  final Color bg;

  @override
  double get minExtent => 60;
  @override
  double get maxExtent => 60;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) =>
      Container(color: bg, child: _TabRow(tab: tab, onTab: onTab));

  @override
  bool shouldRebuild(covariant _TabsHeader old) => old.tab != tab || old.bg != bg;
}

class _TabRow extends StatefulWidget {
  const _TabRow({required this.tab, required this.onTab});
  final MarketTab tab;
  final ValueChanged<MarketTab> onTab;

  @override
  State<_TabRow> createState() => _TabRowState();
}

class _TabRowState extends State<_TabRow> {
  final _keys = {for (final t in MarketTab.values) t: GlobalKey()};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(animate: false));
  }

  @override
  void didUpdateWidget(covariant _TabRow old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  void _reveal({bool animate = true}) {
    final ctx = _keys[widget.tab]?.currentContext;
    if (ctx == null || !mounted) return;
    Scrollable.ensureVisible(ctx, alignment: .5, duration: animate ? Motion.base : Duration.zero, curve: Motion.curve);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 10),
      children: [
        for (final t in MarketTab.values)
          Padding(
            key: _keys[t],
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => widget.onTab(t),
              child: AnimatedContainer(
                duration: Motion.fast,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: t == widget.tab ? p.accentSoft : p.surface,
                  borderRadius: BorderRadius.circular(Radii.pill),
                  border: Border.all(color: t == widget.tab ? p.accent.withValues(alpha: .5) : p.line),
                ),
                child: Row(
                  children: [
                    Icon(t.icon, size: 16, color: t == widget.tab ? p.accent : p.inkSoft),
                    const SizedBox(width: 6),
                    Text(t.label, style: Txt.small(t == widget.tab ? p.accent : p.inkSoft).copyWith(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
