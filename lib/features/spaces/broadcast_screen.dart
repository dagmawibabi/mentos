import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/link_preview.dart';
import '../../net/views.dart';
import '../../net/engine.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import '../calls/live_screen.dart';
import '../chats/composer.dart';
import '../feed/post_card.dart';

/// A channel: one voice at the top, everyone else reads and comments.
class BroadcastScreen extends ConsumerStatefulWidget {
  const BroadcastScreen({
    super.key,
    required this.owner,
    required this.channelId,
    this.spaceId,
    this.title,
  });

  final String owner;
  final String channelId;
  final String? spaceId;
  final String? title;

  @override
  ConsumerState<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends ConsumerState<BroadcastScreen> {
  bool _silent = false;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final posts =
        ref
            .watch(channelFeedProvider((widget.owner, widget.channelId)))
            .value ??
        const <PostView>[];
    final space = widget.spaceId == null ? null : e.space(widget.spaceId!);
    final mine =
        widget.owner == e.me.id ||
        (space != null && space.roleOf(e.me.id).index <= Role.mod.index);
    final bcast = e
        .broadcasts(owner: widget.owner)
        .where((b) => b.id == widget.channelId)
        .firstOrNull;
    final channel = space?.channels
        .where((c) => c.id == widget.channelId)
        .firstOrNull;
    final name =
        widget.title ?? bcast?.name ?? channel?.name ?? e.nameOf(widget.owner);
    final about = (bcast?.about ?? channel?.about ?? '').trim();
    ref.watch(broadcastsProvider);
    final subs = widget.spaceId == null
        ? (bcast == null ? 0 : e.subscribers(bcast).length)
        : (ref.watch(membersProvider(widget.spaceId!)).value ?? const [])
              .length;
    final state = bcast == null
        ? (pinned: null, comments: true)
        : e.channelState(bcast);
    final pinned = state.pinned == null
        ? null
        : posts.where((x) => x.id == state.pinned).firstOrNull;
    final subscribed = bcast != null && e.isSubscribed(bcast.owner, bcast.id);
    final scope = Scope.bcast(widget.owner, widget.channelId);
    final muted = e.db.chat(scope)['muted'] == 1;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () =>
              _info(context, name, about, subs, e.nameOf(widget.owner)),
          child: Row(
            children: [
              Avatar(id: widget.owner, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Txt.heading(p.ink),
                    ),
                    Text(
                      '${compact(subs)} subscriber${subs == 1 ? '' : 's'}',
                      style: Txt.mono(p.muted, size: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (mine && widget.spaceId == null)
            IconBtn(
              _silent
                  ? Icons.notifications_off_outlined
                  : Icons.notifications_none_rounded,
              tooltip: _silent
                  ? 'Silent: subscribers get no notification'
                  : 'Subscribers get notified',
              onTap: () => setState(() => _silent = !_silent),
            ),
          if (bcast != null && bcast.owner == e.me.id)
            IconBtn(
              Icons.person_add_alt_1_rounded,
              tooltip: 'Invite people',
              onTap: () async {
                final peer = await showModalBottomSheet<String>(
                  context: context,
                  isScrollControlled: true,
                  builder: (ctx) => SafeArea(
                    child: SizedBox(
                      height: MediaQuery.sizeOf(ctx).height * .6,
                      child: ListView(
                        children: [
                          const ListTile(
                            title: Text('Invite to channel'),
                            subtitle: Text(
                              'People can subscribe from their invitation.',
                            ),
                          ),
                          for (final person in e.people().where(
                            (x) =>
                                !x.blocked &&
                                x.id != e.me.id &&
                                !e.subscribers(bcast).contains(x.id),
                          ))
                            ListTile(
                              title: Text(e.nameOf(person.id)),
                              trailing: const Icon(Icons.add),
                              onTap: () => Navigator.pop(ctx, person.id),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
                if (peer == null) return;
                try {
                  await e.inviteToChannel(bcast, peer);
                  if (context.mounted) toast(context, 'Invitation sent');
                } catch (err) {
                  if (context.mounted) toast(context, '$err');
                }
              },
            ),
          if (bcast != null && bcast.owner == e.me.id)
            IconBtn(
              Icons.sensors_rounded,
              tooltip: 'Go live',
              onTap: () => goLive(context, ref, bcast),
            ),
          IconBtn(
            Icons.more_horiz_rounded,
            onTap: () =>
                _info(context, name, about, subs, e.nameOf(widget.owner)),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (pinned != null)
            _Pinned(
              text: pinned.text.isNotEmpty ? pinned.text : 'Pinned post',
              onTap: () => context.push('/post/${pinned.id}'),
            )
          else if (about.isNotEmpty)
            _Pinned(
              text: about,
              onTap: () =>
                  _info(context, name, about, subs, e.nameOf(widget.owner)),
            ),
          Expanded(
            child: posts.isEmpty
                ? EmptyState(
                    icon: Icons.campaign_outlined,
                    title: mine ? 'Nothing broadcast yet' : 'Quiet channel',
                    body: mine
                        ? 'What you write here goes to everyone following you. They can comment. Only you post.'
                        : 'Only the owner publishes here. You can reply on a post.',
                  )
                : ListView(
                    reverse: true,
                    padding: const EdgeInsets.only(
                      top: Space.md,
                      bottom: Space.xs,
                    ),
                    children: [
                      for (final post in posts)
                        GestureDetector(
                          onLongPress: mine && bcast != null
                              ? () => showActions(context, [
                                  SheetAction(
                                    Icons.push_pin_outlined,
                                    state.pinned == post.id
                                        ? 'Unpin'
                                        : 'Pin to top',
                                    () => e.setChannelState(
                                      bcast,
                                      pinned: state.pinned == post.id
                                          ? null
                                          : post.id,
                                      comments: state.comments,
                                    ),
                                  ),
                                ])
                              : null,
                          child: PostCard(post: post),
                        ),
                    ],
                  ),
          ),
          if (!mine && bcast != null)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  Space.sm,
                  Space.gutter,
                  Space.sm,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: subscribed
                      ? OutlinedButton.icon(
                          icon: Icon(
                            muted
                                ? Icons.notifications_off_outlined
                                : Icons.notifications_none_rounded,
                            size: 18,
                          ),
                          label: Text(muted ? 'Unmute' : 'Mute'),
                          onPressed: () =>
                              e.updateChat(scope, {'muted': muted ? 0 : 1}),
                        )
                      : FilledButton(
                          onPressed: () => e.subscribe(bcast, true),
                          child: const Text('Subscribe'),
                        ),
                ),
              ),
            ),
          if (mine)
            Composer(
              scope: widget.spaceId == null
                  ? scope
                  : Scope.channel(widget.spaceId!, widget.channelId),
              onCancelReply: () {},
              onCancelEdit: () {},
              publishPost: (text, media, poll) async {
                await e.createPost(
                  text: text,
                  media: media,
                  poll: poll,
                  preview: await previewBody(text),
                  bcastId: widget.spaceId == null ? widget.channelId : null,
                  channelId: widget.spaceId == null ? null : widget.channelId,
                  spaceId: widget.spaceId,
                  silent: _silent,
                );
                if (mounted) setState(() => _silent = false);
              },
            ),
        ],
      ),
    );
  }

  void _info(
    BuildContext context,
    String name,
    String about,
    int subs,
    String ownerName,
  ) {
    final p = context.pal;
    final bcast = ref
        .read(engineProvider)
        .broadcasts(owner: widget.owner)
        .where((b) => b.id == widget.channelId)
        .firstOrNull;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.gutter,
            8,
            Space.gutter,
            Space.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Avatar(id: widget.owner, size: 72),
              const SizedBox(height: 12),
              Text(name, style: Txt.title(p.ink), textAlign: TextAlign.center),
              Text('channel', style: Txt.mono(p.muted, size: 12)),
              const SizedBox(height: 16),
              if (about.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(about, style: Txt.body(p.inkSoft)),
                ),
              const SizedBox(height: 12),
              _InfoRow(label: 'Owner', value: ownerName),
              _InfoRow(label: 'Subscribers', value: compact(subs)),
              _InfoRow(label: 'Posts', value: 'one voice, comments underneath'),
              if (bcast != null) _ChannelControls(bcast: bcast),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(text: '$name\nowner ${widget.owner}'),
                    );
                    toast(ctx, 'Invite copied');
                  },
                  child: const Text('Copy invite'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pinned extends StatelessWidget {
  const _Pinned({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.md,
        Space.gutter,
        0,
      ),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(color: p.line),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.lg),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 12, Space.md, 12),
            child: Row(
              children: [
                Icon(Icons.push_pin_rounded, size: 16, color: p.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.small(p.ink),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: p.faint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Owner and subscriber switches shown in the channel's info sheet.
class _ChannelControls extends ConsumerWidget {
  const _ChannelControls({required this.bcast});
  final Bcast bcast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(broadcastsProvider);
    final e = ref.read(engineProvider);
    final p = context.pal;
    final mine = bcast.owner == e.me.id;
    final state = e.channelState(bcast);
    final subs = e.subscribers(bcast).toList();
    return Column(
      children: [
        if (mine)
          SwitchTile(
            title: 'Comments',
            subtitle: 'Let subscribers reply under posts',
            value: state.comments,
            onChanged: (v) =>
                e.setChannelState(bcast, pinned: state.pinned, comments: v),
          ),
        if (!mine && e.isSubscribed(bcast.owner, bcast.id))
          RowTile(
            title: 'Leave channel',
            danger: true,
            onTap: () {
              e.subscribe(bcast, false);
              Navigator.pop(context);
            },
          ),
        if (mine && subs.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Subscribers', style: Txt.body(p.ink)),
            children: [
              for (final id in subs)
                ListTile(
                  dense: true,
                  leading: Avatar(id: id, size: 30),
                  title: Text(e.nameOf(id)),
                  onTap: () => context.push('/u/$id'),
                ),
            ],
          ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Txt.body(p.ink))),
          Text(value, style: Txt.mono(p.muted, size: 12)),
        ],
      ),
    );
  }
}

class CreateBroadcastSheet {
  static Future<void> open(BuildContext context, WidgetRef ref) async {
    final drafted = await askNamed(
      context,
      title: 'New channel',
      action: 'Create',
      nameMax: 48,
      body: 'You post at the top. Everyone else reads and comments.',
      aboutHint: 'What this channel is for',
    );
    if (drafted == null || drafted.name.trim().isEmpty || !context.mounted)
      return;
    final b = await ref
        .read(engineProvider)
        .createBroadcast(drafted.name.trim(), about: drafted.about.trim());
    if (context.mounted) context.push('/ch/${b.owner}/${b.id}');
  }
}

class BroadcastRow extends ConsumerWidget {
  const BroadcastRow({super.key, required this.channel});
  final Bcast channel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    return InkWell(
      onTap: () => context.push('/ch/${channel.owner}/${channel.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.gutter,
          vertical: 12,
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.raised,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.line),
              ),
              child: Icon(Icons.campaign_outlined, color: p.inkSoft, size: 20),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.bodyStrong(p.ink),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${e.nameOf(channel.owner)} · channel',
                    style: Txt.mono(p.muted, size: 11),
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

class SpaceChannelRow extends ConsumerWidget {
  const SpaceChannelRow({
    super.key,
    required this.space,
    required this.channel,
  });
  final SpaceInfo space;
  final Channel channel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final posts =
        ref.watch(channelFeedProvider((space.id, channel.id))).value ??
        const [];
    return InkWell(
      onTap: () => context.push('/s/${space.id}/c/${channel.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.gutter,
          vertical: 12,
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.raised,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.line),
              ),
              child: Icon(Icons.campaign_outlined, color: p.inkSoft, size: 20),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.bodyStrong(p.ink),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    posts.isEmpty
                        ? 'No broadcasts yet'
                        : (posts.first.text.isEmpty
                              ? 'attachment'
                              : posts.first.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.mono(p.muted, size: 11),
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

class ForumRoomRow extends ConsumerWidget {
  const ForumRoomRow({
    super.key,
    required this.space,
    required this.board,
    this.legacyChannel = false,
  });
  final SpaceInfo space;
  final Channel board;
  final bool legacyChannel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final scope = legacyChannel
        ? Scope.channel(space.id, board.id)
        : Scope.forum(space.id, board.id);
    final msgs = ref.watch(messagesProvider(scope)).value ?? const [];
    final last = msgs.lastOrNull;
    return InkWell(
      onTap: () => context.push(
        legacyChannel
            ? '/s/${space.id}/f/${board.id}?chan=1'
            : '/s/${space.id}/f/${board.id}',
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.gutter,
          vertical: 12,
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.raised,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.line),
              ),
              child: Text(
                '#',
                style: Txt.mono(p.ink, size: 16, w: FontWeight.w500),
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(board.name, style: Txt.bodyStrong(p.ink)),
                  Text(
                    last == null
                        ? 'No messages yet'
                        : '${e.nameOf(last.author)}: ${last.text.isNotEmpty ? last.text : 'attachment'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.small(p.muted),
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
