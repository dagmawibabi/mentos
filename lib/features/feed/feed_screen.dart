import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/market/market.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import '../market/market_cards.dart';
import '../market/market_kit.dart';
import 'post_card.dart';
import 'stories.dart';
import '../../plugins/plugin_providers.dart';
import '../plugins/plugins_screen.dart';

class FeedScreen extends ConsumerWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final feed = ref.watch(feedProvider);
    final unseen = ref.watch(unseenActivityProvider).value ?? 0;
    final held = ref.watch(heldPostsProvider).value;
    final waiting = (held?.scheduled.length ?? 0) + (held?.drafts.length ?? 0);
    final net = ref.watch(netStatusProvider).value;
    final layout = ref.watch(pluginLayoutProvider);

    return Scaffold(
      floatingActionButton: layout.hide.contains('composeButton')
          ? null
          : _ComposeButton(
              onTap: () => context.push('/compose'),
            ),
      body: RefreshIndicator(
        color: p.ink,
        backgroundColor: p.surface,
        onRefresh: () async {
          final e = ref.read(maybeEngineProvider);
          if (e != null) await e.connectNode();
        },
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              floating: true,
              snap: true,
              titleSpacing: Space.gutter,
              title: Row(
                children: [
                  const MentosMark(size: 22),
                  const SizedBox(width: 10),
                  Text('Feed', style: Txt.title(p.ink)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: (net?.links.isNotEmpty ?? false)
                          ? p.accent.withValues(alpha: .15)
                          : p.muted.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: (net?.links.isNotEmpty ?? false) ? p.accent : p.muted,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          (net?.links.isNotEmpty ?? false) ? 'P2P Online' : 'Local Node',
                          style: Txt.label(
                            (net?.links.isNotEmpty ?? false) ? p.accent : p.muted,
                          ).copyWith(fontSize: 10, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                IconBtn(
                  Icons.qr_code_scanner_rounded,
                  tooltip: 'Add someone',
                  onTap: () => context.push('/connect'),
                ),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconBtn(
                      Icons.schedule_rounded,
                      tooltip: 'Drafts and scheduled',
                      onTap: () => context.push('/drafts'),
                    ),
                    if (waiting > 0)
                      Positioned(right: 4, top: 6, child: CountBadge(waiting)),
                  ],
                ),
                Stack(
                  children: [
                    IconBtn(
                      Icons.notifications_none_rounded,
                      tooltip: 'Activity',
                      onTap: () => context.push('/activity'),
                    ),
                    if (unseen > 0)
                      Positioned(
                        right: 11,
                        top: 11,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: p.accent,
                            shape: BoxShape.circle,
                            border: Border.all(color: p.bg, width: 1.5),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 8),
              ],
            ),
            if (net != null && !net.running)
              const SliverToBoxAdapter(child: _OfflineBanner()),
            if (waiting > 0)
              SliverToBoxAdapter(
                child: _WaitingBanner(
                  count: waiting,
                  onTap: () => context.push('/drafts'),
                ),
              ),
            if (!layout.hide.contains('stories')) const SliverToBoxAdapter(child: StoriesBar()),
            const SliverToBoxAdapter(child: PluginSlotView('feed.top')),
            ...feed.when(
              loading: () => [const SliverFillRemaining(child: Loading())],
              error: (e, _) => [
                SliverFillRemaining(child: Center(child: Text('$e'))),
              ],
              data: (posts) => posts.isEmpty
                  ? [
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          icon: Icons.wifi_tethering_rounded,
                          title: 'Quiet for now',
                          body:
                              'Posts appear here while the people you follow are online, '
                              'or when they let you keep a copy.',
                          action: OutlinedButton.icon(
                            onPressed: () => context.push('/connect'),
                            icon: const Icon(
                              Icons.person_add_alt_rounded,
                              size: 18,
                            ),
                            label: const Text('Add someone'),
                          ),
                        ),
                      ),
                    ]
                  : [
                      SliverPadding(
                        padding: const EdgeInsets.only(
                          top: Space.md,
                          bottom: 96,
                        ),
                        sliver: _FeedWithAds(posts: posts),
                      ),
                    ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposeButton extends StatelessWidget {
  const _ComposeButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Pressable(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: p.ink,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Icon(Icons.edit_rounded, color: p.bg, size: 22),
      ),
    );
  }
}

class _WaitingBanner extends StatelessWidget {
  const _WaitingBanner({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final label = count == 1 ? '1 post is waiting' : '$count posts are waiting';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.sm,
        Space.gutter,
        0,
      ),
      child: Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(Space.md, 10, Space.sm, 10),
          decoration: BoxDecoration(
            color: p.raised,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(
            children: [
              Icon(Icons.schedule_rounded, size: 18, color: p.inkSoft),
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(
                  '$label · drafts and scheduled',
                  style: Txt.small(p.inkSoft),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: p.faint, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineBanner extends ConsumerWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final busy = ref.watch(maybeEngineProvider)?.connecting ?? false;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.sm,
        Space.gutter,
        Space.sm,
      ),
      padding: const EdgeInsets.fromLTRB(
        Space.md,
        Space.sm,
        Space.sm,
        Space.sm,
      ),
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: p.muted),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              'Your node is offline. New posts stay on this phone until it reconnects.',
              style: Txt.small(p.inkSoft),
            ),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () {
                    final e = ref.read(maybeEngineProvider);
                    if (e != null) unawaited(e.connectNode());
                  },
            child: Text(busy ? 'Connecting' : 'Reconnect'),
          ),
        ],
      ),
    );
  }
}

/// Posts, with a sponsored card after every sixth post for people who
/// turned on "Earn from ads" in the market.
class _FeedWithAds extends ConsumerWidget {
  const _FeedWithAds({required this.posts});
  final List<PostView> posts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(marketProvider);
    ref.watch(marketTickProvider);
    final ads = m != null && m.adsEnabled;
    const every = 6;
    final slots = ads && posts.length >= 3 ? posts.length ~/ every + (posts.length % every >= 3 ? 1 : 0) : 0;
    return SliverList.builder(
      itemCount: posts.length + slots,
      itemBuilder: (_, i) {
        if (ads && (i + 1) % (every + 1) == 0) {
          final ad = m.nextAd(slot: i ~/ (every + 1));
          return ad == null ? const SizedBox.shrink() : SponsoredCard(ad, key: ValueKey('ad-${ad.id}-$i'));
        }
        final index = ads ? i - (i + 1) ~/ (every + 1) : i;
        if (index >= posts.length) return const SizedBox.shrink();
        return PostCard(key: ValueKey(posts[index].id), post: posts[index]);
      },
    );
  }
}
