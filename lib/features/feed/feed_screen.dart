import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import 'post_card.dart';
import 'stories.dart';

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

    return Scaffold(
      floatingActionButton: _ComposeButton(
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
            const SliverToBoxAdapter(child: StoriesBar()),
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
                        sliver: SliverList.builder(
                          itemCount: posts.length,
                          itemBuilder: (_, i) => PostCard(
                            key: ValueKey(posts[i].id),
                            post: posts[i],
                          ),
                        ),
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
