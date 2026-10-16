import 'package:flutter/material.dart';
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
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const SizedBox.shrink();
    final me = ref.watch(myProfileProvider).value ?? e.myProfile;
    final posts = ref.watch(authorFeedProvider(e.me.id)).value ?? const <PostView>[];
    final people = ref.watch(peopleProvider).value ?? const <Peer>[];
    final grants = ref.watch(grantsProvider).value ?? const <Grant>[];
    final keepers = grants.where((g) => g.dir == GrantDir.out && g.state == GrantState.active).map((g) => g.peer).toSet();

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('You'),
          actions: [
            IconBtn(Icons.insights_outlined, tooltip: 'Insights', onTap: () => context.push('/insights')),
            IconBtn(Icons.info_outline_rounded, tooltip: 'Technical', onTap: () => showPeerTech(context, e.me.id)),
            IconBtn(Icons.qr_code_rounded, tooltip: 'My code', onTap: () => context.push('/connect')),
            IconBtn(Icons.settings_outlined, tooltip: 'Settings', onTap: () => context.push('/settings')),
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          children: [
            ProfileHeader(
              id: e.me.id,
              name: me.displayName,
              bio: me.bio,
              onEdit: () => context.push('/edit-profile'),
              stats: [
                (posts.length, 'posts', null),
                (people.where((x) => x.iFollow).length, 'following', () => context.push('/people?tab=0')),
                (people.where((x) => x.followsMe).length, 'followers', () => context.push('/people?tab=1')),
                (keepers.length, 'keep you', () => context.go('/network')),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () async {
                        try {
                          final n = await hostPickedFiles(context, e);
                          if (n > 0 && context.mounted) toast(context, 'Hosting');
                        } catch (err) {
                          if (context.mounted) toast(context, 'Could not host: $err');
                        }
                      },
                      icon: const Icon(Icons.hub_outlined, size: 16),
                      label: const Text('Host a file', maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => context.push('/transfer'),
                      icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                      label: const Text('Transfer', maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => context.push('/files'),
                      icon: const Icon(Icons.folder_outlined, size: 16),
                      label: const Text('Files', maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
            ),
            const TabBar(tabs: [Tab(text: 'Posts'), Tab(text: 'Bookmarks'), Tab(text: 'Activity'), Tab(text: 'Hosted')]),
            Expanded(
              child: TabBarView(
                children: [
                  posts.isEmpty
                      ? EmptyState(
                          icon: Icons.edit_note_rounded,
                          title: 'Nothing posted yet',
                          body: 'Your posts are stored here and reach followers directly.',
                          compact: true,
                          action: OutlinedButton(onPressed: () => context.push('/compose'), child: const Text('Write a post')),
                        )
                      : ListView.separated(
                          itemCount: posts.length,
                          separatorBuilder: (_, _) => const Hairline(),
                          itemBuilder: (_, i) => PostCard(post: posts[i]),
                        ),
                  const BookmarksScreen(embedded: true),
                  const ActivityScreen(embedded: true),
                  ListView(children: [HostedList(author: e.me.id, compact: true)]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconBtn(Icons.info_outline_rounded, tooltip: 'Technical', onTap: () => showPeerTech(context, id)),
          IconBtn(Icons.more_horiz_rounded, onTap: () => _menu(context, ref, peer)),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          ProfileHeader(
            id: id,
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
                      child: Text('${peer.name} follows you', style: Txt.mono(p.accent, size: 11)),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: peer.iFollow
                          ? OutlinedButton(onPressed: () => e.follow(id, false), child: const Text('Following'))
                          : FilledButton(
                              onPressed: () => e.follow(id, true),
                              child: Text(peer.followsMe ? 'Follow back' : 'Follow'),
                            ),
                    ),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: OutlinedButton(onPressed: () => context.push('/chat/$id'), child: const Text('Message')),
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
                    Icon(peer.preserve ? Icons.cloud_done_rounded : Icons.cloud_outlined,
                        size: 18, color: peer.preserve ? p.accent : p.muted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Keep their posts', style: Txt.small(p.ink).copyWith(fontWeight: FontWeight.w600)),
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
                    Switch(value: peer.preserve, onChanged: canPreserve || peer.preserve ? (v) => e.setPreserve(id, v) : null),
                  ],
                ),
              ),
            ),
          const SizedBox(height: Space.md),
          const SizedBox(height: Space.md),
          DefaultTabController(
            length: 2,
            child: Column(
              children: [
                const TabBar(tabs: [Tab(text: 'Posts'), Tab(text: 'Hosted')]),
                SizedBox(
                  height: 520,
                  child: TabBarView(
                    children: [
                      posts.isEmpty
                          ? EmptyState(
                              icon: online ? Icons.edit_note_rounded : Icons.cloud_off_rounded,
                              title: online ? 'No posts yet' : 'Posts are on ${peer.name}\'s phone',
                              compact: true,
                            )
                          : ListView.separated(
                              itemCount: posts.length,
                              separatorBuilder: (_, _) => const Hairline(),
                              itemBuilder: (_, i) => PostCard(post: posts[i]),
                            ),
                      ListView(children: [HostedList(author: id, searchable: true, compact: true)]),
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
    final picked = await pickFiles(e.media);
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
      SheetAction(Icons.info_outline_rounded, 'Technical details', () => showPeerTech(context, peer.id)),
      SheetAction(Icons.swap_horiz_rounded, 'File transfer', () => context.push('/transfer/${peer.id}')),
      SheetAction(Icons.key_rounded, 'Copy key', () {
        Clipboard.setData(ClipboardData(text: peer.id));
        toast(context, 'Key copied');
      }),
      SheetAction(Icons.edit_outlined, 'Set nickname', () async {
        final n = await prompt(context, title: 'Nickname', initial: peer.nickname ?? '', hint: 'Only you see this');
        if (n != null) e.setNickname(peer.id, n.trim().isEmpty ? null : n.trim());
      }),
      SheetAction(peer.blocked ? Icons.check_circle_outline_rounded : Icons.block_rounded,
          peer.blocked ? 'Unblock' : 'Block', () async {
        if (!peer.blocked) {
          final ok = await confirm(context,
              title: 'Block ${peer.name}?',
              body: 'You won\'t see their posts or messages, and anything of theirs kept here is deleted.',
              action: 'Block',
              danger: true);
          if (!ok) return;
        }
        await e.block(peer.id, !peer.blocked);
      }, danger: !peer.blocked),
    ]);
  }
}
