import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/engine.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import '../spaces/broadcast_screen.dart';
import '../spaces/channels_screen.dart';
import 'bubble.dart';

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  String _q = '';
  String _folder = '';
  bool _archived = false;

  void _select(BuildContext context, InboxPane pane) {
    ref.read(inboxPaneProvider.notifier).show(pane);
    setState(() {
      _archived = false;
      _q = '';
    });
    final name = switch (pane) {
      InboxPane.chats => 'chats',
      InboxPane.groups => 'groups',
      InboxPane.channels => 'channels',
    };
    GoRouter.maybeOf(context)?.go('/chats?tab=$name');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const SizedBox.shrink();
    final saved = ref.watch(inboxPaneProvider);
    final tab = GoRouter.maybeOf(context)?.state.uri.queryParameters['tab'];
    final pane = switch (tab) {
      'channels' => InboxPane.channels,
      'groups' => InboxPane.groups,
      'spaces' => InboxPane.channels,
      'chats' => InboxPane.chats,
      _ => saved,
    };
    final title = _archived ? 'Archived' : 'Spaces';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: _archived
            ? IconBtn(
                Icons.arrow_back_rounded,
                onTap: () => setState(() => _archived = false),
              )
            : null,
        actions: [
          if (_archived || pane == InboxPane.chats) ...[
            IconBtn(
              Icons.call_outlined,
              tooltip: 'Calls',
              onTap: () => context.push('/calls'),
            ),
            IconBtn(
              Icons.swap_horiz_rounded,
              tooltip: 'File transfer',
              onTap: () => context.push('/transfer'),
            ),
            IconBtn(
              Icons.edit_square,
              tooltip: 'New chat',
              onTap: () => _newChat(context),
            ),
          ],
          if (!_archived && pane == InboxPane.groups)
            IconBtn(
              Icons.group_add_outlined,
              tooltip: 'New group',
              onTap: () => context.push('/new-group'),
            ),
          if (!_archived && pane == InboxPane.channels) ...[
            IconBtn(
              Icons.groups_outlined,
              tooltip: 'Communities',
              onTap: () => context.push('/communities'),
            ),
            IconBtn(
              Icons.add_rounded,
              tooltip: 'New channel',
              onTap: () => CreateBroadcastSheet.open(context, ref),
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (!_archived)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.gutter,
                0,
                Space.gutter,
                Space.sm,
              ),
              child: Segmented<InboxPane>(
                value: pane,
                options: const {
                  InboxPane.chats: 'Chats',
                  InboxPane.groups: 'Groups',
                  InboxPane.channels: 'Channels',
                },
                onChanged: (next) => _select(context, next),
              ),
            ),
          Expanded(
            child: switch (pane) {
              InboxPane.channels when !_archived => const ChannelsScreen(
                embedded: true,
              ),
              _ => _conversations(
                context,
                p,
                e,
                groups: pane == InboxPane.groups,
              ),
            },
          ),
        ],
      ),
    );
  }

  Widget _conversations(
    BuildContext context,
    Palette p,
    Engine e, {
    required bool groups,
  }) {
    final all = ref.watch(chatsProvider).value ?? const <ChatSummary>[];
    final filtered = all
        .where((c) => c.archived == _archived)
        .where((c) => c.group == groups && !c.broadcast)
        .where((c) => _folder.isEmpty || e.chatFolder(c.scope) == _folder)
        .where((c) {
          final name = (c.group ? c.title : e.nameOf(c.peer)).toLowerCase();
          return _q.isEmpty || name.contains(_q.toLowerCase());
        })
        .toList();
    final folders = {
      for (final c in all)
        if (e.chatFolder(c.scope).isNotEmpty) e.chatFolder(c.scope),
    };
    final archivedCount = all.where((c) => c.archived).length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.gutter,
            0,
            Space.gutter,
            Space.sm,
          ),
          child: TextField(
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: 'Search',
              prefixIcon: Icon(Icons.search_rounded, color: p.faint, size: 20),
            ),
          ),
        ),
        if (folders.isNotEmpty)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              children: [
                for (final f in ['', ...folders])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.isEmpty ? 'All' : f),
                      selected: _folder == f,
                      onSelected: (_) => setState(() => _folder = f),
                    ),
                  ),
              ],
            ),
          ),
        if (!_archived && archivedCount > 0)
          RowTile(
            icon: Icons.archive_outlined,
            title: 'Archived',
            trailing: CountBadge(archivedCount, muted: true),
            onTap: () => setState(() => _archived = true),
          ),
        Expanded(
          child: filtered.isEmpty
              ? EmptyState(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: _q.isNotEmpty
                      ? 'No matches'
                      : (groups ? 'No groups' : 'No conversations'),
                  body: _q.isNotEmpty
                      ? null
                      : (groups
                            ? 'Start a group from the button above.'
                            : 'Add someone with their QR code and start talking — directly, phone to phone.'),
                  action: _q.isNotEmpty
                      ? null
                      : OutlinedButton.icon(
                          onPressed: () => _newChat(context),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('New chat'),
                        ),
                )
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => _ChatRow(c: filtered[i]),
                ),
        ),
      ],
    );
  }

  Future<void> _newChat(BuildContext context) async {
    final e = ref.read(engineProvider);
    final people = e.people().where((x) => !x.blocked).toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final p = ctx.pal;
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * .65,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  0,
                  Space.gutter,
                  Space.sm,
                ),
                child: Text('New chat', style: Txt.heading(p.ink)),
              ),
              RowTile(
                icon: Icons.campaign_outlined,
                title: 'New channel',
                subtitle: 'Broadcast to everyone who follows you',
                onTap: () {
                  Navigator.pop(ctx);
                  CreateBroadcastSheet.open(context, ref);
                },
              ),
              RowTile(
                icon: Icons.group_add_outlined,
                title: 'New group',
                subtitle: 'Chat with several people at once',
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/new-group');
                },
              ),
              RowTile(
                icon: Icons.qr_code_scanner_rounded,
                title: 'Add someone new',
                subtitle: 'Scan a QR code or paste a contact link',
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/connect');
                },
              ),
              const Hairline(),
              Expanded(
                child: ListView(
                  children: [
                    for (final x in people)
                      ListTile(
                        leading: Avatar(id: x.id, size: 38),
                        title: Text(x.name),
                        subtitle: Text(
                          shortId(x.id),
                          style: Txt.mono(p.muted, size: 11),
                        ),
                        onTap: () => Navigator.pop(ctx, x.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked != null && context.mounted) context.push('/chat/$picked');
  }
}

class _ChatRow extends ConsumerWidget {
  const _ChatRow({required this.c});
  final ChatSummary c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final name = c.group
        ? (c.title.isEmpty ? 'Group' : c.title)
        : (ref.watch(peerProvider(c.peer)).value?.name ?? alias(c.peer));
    final last = c.last;
    final preview = c.typing
        ? 'typing…'
        : c.pendingOffer
        ? 'wants you to keep their messages'
        : last == null
        ? 'no messages yet'
        : '${last.mine ? 'You: ' : ''}${previewOf(last)}';
    final synced =
        c.syncMine == GrantState.active && c.syncTheirs == GrantState.active;

    return InkWell(
      onTap: () => context.push(c.group ? '/g/${c.peer}' : '/chat/${c.peer}'),
      onLongPress: () => showActions(context, [
        SheetAction(
          c.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
          c.pinned ? 'Unpin' : 'Pin',
          () => e.updateChat(c.scope, {'pinned': c.pinned ? 0 : 1}),
        ),
        SheetAction(
          c.muted
              ? Icons.notifications_active_outlined
              : Icons.notifications_off_outlined,
          c.muted ? 'Unmute' : 'Mute',
          () => e.updateChat(c.scope, {'muted': c.muted ? 0 : 1}),
        ),
        SheetAction(
          c.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
          c.archived ? 'Unarchive' : 'Archive',
          () => e.updateChat(c.scope, {'archived': c.archived ? 0 : 1}),
        ),
        SheetAction(Icons.folder_outlined, 'Folder', () async {
          final folders = {
            for (final other in e.chats())
              if (e.chatFolder(other.scope).isNotEmpty)
                e.chatFolder(other.scope),
          }.toList()..sort();
          final name = await prompt(
            context,
            title: 'Folder',
            body: 'Chats in the same folder sit together. Clear it to take this chat out.',
            initial: e.chatFolder(c.scope),
            hint: 'Family, work, …',
            maxLength: 24,
            selectAll: true,
            suggestions: folders,
            capitalization: TextCapitalization.words,
          );
          if (name != null) e.setChatFolder(c.scope, name);
        }),
        SheetAction(
          Icons.mark_chat_read_outlined,
          'Mark as read',
          () => e.markRead(c.scope),
        ),
        SheetAction(
          Icons.delete_outline_rounded,
          'Clear on this phone',
          () => e.clearChat(c.scope),
          danger: true,
        ),
      ], title: name.toUpperCase()),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.gutter,
          vertical: 12,
        ),
        child: Row(
          children: [
            c.group
                ? Container(
                    width: 50,
                    height: 50,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: p.raised,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: p.line),
                    ),
                    child: Icon(Icons.groups_rounded, color: p.inkSoft),
                  )
                : Avatar(id: c.peer, size: 50),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Txt.bodyStrong(p.ink),
                        ),
                      ),
                      if (synced) ...[
                        const SizedBox(width: 5),
                        Icon(
                          Icons.cloud_done_rounded,
                          size: 14,
                          color: p.accent,
                        ),
                      ],
                      if (c.muted) ...[
                        const SizedBox(width: 5),
                        Icon(
                          Icons.notifications_off_outlined,
                          size: 14,
                          color: p.faint,
                        ),
                      ],
                      if (c.pinned) ...[
                        const SizedBox(width: 5),
                        Icon(Icons.push_pin_rounded, size: 13, color: p.faint),
                      ],
                      const Spacer(),
                      if (last != null)
                        Text(
                          timeAgo(last.ts),
                          style: Txt.mono(
                            c.unread > 0 ? p.accent : p.faint,
                            size: 11,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (last != null && last.mine && !c.typing) ...[
                        Icon(
                          switch (last.delivery) {
                            Delivery.sending => Icons.schedule_rounded,
                            Delivery.failed => Icons.error_outline_rounded,
                            Delivery.sent => Icons.check_rounded,
                            _ => Icons.done_all_rounded,
                          },
                          size: 14,
                          color: last.delivery == Delivery.read
                              ? p.accent
                              : p.faint,
                        ),
                        const SizedBox(width: 3),
                      ],
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: c.typing || c.pendingOffer
                              ? Txt.small(p.accent)
                              : Txt.small(last == null ? p.faint : p.muted),
                        ),
                      ),
                      if (c.unread > 0) ...[
                        const SizedBox(width: 8),
                        CountBadge(c.unread, muted: c.muted),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
