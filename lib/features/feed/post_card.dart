import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/views.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/link_card.dart';
import '../../widgets/media.dart';
import '../../widgets/nsfw.dart';
import '../../widgets/invite_card.dart';
import '../../widgets/ui.dart';
import 'tag_screen.dart';
import '../chats/share_sheet.dart';

/// Who saw a post. Authors see names; everyone else sees the count.
void showViewers(BuildContext context, WidgetRef ref, PostView post) {
  final e = ref.read(engineProvider);
  if (post.author != e.me.id) {
    toast(context, '${post.views} ${post.views == 1 ? 'view' : 'views'}');
    return;
  }
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final p = ctx.pal;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * .7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  0,
                  Space.gutter,
                  Space.sm,
                ),
                child: Text(
                  '${post.views} ${post.views == 1 ? 'view' : 'views'}',
                  style: Txt.title(p.ink),
                ),
              ),
              if (post.viewers.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Space.gutter),
                  child: Text(
                    'No views yet. A view counts when someone has your post on screen for a moment.',
                    style: Txt.small(p.muted),
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final id in post.viewers)
                      ListTile(
                        leading: Avatar(id: id, size: 34),
                        title: Text(e.nameOf(id)),
                        onTap: () {
                          Navigator.pop(ctx);
                          context.push('/u/$id');
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Counts a view once a post has stayed on screen for a moment, like an
/// impression on X. [Engine.recordView] sends at most one per post.
class _Impression extends ConsumerStatefulWidget {
  const _Impression({required this.post, required this.child});
  final PostView post;
  final Widget child;

  @override
  ConsumerState<_Impression> createState() => _ImpressionState();
}

class _ImpressionState extends ConsumerState<_Impression> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      final e = ref.read(maybeEngineProvider);
      if (e != null && widget.post.author != e.me.id)
        unawaited(e.recordView(widget.post.item));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class PostCard extends ConsumerWidget {
  const PostCard({super.key, required this.post, this.detailed = false});
  final PostView post;
  final bool detailed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final author = ref.watch(peerProvider(post.author)).value;
    final name = post.author == e.me.id
        ? (e.myProfile.displayName)
        : (author?.name ?? alias(post.author));
    final prov = ProvenanceTag.of(post.item);

    final hasBody =
        post.title.isNotEmpty ||
        post.text.isNotEmpty ||
        post.repost != null ||
        post.media.isNotEmpty ||
        post.poll != null;

    return _Impression(
      post: post,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Space.sm,
          detailed ? Space.sm : 0,
          Space.sm,
          detailed ? Space.sm : Space.sm,
        ),
        child: Pressable(
          onTap: detailed
              ? null
              : () async {
                  final files = post.media
                      .where((m) => !m.isImage && !m.isVideo && !m.isAudio)
                      .toList();
                  if (files.length == 1 &&
                      post.text.isEmpty &&
                      post.poll == null) {
                    final f = await e.openMedia(files.first, post.item);
                    if (!context.mounted) return;
                    if (f == null) {
                      toast(
                        context,
                        'File not reachable — the sender is offline.',
                      );
                      return;
                    }
                    await showLocalFile(context, f, name: files.first.name, mime: files.first.mime);
                    return;
                  }
                  context.push('/post/${post.id}');
                },
          onLongPress: () => showPostActions(context, ref, post),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: p.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, 2, 0),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => post.author == e.me.id
                            ? context.go('/me')
                            : context.push('/u/${post.author}'),
                        child: Avatar(id: post.author, size: 38),
                      ),
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
                                if (_badge(ref, post.author)) ...[
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.verified_rounded,
                                    size: 15,
                                    color: p.accent,
                                  ),
                                ],
                                if (post.ai) ...[
                                  const SizedBox(width: 6),
                                  _Flag('AI', fg: p.danger, bg: p.dangerSoft),
                                ],
                                if (post.nsfw) ...[
                                  const SizedBox(width: 6),
                                  _Flag('NSFW', fg: p.danger, bg: p.dangerSoft),
                                ],
                                if (prov != Provenance.mine) ...[
                                  const SizedBox(width: 6),
                                  ProvenanceTag(prov, compact: true),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                timeAgo(post.item.ts),
                                if (post.edited) 'edited',
                                if (post.spaceId != null) 'in space',
                              ].join(' · '),
                              style: Txt.mono(p.muted, size: 11),
                            ),
                          ],
                        ),
                      ),
                      IconBtn(
                        Icons.more_horiz_rounded,
                        color: p.muted,
                        size: 20,
                        onTap: () => showPostActions(context, ref, post),
                      ),
                    ],
                  ),
                ),
                if (hasBody)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Space.lg,
                      Space.md,
                      Space.lg,
                      Space.lg,
                    ),
                    child: NsfwGate(
                      nsfw: post.nsfw,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (post.title.isNotEmpty)
                            Text(post.title, style: Txt.heading(p.ink)),
                          if (post.text.isNotEmpty) ...[
                            if (post.title.isNotEmpty)
                              const SizedBox(height: Space.sm),
                            _TaggedText(text: post.text, detailed: detailed),
                            LinkCard(text: post.text, attached: post.preview),
                            if (firstInvite(post.text) != null) InviteCard(text: post.text),
                          ],
                          if (post.repost != null) ...[
                            if (post.title.isNotEmpty || post.text.isNotEmpty)
                              const SizedBox(height: Space.md),
                            RepostEmbed(data: post.repost!),
                          ],
                          if (post.media.any(
                            (m) => m.isImage || m.isVideo,
                          )) ...[
                            if (post.title.isNotEmpty ||
                                post.text.isNotEmpty ||
                                post.repost != null)
                              const SizedBox(height: Space.md),
                            MediaGrid(media: post.media, item: post.item),
                          ],
                          for (final m in post.media.where(
                            (m) => !m.isImage && !m.isVideo,
                          )) ...[
                            const SizedBox(height: Space.sm),
                            m.isAudio
                                ? Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: p.raised,
                                      borderRadius: BorderRadius.circular(
                                        Radii.md,
                                      ),
                                    ),
                                    child: VoicePlayer(
                                      media: m,
                                      item: post.item,
                                      fg: p.ink,
                                      track: p.raised,
                                    ),
                                  )
                                : FileTile(
                                    media: m,
                                    item: post.item,
                                    fg: p.ink,
                                    bg: p.raised,
                                  ),
                          ],
                          if (post.poll != null) ...[
                            if (post.title.isNotEmpty ||
                                post.text.isNotEmpty ||
                                post.repost != null ||
                                post.media.isNotEmpty)
                              const SizedBox(height: Space.md),
                            PollView(
                              state: post.poll!,
                              onVote: (i) => e.vote(
                                post.scope,
                                post.id,
                                post.poll!.myVote == i ? null : i,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                else
                  const SizedBox(height: Space.md),
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: p.line)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Space.sm,
                      2,
                      Space.sm,
                      2,
                    ),
                    child: _Actions(post: post),
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

class _Flag extends StatelessWidget {
  const _Flag(this.label, {required this.fg, required this.bg});
  final String label;
  final Color fg;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(label, style: Txt.mono(fg, size: 10, w: FontWeight.w600)),
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.post});
  final PostView post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    return Row(
      children: [
        _Action(
          icon: post.liked
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          color: post.liked ? p.ink : p.muted,
          count: post.likes,
          onTap: () {
            HapticFeedback.lightImpact();
            e.like(post.scope, post.id, !post.liked);
          },
          onCount: post.author == e.me.id
              ? () => showLikers(context, ref, post)
              : null,
        ),
        _Action(
          icon: Icons.mode_comment_outlined,
          color: p.muted,
          count: post.comments,
          onTap: () => context.push('/post/${post.id}'),
        ),
        _Action(
          icon: Icons.repeat_rounded,
          color: p.muted,
          onTap: () => context.push('/compose?repost=${post.id}'),
        ),
        _Action(
          icon: Icons.send_outlined,
          color: p.muted,
          onTap: () => showShareSheet(context, ref, post),
        ),
        const Spacer(),
        if (post.views > 0 || post.author == e.me.id)
          _Action(
            icon: Icons.bar_chart_rounded,
            color: p.muted,
            count: post.views,
            onTap: () => showViewers(context, ref, post),
          ),
        _Action(
          icon: post.bookmarked
              ? Icons.bookmark_rounded
              : Icons.bookmark_border_rounded,
          color: post.bookmarked ? p.ink : p.muted,
          onTap: () {
            HapticFeedback.selectionClick();
            e.setBookmark(post, !post.bookmarked);
          },
        ),
      ],
    );
  }
}

bool _badge(WidgetRef ref, String id) {
  final coin = ref.watch(coinProvider);
  if (coin == null) return false;
  return coin.hasBadge(id);
}

void showLikers(BuildContext context, WidgetRef ref, PostView post) {
  final e = ref.read(engineProvider);
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(Space.gutter),
            child: Text(
              '${post.likes} ${post.likes == 1 ? 'like' : 'likes'}',
              style: Txt.title(ctx.pal.ink),
            ),
          ),
          if (post.likers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(Space.gutter),
              child: Text('Names show for likes this phone has seen.'),
            ),
          for (final id in post.likers)
            ListTile(
              leading: Avatar(id: id, size: 34),
              title: Text(e.nameOf(id)),
              onTap: () {
                Navigator.pop(ctx);
                context.push('/u/$id');
              },
            ),
        ],
      ),
    ),
  );
}

class _TaggedText extends StatelessWidget {
  const _TaggedText({required this.text, required this.detailed});
  final String text;
  final bool detailed;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final style = detailed
        ? Txt.body(p.ink).copyWith(fontSize: 17, height: 1.45)
        : Txt.body(p.ink);
    return TaggedText(text: withoutInvites(text), style: style, maxLines: detailed ? null : 12);
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.color,
    required this.onTap,
    this.count,
    this.onCount,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback? onCount;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: Motion.fast,
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: Icon(icon, key: ValueKey(icon), size: 20, color: color),
            ),
            if (count != null && count! > 0) ...[
              const SizedBox(width: 5),
              GestureDetector(
                onTap: onCount,
                child: Text(
                  compact(count!),
                  style: Txt.mono(p.muted, size: 12),
                ),
              ),
            ],
            if (count == null || count == 0) const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class RepostEmbed extends ConsumerWidget {
  const RepostEmbed({super.key, required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final author = data['author'] is String ? data['author'] as String : '';
    final id = data['id'] is String ? data['id'] as String : '';
    final peer = ref.watch(peerProvider(author)).value;
    final live = ref.watch(postProvider(id)).value;
    return GestureDetector(
      onTap: () => context.push('/post/$id'),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Avatar(id: author, size: 20, presence: false),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    peer?.name ?? alias(author),
                    style: Txt.small(p.ink)
                        .copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
                ProvenanceTag(
                  live == null ? Provenance.local : ProvenanceTag.of(live.item),
                  compact: true,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              live?.text ??
                  (data['text'] is String ? data['text'] as String : ''),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: Txt.small(live == null ? p.muted : p.inkSoft),
            ),
            if (live == null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Original shows when its author is online',
                  style: Txt.mono(p.faint, size: 10.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class PollView extends StatelessWidget {
  const PollView({
    super.key,
    required this.state,
    required this.onVote,
    this.fg,
    this.track,
  });
  final PollState state;
  final ValueChanged<int> onVote;
  final Color? fg;
  final Color? track;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final ink = fg ?? p.ink;
    final bg = track ?? p.raised;
    final voted = state.myVote != null || state.locked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.poll.question.isNotEmpty) ...[
          Text(state.poll.question, style: Txt.bodyStrong(ink)),
          const SizedBox(height: Space.sm),
        ],
        for (var i = 0; i < state.poll.options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              onTap: state.locked ? null : () => onVote(i),
              child: LayoutBuilder(
                builder: (context, c) {
                  final frac = state.total == 0
                      ? 0.0
                      : state.counts[i] / state.total;
                  final mine = state.myVote == i;
                  return Container(
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(Radii.sm + 2),
                      border: Border.all(color: mine ? p.accent : p.line),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedContainer(
                          duration: Motion.slow,
                          curve: Motion.curve,
                          width: voted ? c.maxWidth * frac : 0,
                          decoration: BoxDecoration(
                            color: mine ? p.accentSoft : bg,
                            borderRadius: BorderRadius.circular(Radii.sm + 1),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              if (mine) ...[
                                Icon(
                                  Icons.check_rounded,
                                  size: 16,
                                  color: p.accent,
                                ),
                                const SizedBox(width: 6),
                              ],
                              Expanded(
                                child: Text(
                                  state.poll.options[i],
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Txt.small(ink),
                                ),
                              ),
                              if (voted)
                                Text(
                                  '${(frac * 100).round()}%',
                                  style: Txt.mono(
                                    ink.withValues(alpha: .7),
                                    size: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        Text(
          '${state.total} ${state.total == 1 ? 'vote' : 'votes'}${state.locked ? ' · closed' : ''} · counts from people online or kept',
          style: Txt.mono(ink.withValues(alpha: .5), size: 10.5),
        ),
      ],
    );
  }
}

Future<void> showPostActions(
  BuildContext context,
  WidgetRef ref,
  PostView post,
) {
  final e = ref.read(engineProvider);
  final mine = post.author == e.me.id;
  return showActions(context, [
    if (post.text.isNotEmpty)
      SheetAction(Icons.copy_rounded, 'Copy text', () {
        Clipboard.setData(ClipboardData(text: post.text));
        toast(context, 'Copied');
      }),
    SheetAction(
      post.bookmarked
          ? Icons.bookmark_remove_outlined
          : Icons.bookmark_add_outlined,
      post.bookmarked ? 'Remove bookmark' : 'Bookmark',
      () => e.setBookmark(post, !post.bookmarked),
    ),
    SheetAction(
      Icons.send_outlined,
      'Send in a chat',
      () => showShareSheet(context, ref, post),
    ),
    SheetAction(Icons.ios_share_rounded, 'Share outside Mentos', () {
      SharePlus.instance.share(
        ShareParams(text: post.text.isEmpty ? 'A post on Mentos' : post.text),
      );
    }),
    if (mine) ...[
      if (post.poll != null && !post.poll!.locked)
        SheetAction(
          Icons.stop_circle_outlined,
          'Stop poll',
          () => e.closePoll(post.item),
        ),
      SheetAction(Icons.edit_outlined, 'Edit', () async {
        final t = await prompt(
          context,
          title: 'Edit post',
          body: 'People who already have this post see the new text.',
          initial: post.text,
          maxLength: 2000,
          action: 'Save',
          allowEmpty: false,
        );
        if (t != null && t.trim().isNotEmpty && t != post.text)
          await e.edit(post.scope, post.id, t.trim());
      }),
      SheetAction(Icons.delete_outline_rounded, 'Delete everywhere', () async {
        final ok = await confirm(
          context,
          title: 'Delete this post?',
          body: 'It is removed from this phone and peers who kept a copy are told to delete theirs.',
          action: 'Delete',
          danger: true,
        );
        if (ok) await e.deleteItem(post.item);
      }, danger: true),
    ] else ...[
      SheetAction(
        Icons.person_outline_rounded,
        'View profile',
        () => context.push('/u/${post.author}'),
      ),
      SheetAction(
        Icons.block_rounded,
        'Block ${e.nameOf(post.author)}',
        () async {
          final ok = await confirm(
            context,
            title: 'Block ${e.nameOf(post.author)}?',
            body: 'You won\'t see their posts or messages, and anything of theirs kept here is deleted.',
            action: 'Block',
            danger: true,
          );
          if (ok) await e.block(post.author, true);
        },
        danger: true,
      ),
    ],
  ]);
}
