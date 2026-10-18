import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/market/market.dart';
import '../../net/pay/coin.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import 'market_kit.dart';

void openListing(BuildContext context, Listing l) =>
    context.push('/market/l/${Uri.encodeComponent(l.id)}');

/// Large photo card for the "fresh" carousel.
class FeatureCard extends ConsumerWidget {
  const FeatureCard(this.l, {super.key});
  final Listing l;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(marketProvider);
    final e = ref.watch(maybeEngineProvider);
    return Pressable(
      onTap: () => openListing(context, l),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: SizedBox(
          width: 260,
          child: Stack(
            fit: StackFit.expand,
            children: [
              MarketImage(media: l.cover, sources: [l.author, m?.via(l.id) ?? '']),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xCC000000)],
                    stops: [.45, 1],
                  ),
                ),
              ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.heading(Colors.white)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Amount(l.price, size: 15, color: Colors.white),
                        const Spacer(),
                        Flexible(
                          child: Text(
                            e?.nameOf(l.author) ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Txt.small(Colors.white70),
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
      ),
    );
  }
}

/// Photo-first product tile for the shop grid.
class ProductCard extends ConsumerWidget {
  const ProductCard(this.l, {super.key});
  final Listing l;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider);
    final e = ref.watch(maybeEngineProvider);
    final rep = m?.reputation(l.author);
    final stock = l.body['stock'] as int? ?? -1;
    final digital = l.body['condition'] == 'digital';
    final soldOut = stock == 0 || l.status == 'sold out';
    return Pressable(
      onTap: () => openListing(context, l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: p.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MarketImage(
                    media: l.cover,
                    sources: [l.author, m?.via(l.id) ?? ''],
                    icon: Icons.shopping_bag_outlined,
                  ),
                  if (soldOut) Container(color: Colors.white.withValues(alpha: .45)),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Wrap(
                      spacing: 4,
                      children: [
                        if (digital)
                          Pill('Download', fg: Colors.white, bg: Colors.black.withValues(alpha: .55), icon: Icons.bolt_rounded),
                        if (soldOut)
                          Pill('Sold out', fg: Colors.white, bg: Colors.black.withValues(alpha: .7), dot: false)
                        else if (stock > 0 && stock <= 3)
                          Pill('$stock left', fg: Colors.white, bg: Colors.black.withValues(alpha: .55), dot: false),
                      ],
                    ),
                  ),
                  if (l.author == e?.me.id)
                    Positioned(right: 8, top: 8, child: Pill('Yours', fg: p.accentInk, bg: p.accent, dot: false)),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Amount(l.price, size: 17, color: p.ink),
                const SizedBox(height: 2),
                Text(
                  l.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Txt.small(p.inkSoft).copyWith(height: 1.3, fontSize: 13.5),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        e?.nameOf(l.author) ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Txt.mono(p.muted, size: 11),
                      ),
                    ),
                    if (rep != null && rep.badge) ...[
                      const SizedBox(width: 3),
                      Icon(Icons.verified_rounded, size: 12, color: p.accent),
                    ],
                    if (rep != null && rep.reviews > 0) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.star_rounded, size: 12, color: MarketColors(p).amber),
                      Text(rep.stars.toStringAsFixed(1), style: Txt.mono(p.muted, size: 11)),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class TaskCard extends ConsumerWidget {
  const TaskCard(this.l, {super.key});
  final Listing l;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final mc = MarketColors(p);
    final e = ref.watch(maybeEngineProvider);
    final deadline = l.body['deadline'] as int? ?? 0;
    final applicants = l.body['applicants'] as int? ?? 0;
    final criteria = (l.body['criteria'] as List? ?? const []).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.md),
      child: MCard(
        onTap: () => openListing(context, l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Pill(taskCategories[l.category] ?? 'Task', fg: mc.amber, bg: mc.amberSoft, dot: false),
                const SizedBox(width: 6),
                if (l.status != 'open' && l.status != 'active') Pill.stage(context, l.status),
                const Spacer(),
                Icon(Icons.schedule_rounded, size: 14, color: p.muted),
                const SizedBox(width: 4),
                Text(timeLeft(deadline), style: Txt.mono(p.muted, size: 11)),
              ],
            ),
            const SizedBox(height: Space.md),
            Text(l.title, style: Txt.heading(p.ink)),
            if (l.about.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(l.about, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.small(p.inkSoft)),
            ],
            const SizedBox(height: Space.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('REWARD', style: Txt.label(p.muted)),
                    const SizedBox(height: 2),
                    Amount(l.price, size: 22, color: p.accent),
                  ],
                ),
                const Spacer(),
                _Meta(Icons.people_alt_outlined, '$applicants'),
                const SizedBox(width: Space.md),
                _Meta(Icons.checklist_rounded, '$criteria'),
                const SizedBox(width: Space.md),
                Text(e?.nameOf(l.author) ?? '', style: Txt.small(p.muted)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: p.muted),
        const SizedBox(width: 3),
        Text(text, style: Txt.mono(p.muted, size: 12)),
      ],
    );
  }
}

/// A peer-to-peer exchange offer.
class OfferRow extends ConsumerWidget {
  const OfferRow(this.l, {super.key});
  final Listing l;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final sells = l.body['side'] == 'sell';
    final rate = l.body['rate'] as int;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.md),
      child: MCard(
        onTap: () => openListing(context, l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TraderChip(l.author, dense: true),
            const SizedBox(height: Space.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('PRICE', style: Txt.label(p.muted)),
                      const SizedBox(height: 2),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text((rate / 100).toStringAsFixed(2), style: Txt.title(p.ink)),
                          const SizedBox(width: 4),
                          Text('birr / MNT', style: Txt.mono(p.muted, size: 11)),
                        ],
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: () => openListing(context, l),
                  style: FilledButton.styleFrom(
                    backgroundColor: sells ? p.accent : p.danger,
                    foregroundColor: sells ? p.accentInk : Colors.white,
                  ),
                  child: Text(sells ? 'Buy' : 'Sell'),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Limit ${Coin.format(l.body['min'] as int)} – ${Coin.format(l.body['max'] as int)} MNT · pay within ${l.body['windowMins']} min',
              style: Txt.small(p.muted),
            ),
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in (l.body['methods'] as List).whereType<String>())
                  Pill(m, fg: p.inkSoft, bg: p.raised, dot: false),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A phone offering storage or compute, with its measured numbers.
class ProviderCard extends ConsumerWidget {
  const ProviderCard(this.l, {super.key});
  final Listing l;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final mc = MarketColors(p);
    final bench = (l.body['bench'] as Map?)?.cast<String, dynamic>() ?? const {};
    final storage = (l.body['storage'] as Map?)?.cast<String, dynamic>();
    final compute = (l.body['compute'] as Map?)?.cast<String, dynamic>();
    final net = (bench['net'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.md),
      child: MCard(
        onTap: () => openListing(context, l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: mc.blueSoft, borderRadius: BorderRadius.circular(12)),
                  child: Icon(_platformIcon('${bench['platform']}'), color: mc.blue),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.title, style: Txt.bodyStrong(p.ink)),
                      Text(
                        [
                          if (bench['cores'] != null) '${bench['cores']} cores',
                          if (bench['ramMb'] != null) '${((bench['ramMb'] as int) / 1024).toStringAsFixed(1)} GB RAM',
                          if (net['mode'] != null) '${net['mode']}',
                        ].join(' · '),
                        style: Txt.small(p.muted),
                      ),
                    ],
                  ),
                ),
                if (bench['score'] != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${bench['score']}', style: Txt.heading(mc.blue)),
                      Text('SCORE', style: Txt.label(p.muted)),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: Space.md),
            if (storage != null)
              _OfferLine(
                icon: Icons.sd_storage_outlined,
                title: '${storage['gb']} GB storage',
                price: storage['perGbDay'] as int,
                per: 'GB / day',
              ),
            if (compute != null)
              _OfferLine(
                icon: Icons.bolt_rounded,
                title: (compute['jobs'] as List).map((j) => jobTypes[j] ?? j).join(', '),
                price: compute['perUnit'] as int,
                per: 'unit',
              ),
            if (l.body['sandbox'] is Map)
              _OfferLine(
                icon: Icons.terminal_rounded,
                title: 'Sandbox · ${(l.body['sandbox'] as Map)['mb']} MB, scripts and files',
                price: (l.body['sandbox'] as Map)['perHour'] as int,
                per: 'hour',
              ),
          ],
        ),
      ),
    );
  }
}

IconData _platformIcon(String platform) => switch (platform) {
  'android' => Icons.phone_android_rounded,
  'ios' => Icons.phone_iphone_rounded,
  'windows' || 'linux' || 'macos' => Icons.computer_rounded,
  _ => Icons.devices_other_rounded,
};

class _OfferLine extends StatelessWidget {
  const _OfferLine({required this.icon, required this.title, required this.price, required this.per});
  final IconData icon;
  final String title;
  final int price;
  final String per;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Row(
        children: [
          Icon(icon, size: 17, color: p.inkSoft),
          const SizedBox(width: Space.sm),
          Expanded(child: Text(title, style: Txt.small(p.inkSoft), maxLines: 1, overflow: TextOverflow.ellipsis)),
          Amount(price, size: 14),
          Text(' / $per', style: Txt.mono(p.muted, size: 11)),
        ],
      ),
    );
  }
}

/// The card a viewer sees in their feed. Counts a view after it has been on
/// screen for a moment, and pays nothing unless the viewer opted in.
class SponsoredCard extends ConsumerStatefulWidget {
  const SponsoredCard(this.ad, {super.key, this.preview = false});
  final Listing ad;
  final bool preview;

  @override
  ConsumerState<SponsoredCard> createState() => _SponsoredCardState();
}

class _SponsoredCardState extends ConsumerState<SponsoredCard> {
  bool _counted = false;

  @override
  void initState() {
    super.initState();
    if (!widget.preview) {
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (!mounted || _counted) return;
        _counted = true;
        ref.read(marketProvider)?.sawAd(widget.ad);
      });
    }
  }

  Future<void> _open() async {
    final ad = widget.ad;
    if (!widget.preview) await ref.read(marketProvider)?.clickedAd(ad);
    if (!mounted) return;
    final target = (ad.body['target'] as Map?)?.cast<String, dynamic>() ?? const {};
    switch (target['type']) {
      case 'url':
        final uri = Uri.tryParse('${target['value']}');
        if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) return;
        final go = await confirm(context, title: 'Open link?', body: uri.toString(), action: 'Open');
        if (go) await launchUrl(uri, mode: LaunchMode.externalApplication);
      case 'listing':
        context.push('/market/l/${Uri.encodeComponent('${target['value']}')}');
      case 'profile':
        context.push('/u/${target['value']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final mc = MarketColors(p);
    final ad = widget.ad;
    final m = ref.watch(marketProvider);
    final e = ref.watch(maybeEngineProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.sm),
      child: MCard(
        padding: EdgeInsets.zero,
        onTap: _open,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (ad.cover != null)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: MarketImage(media: ad.cover, sources: [ad.author, m?.via(ad.id) ?? '']),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Pill('Sponsored', fg: mc.violet, bg: mc.violetSoft, icon: Icons.campaign_outlined),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(e?.nameOf(ad.author) ?? '', style: Txt.small(p.muted), overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  Text(ad.title, style: Txt.heading(p.ink)),
                  if ('${ad.body['text'] ?? ''}'.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('${ad.body['text']}', style: Txt.body(p.inkSoft)),
                  ],
                  if ((ad.body['target'] as Map?)?['type'] != 'none') ...[
                    const SizedBox(height: Space.md),
                    Text('Learn more →', style: Txt.bodyStrong(mc.violet)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

