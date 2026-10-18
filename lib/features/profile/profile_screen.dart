import 'package:flutter/material.dart';
import '../../plugins/plugin_providers.dart';
import '../plugins/plugins_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/engine.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';
import '../activity/activity_screen.dart';
import '../bookmarks/bookmarks_screen.dart';
import '../common/attach.dart';
import '../files/hosted_list.dart';
import '../wallet/wallet_screen.dart';
import '../feed/post_card.dart';
import '../../widgets/profile_header.dart';

class MyProfileScreen extends ConsumerWidget {
  const MyProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const SizedBox.shrink();
    final me = ref.watch(myProfileProvider).value ?? e.myProfile;
    final posts = ref.watch(authorFeedProvider(e.me.id)).value ?? const <PostView>[];
    final people = ref.watch(peopleProvider).value ?? const <Peer>[];
    final grants = ref.watch(grantsProvider).value ?? const <Grant>[];
    final stories = ref.watch(storiesProvider).value ?? const <StoryGroup>[];
    final mine = stories.where((g) => g.author == e.me.id).firstOrNull;
    final keepers = grants.where((g) => g.dir == GrantDir.out && g.state == GrantState.active).map((g) => g.peer).toSet();
    final followers = people.where((x) => x.followsMe).length;
    final following = people.where((x) => x.iFollow).length;

    Future<void> host() async {
      try {
        final n = await hostPickedFiles(context, e);
        if (n > 0 && context.mounted) toast(context, 'Hosting');
      } catch (err) {
        if (context.mounted) toast(context, 'Could not host: $err');
      }
    }

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        body: NestedScrollView(
          headerSliverBuilder: (context, _) => [
            SliverAppBar(
              pinned: true,
              title: const Text('You'),
              actions: [
                IconBtn(Icons.qr_code_rounded, tooltip: 'My code', onTap: () => context.push('/connect')),
                IconBtn(Icons.settings_outlined, tooltip: 'Settings', onTap: () => context.push('/settings')),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: (v) => switch (v) {
                    'insights' => context.push('/insights'),
                    'data' => context.push('/data'),
                    'custody' => context.push('/custody'),
                    _ => showPeerTech(context, e.me.id),
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'insights', child: ListTile(leading: Icon(Icons.insights_outlined), title: Text('Insights'), dense: true)),
                    PopupMenuItem(value: 'data', child: ListTile(leading: Icon(Icons.data_object_rounded), title: Text('Data explorer'), dense: true)),
                    PopupMenuItem(value: 'custody', child: ListTile(leading: Icon(Icons.inventory_2_outlined), title: Text('Who holds what'), dense: true)),
                    PopupMenuItem(value: 'tech', child: ListTile(leading: Icon(Icons.info_outline_rounded), title: Text('Technical details'), dense: true)),
                  ],
                ),
                const SizedBox(width: 4),
              ],
            ),
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ------------------------------------------------ identity
                  SizedBox(
                    height: 170,
                    child: Stack(
                      children: [
                        Positioned(
                          left: Space.gutter,
                          right: Space.gutter,
                          top: 0,
                          height: 112,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: ProfileCover(id: e.me.id, cover: me.cover),
                          ),
                        ),
                        Positioned(
                          left: Space.gutter + Space.md,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(40)),
                            child: StoryAvatar(
                              id: e.me.id,
                              size: 80,
                              story: mine != null,
                              onTap: () => context.push(mine != null ? '/story/${e.me.id}' : '/story/new'),
                            ),
                          ),
                        ),
                        Positioned(
                          right: Space.gutter + Space.xs,
                          bottom: 0,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, backgroundColor: p.bg),
                            icon: const Icon(Icons.edit_outlined, size: 16),
                            label: const Text('Edit profile'),
                            onPressed: () => context.push('/edit-profile'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.sm),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.gutter + Space.xs),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(me.displayName, style: Txt.display(p.ink).copyWith(fontSize: 24, height: 1.15)),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: e.me.id));
                            toast(context, 'Key copied');
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(shortId(e.me.id), style: Txt.mono(p.muted)),
                              const SizedBox(width: 6),
                              Icon(Icons.copy_rounded, size: 13, color: p.faint),
                              const SizedBox(width: 10),
                              Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: e.running ? p.accent : p.faint)),
                              const SizedBox(width: 5),
                              Text(e.running ? 'online' : 'offline', style: Txt.mono(e.running ? p.accent : p.muted, size: 11)),
                            ],
                          ),
                        ),
                        if (me.bio.isNotEmpty) ...[
                          const SizedBox(height: Space.sm),
                          Text(me.bio, style: Txt.body(p.inkSoft)),
                        ] else ...[
                          const SizedBox(height: Space.sm),
                          GestureDetector(
                            onTap: () => context.push('/edit-profile'),
                            child: Text('Add a bio so people know it\'s you', style: Txt.small(p.accent)),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.lg),

                  // ------------------------------------------------ stats
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                    child: Container(
                      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: p.line)),
                      clipBehavior: Clip.antiAlias,
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Stat(posts.length, 'Posts', null),
                            VerticalDivider(width: 1, color: p.line),
                            _Stat(followers, 'Followers', () => context.push('/people?tab=1')),
                            VerticalDivider(width: 1, color: p.line),
                            _Stat(following, 'Following', () => context.push('/people?tab=0')),
                            VerticalDivider(width: 1, color: p.line),
                            _Stat(keepers.length, 'Keep you', () => context.push('/custody')),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.md),

                  // ------------------------------------------------ actions
                  if (!ref.watch(pluginLayoutProvider).hide.contains('quickActions'))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.gutter - 4),
                    child: Row(
                      children: [
                        _Quick(Icons.edit_note_rounded, 'Post', const Color(0xFF0E9F6E), () => context.push('/compose')),
                        _Quick(Icons.amp_stories_outlined, 'Story', const Color(0xFFDB2777), () => context.push('/story/new')),
                        _Quick(Icons.hub_outlined, 'Host', const Color(0xFF6366F1), host),
                        _Quick(Icons.swap_horiz_rounded, 'Transfer', const Color(0xFF0EA5E9), () => context.push('/transfer')),
                        _Quick(Icons.folder_outlined, 'Files', const Color(0xFFD97706), () => context.push('/files')),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.md),

                  const PluginSlotView('profile.top', padding: EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm)),
                  const SizedBox(height: Space.sm),
                ],
              ),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _TabsBar(
                bg: p.bg,
                bar: const TabBar(
                  tabs: [
                    Tab(text: 'Posts'),
                    Tab(text: 'Saved'),
                    Tab(text: 'Activity'),
                    Tab(text: 'Hosted'),
                  ],
                ),
              ),
            ),
          ],
          body: TabBarView(
            children: [
              posts.isEmpty
                  ? EmptyState(
                      icon: Icons.edit_note_rounded,
                      title: 'Nothing posted yet',
                      body: 'Your posts are stored here and reach followers directly.',
                      compact: true,
                      action: OutlinedButton(onPressed: () => context.push('/compose'), child: const Text('Write a post')),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(0, Space.md, 0, Space.xl),
                      itemCount: posts.length,
                      itemBuilder: (_, i) => PostCard(post: posts[i]),
                    ),
              const BookmarksScreen(embedded: true),
              const ActivityScreen(embedded: true),
              ListView(children: [HostedList(author: e.me.id, compact: true)]),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label, this.onTap);
  final int value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Text(compact(value), style: Txt.heading(p.ink).copyWith(fontSize: 19)),
              const SizedBox(height: 2),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted).copyWith(fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Quick extends StatelessWidget {
  const _Quick(this.icon, this.label, this.tint, this.onTap);
  final IconData icon;
  final String label;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Expanded(
      child: Pressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            children: [
              Container(
                height: 48,
                decoration: BoxDecoration(color: tint.withValues(alpha: .12), borderRadius: BorderRadius.circular(16)),
                child: Center(child: Icon(icon, color: tint, size: 22)),
              ),
              const SizedBox(height: 5),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.inkSoft).copyWith(fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabsBar extends SliverPersistentHeaderDelegate {
  _TabsBar({required this.bar, required this.bg});
  final TabBar bar;
  final Color bg;

  @override
  double get minExtent => bar.preferredSize.height;
  @override
  double get maxExtent => bar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => Container(color: bg, child: bar);

  @override
  bool shouldRebuild(covariant _TabsBar old) => old.bg != bg;
}

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    if (id == e.me.id) return const MyProfileScreen();
    final peer = ref.watch(peerProvider(id)).value ?? Peer(id: id);
    final online = ref.watch(onlineProvider(id)).value ?? false;
    final posts = ref.watch(authorFeedProvider(id)).value ?? const <PostView>[];
    final canPreserve = peer.profile?.keepPosts ?? false;
    final theirStory = (ref.watch(storiesProvider).value ?? const <StoryGroup>[]).where((g) => g.author == id).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconBtn(
            Icons.info_outline_rounded,
            tooltip: 'Technical',
            onTap: () => showPeerTech(context, id),
          ),
          IconBtn(
            Icons.more_horiz_rounded,
            onTap: () => _menu(context, ref, peer),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          if (peer.profile?.cover != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: SizedBox(height: 112, child: ProfileCover(id: id, cover: peer.profile!.cover)),
              ),
            ),
          ProfileHeader(
            id: id,
            story: theirStory != null,
            storySeen: theirStory?.allSeen ?? false,
            onAvatar: theirStory == null ? null : () => context.push('/story/$id'),
            name: peer.name,
            bio: peer.profile?.bio ?? '',
            status: online ? null : lastSeen(peer.lastSeen),
            online: online,
            stats: [
              (posts.length, online ? 'posts' : 'visible posts', null),
              if (peer.followsMe) (1, 'follows you', null),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Column(
              children: [
                if (peer.followsMe && !peer.iFollow)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.sm),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${peer.name} follows you',
                        style: Txt.mono(p.accent, size: 11),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: peer.iFollow
                          ? OutlinedButton(
                              onPressed: () => e.follow(id, false),
                              child: const Text('Following'),
                            )
                          : FilledButton(
                              onPressed: () => e.follow(id, true),
                              child: Text(
                                peer.followsMe ? 'Follow back' : 'Follow',
                              ),
                            ),
                    ),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => context.push('/chat/$id'),
                        child: const Text('Message'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.sm),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _sendFile(context, e, id),
                        icon: const Icon(Icons.file_upload_outlined, size: 18),
                        label: const Text('Send file'),
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    Expanded(child: WalletChip(peer: id)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.md),
          if (peer.iFollow)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Container(
                padding: const EdgeInsets.fromLTRB(Space.md, 6, 6, 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(color: peer.preserve ? p.accent : p.line),
                ),
                child: Row(
                  children: [
                    Icon(
                      peer.preserve
                          ? Icons.cloud_done_rounded
                          : Icons.cloud_outlined,
                      size: 18,
                      color: peer.preserve ? p.accent : p.muted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Keep their posts',
                            style: Txt.small(p.ink)
                                .copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            canPreserve
                                ? (peer.preserve
                                      ? 'Stored here and shown to others while ${peer.name} is away.'
                                      : '${peer.name} allows followers to keep a copy.')
                                : '${peer.name} keeps their posts on their own phone only.',
                            style: Txt.small(p.muted).copyWith(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: peer.preserve,
                      onChanged: canPreserve || peer.preserve
                          ? (v) => e.setPreserve(id, v)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: Space.lg),
          DefaultTabController(
            length: 2,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Posts'),
                    Tab(text: 'Hosted'),
                  ],
                ),
                SizedBox(
                  height: 520,
                  child: TabBarView(
                    children: [
                      posts.isEmpty
                          ? EmptyState(
                              icon: online
                                  ? Icons.edit_note_rounded
                                  : Icons.cloud_off_rounded,
                              title: online
                                  ? 'No posts yet'
                                  : 'Posts are on ${peer.name}\'s phone',
                              compact: true,
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                0,
                                Space.md,
                                0,
                                Space.xl,
                              ),
                              itemCount: posts.length,
                              itemBuilder: (_, i) => PostCard(post: posts[i]),
                            ),
                      ListView(
                        children: [
                          HostedList(
                            author: id,
                            searchable: true,
                            compact: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendFile(BuildContext context, Engine e, String id) async {
    final picked = await pickFiles(e.media, context: context);
    if (picked.isEmpty || !context.mounted) return;
    try {
      for (final f in picked) {
        final media = await importPending(e, f);
        await e.offerTransfer(id, media);
      }
      if (context.mounted) toast(context, 'File offered');
    } catch (err) {
      if (context.mounted) toast(context, 'Could not send: $err');
    }
  }

  void _menu(BuildContext context, WidgetRef ref, Peer peer) {
    final e = ref.read(engineProvider);
    showActions(context, [
      SheetAction(
        Icons.info_outline_rounded,
        'Technical details',
        () => showPeerTech(context, peer.id),
      ),
      SheetAction(
        Icons.swap_horiz_rounded,
        'File transfer',
        () => context.push('/transfer/${peer.id}'),
      ),
      SheetAction(Icons.key_rounded, 'Copy key', () {
        Clipboard.setData(ClipboardData(text: peer.id));
        toast(context, 'Key copied');
      }),
      SheetAction(Icons.edit_outlined, 'Set nickname', () async {
        final n = await prompt(
          context,
          title: 'Nickname',
          body: 'Only you see this. Clear it to use their name again.',
          initial: peer.nickname ?? '',
          hint: 'A name you will recognize',
          selectAll: true,
          capitalization: TextCapitalization.words,
        );
        if (n != null)
          e.setNickname(peer.id, n.trim().isEmpty ? null : n.trim());
      }),
      SheetAction(
        peer.blocked ? Icons.check_circle_outline_rounded : Icons.block_rounded,
        peer.blocked ? 'Unblock' : 'Block',
        () async {
          if (!peer.blocked) {
            final ok = await confirm(
              context,
              title: 'Block ${peer.name}?',
              body: 'You won\'t see their posts or messages, and anything of theirs kept here is deleted.',
              action: 'Block',
              danger: true,
            );
            if (!ok) return;
          }
          await e.block(peer.id, !peer.blocked);
        },
        danger: !peer.blocked,
      ),
    ]);
  }
}
