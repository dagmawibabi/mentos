import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

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
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final posts = ref.watch(channelFeedProvider((widget.owner, widget.channelId))).value ?? const <PostView>[];
    final space = widget.spaceId == null ? null : e.space(widget.spaceId!);
    final mine = widget.owner == e.me.id ||
        (space != null && space.roleOf(e.me.id).index <= Role.mod.index);
    final bcast = e.broadcasts(owner: widget.owner).where((b) => b.id == widget.channelId).firstOrNull;
    final channel = space?.channels.where((c) => c.id == widget.channelId).firstOrNull;
    final name = widget.title ?? bcast?.name ?? channel?.name ?? e.nameOf(widget.owner);
    final about = (bcast?.about ?? channel?.about ?? '').trim();
    final subs = widget.spaceId == null
        ? (ref.watch(peopleProvider).value ?? const []).where((x) => x.iFollow || x.followsMe).length
        : (ref.watch(membersProvider(widget.spaceId!)).value ?? const []).length;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => _info(context, name, about, subs, e.nameOf(widget.owner)),
          child: Row(
            children: [
              Avatar(id: widget.owner, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.heading(p.ink)),
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
          IconBtn(Icons.more_horiz_rounded, onTap: () => _info(context, name, about, subs, e.nameOf(widget.owner))),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (about.isNotEmpty) _Pinned(text: about, onTap: () => _info(context, name, about, subs, e.nameOf(widget.owner))),
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
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    children: [
                      for (final post in posts) _ChannelPost(post: post),
                    ],
                  ),
          ),
          if (mine)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _text,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(hintText: 'Broadcast'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconBtn(
                      Icons.send_rounded,
                      onTap: _sending ? null : _send,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref.read(engineProvider).createPost(
            text: text,
            bcastId: widget.spaceId == null ? widget.channelId : null,
            channelId: widget.spaceId == null ? null : widget.channelId,
            spaceId: widget.spaceId,
          );
      _text.clear();
    } catch (err) {
      if (mounted) toast(context, 'Could not broadcast: $err');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _info(BuildContext context, String name, String about, int subs, String ownerName) {
    final p = context.pal;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, Space.lg),
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
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: '$name\nowner ${widget.owner}'));
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Icon(Icons.push_pin_rounded, size: 16, color: p.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.small(p.ink)),
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

class _ChannelPost extends ConsumerWidget {
  const _ChannelPost({required this.post});
  final PostView post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: () => context.push('/post/${post.id}'),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.nameOf(post.author), style: Txt.small(p.accent).copyWith(fontWeight: FontWeight.w600)),
                if (post.title.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(post.title, style: Txt.bodyStrong(p.ink)),
                ],
                if (post.text.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(post.text, style: Txt.body(p.ink)),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (post.likes > 0) ...[
                      Icon(Icons.favorite_rounded, size: 14, color: p.danger),
                      const SizedBox(width: 4),
                      Text('${post.likes}', style: Txt.mono(p.muted, size: 11)),
                      const SizedBox(width: 12),
                    ],
                    const Spacer(),
                    Icon(Icons.visibility_outlined, size: 14, color: p.faint),
                    const SizedBox(width: 4),
                    Text('${post.views}', style: Txt.mono(p.faint, size: 11)),
                    const SizedBox(width: 8),
                    Text(
                      post.edited ? 'edited ${clock(post.item.ts)}' : clock(post.item.ts),
                      style: Txt.mono(p.faint, size: 11),
                    ),
                  ],
                ),
                if (post.comments > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${post.comments} comment${post.comments == 1 ? '' : 's'}',
                      style: Txt.small(p.accent),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
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
    final drafted = await showDialog<({String name, String about})>(
      context: context,
      builder: (ctx) => const _NewChannelDialog(),
    );
    if (drafted == null || drafted.name.trim().isEmpty) return;
    final b = await ref.read(engineProvider).createBroadcast(drafted.name.trim(), about: drafted.about.trim());
    if (context.mounted) context.push('/ch/${b.owner}/${b.id}');
  }
}

class _NewChannelDialog extends StatefulWidget {
  const _NewChannelDialog();

  @override
  State<_NewChannelDialog> createState() => _NewChannelDialogState();
}

class _NewChannelDialogState extends State<_NewChannelDialog> {
  final _name = TextEditingController();
  final _about = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New channel'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 48,
            decoration: const InputDecoration(hintText: 'Name', counterText: ''),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _about,
            maxLength: 240,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'What this channel is for',
              counterText: '',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, (name: name, about: _about.text.trim()));
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class BroadcastRow extends ConsumerWidget {
  const BroadcastRow({super.key, required this.channel});
  final Bcast channel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: p.raised,
        child: Icon(Icons.campaign_outlined, color: p.inkSoft, size: 20),
      ),
      title: Text(channel.name),
      subtitle: Text('${e.nameOf(channel.owner)} · channel', style: Txt.mono(p.muted, size: 11)),
      onTap: () => context.push('/ch/${channel.owner}/${channel.id}'),
    );
  }
}

class SpaceChannelRow extends ConsumerWidget {
  const SpaceChannelRow({super.key, required this.space, required this.channel});
  final SpaceInfo space;
  final Channel channel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final posts = ref.watch(channelFeedProvider((space.id, channel.id))).value ?? const [];
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: p.raised,
        child: Icon(Icons.campaign_outlined, color: p.inkSoft, size: 20),
      ),
      title: Text(channel.name),
      subtitle: Text(
        posts.isEmpty ? 'No broadcasts yet' : (posts.first.text.isEmpty ? 'attachment' : posts.first.text),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Txt.mono(p.muted, size: 11),
      ),
      onTap: () => context.push('/s/${space.id}/c/${channel.id}'),
    );
  }
}

class ForumRoomRow extends ConsumerWidget {
  const ForumRoomRow({super.key, required this.space, required this.board, this.legacyChannel = false});
  final SpaceInfo space;
  final Channel board;
  final bool legacyChannel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final scope = legacyChannel ? Scope.channel(space.id, board.id) : Scope.forum(space.id, board.id);
    final msgs = ref.watch(messagesProvider(scope)).value ?? const [];
    final last = msgs.lastOrNull;
    return InkWell(
      onTap: () => context.push(legacyChannel ? '/s/${space.id}/f/${board.id}?chan=1' : '/s/${space.id}/f/${board.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(10)),
              child: Text('#', style: Txt.mono(p.ink, size: 16, w: FontWeight.w500)),
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
