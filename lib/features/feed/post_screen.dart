import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/engine.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/media.dart';
import '../../widgets/ui.dart';
import '../common/attach.dart';
import 'post_card.dart';

class PostScreen extends ConsumerStatefulWidget {
  const PostScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends ConsumerState<PostScreen> {
  final _c = TextEditingController();
  final _focus = FocusNode();
  CommentView? _replyTo;
  final _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    _c.addListener(() => setState(() {}));
  }

  Future<void> _send(PostView post, {List<Pending> media = const []}) async {
    final t = _c.text.trim();
    if (t.isEmpty && media.isEmpty) return;
    _c.clear();
    final reply = _replyTo;
    setState(() => _replyTo = null);
    final e = ref.read(engineProvider);
    final refs = <MediaRef>[];
    for (final x in media) {
      refs.add(await importPending(e, x, scope: post.scope));
    }
    await e.comment(post, t, replyTo: reply?.item.id, media: refs);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final post = ref.watch(postProvider(widget.id));
    final comments =
        ref.watch(commentsProvider(widget.id)).value ?? const <CommentView>[];
    final e = ref.read(engineProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: post.when(
        loading: () => const Loading(),
        error: (err, _) => Center(child: Text('$err')),
        data: (pv) {
          if (pv == null) {
            return const EmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Not reachable right now',
              body:
                  'This post lives on its author\'s phone. It shows up again when they\'re online, '
                  'or if someone you follow keeps a copy.',
            );
          }
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => e.recordView(pv.item),
          );
          final rows = threadComments(comments, _collapsed);
          final open = e.commentsOpen(pv);
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: Space.lg),
                  children: [
                    PostCard(post: pv, detailed: true),
                    SectionLabel(
                      !open
                          ? 'Comments are off'
                          : comments.isEmpty
                          ? 'No comments yet'
                          : '${comments.length} comments',
                      trailing: Text(
                        'from people online or kept',
                        style: Txt.mono(p.faint, size: 10.5),
                      ),
                    ),
                    for (final row in rows)
                      _CommentTile(
                        c: row.c,
                        depth: row.depth,
                        replies: row.replies,
                        collapsed: _collapsed.contains(row.c.item.id),
                        orphan: row.orphan,
                        onToggle: row.replies == 0
                            ? null
                            : () => setState(() => _collapsed.contains(row.c.item.id)
                                ? _collapsed.remove(row.c.item.id)
                                : _collapsed.add(row.c.item.id)),
                        onReply: () {
                          setState(() => _replyTo = row.c);
                          _focus.requestFocus();
                        },
                        onLike: () => e.like(pv.scope, row.c.item.id, !row.c.liked),
                        onDelete: row.c.item.author == e.me.id
                            ? () => e.deleteItem(row.c.item)
                            : null,
                      ),
                    const SizedBox(height: Space.xl),
                  ],
                ),
              ),
              if (open)
                Container(
                  decoration: BoxDecoration(
                    color: p.bg,
                    border: Border(top: BorderSide(color: p.line)),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_replyTo != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              Space.gutter,
                              Space.sm,
                              Space.xs,
                              0,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.reply_rounded,
                                  size: 16,
                                  color: p.muted,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Replying to ${e.nameOf(_replyTo!.item.author)}',
                                    style: Txt.small(p.muted),
                                  ),
                                ),
                                IconBtn(
                                  Icons.close_rounded,
                                  size: 16,
                                  color: p.muted,
                                  onTap: () => setState(() => _replyTo = null),
                                ),
                              ],
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            Space.gutter,
                            Space.sm,
                            Space.xs,
                            Space.sm,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Avatar(id: e.me.id, size: 30, presence: false),
                              IconBtn(
                                Icons.image_outlined,
                                tooltip: 'Image',
                                onTap: () async {
                                  final picked = await pickImages(context: context);
                                  if (picked.isNotEmpty)
                                    await _send(pv, media: picked);
                                },
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: _c,
                                  focusNode: _focus,
                                  minLines: 1,
                                  maxLines: 4,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  decoration: const InputDecoration(
                                    hintText: 'Add a comment',
                                  ),
                                ),
                              ),
                              IconBtn(
                                Icons.arrow_upward_rounded,
                                active: _c.text.trim().isNotEmpty,
                                onTap: _c.text.trim().isEmpty
                                    ? null
                                    : () => _send(pv),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// One comment in thread order, with how deep it sits and how many replies
/// hang under it.
typedef CommentRow = ({CommentView c, int depth, int replies, bool orphan});

/// Orders comments as a tree: each reply right under the comment it answers,
/// oldest first at every level. Replies to a comment this phone does not
/// have start their own thread. Collapsed comments hide their whole subtree.
List<CommentRow> threadComments(List<CommentView> comments, Set<String> collapsed) {
  final ids = {for (final c in comments) c.item.id};
  final children = <String?, List<CommentView>>{};
  for (final c in comments) {
    final parent = c.replyTo != null && ids.contains(c.replyTo) && c.replyTo != c.item.id ? c.replyTo : null;
    (children[parent] ??= []).add(c);
  }
  for (final list in children.values) {
    list.sort((a, b) => a.item.ts.compareTo(b.item.ts));
  }
  int count(String id, Set<String> seen) {
    var n = 0;
    for (final k in children[id] ?? const <CommentView>[]) {
      if (!seen.add(k.item.id)) continue;
      n += 1 + count(k.item.id, seen);
    }
    return n;
  }

  final out = <CommentRow>[];
  final placed = <String>{};
  void walk(CommentView c, int depth) {
    if (!placed.add(c.item.id)) return;
    final replies = count(c.item.id, {c.item.id});
    out.add((c: c, depth: depth, replies: replies, orphan: depth == 0 && c.replyTo != null));
    if (collapsed.contains(c.item.id)) return;
    for (final k in children[c.item.id] ?? const <CommentView>[]) {
      walk(k, depth + 1);
    }
  }

  for (final root in children[null] ?? const <CommentView>[]) {
    walk(root, 0);
  }
  return out;
}

class _CommentTile extends ConsumerWidget {
  const _CommentTile({
    required this.c,
    required this.onReply,
    required this.onLike,
    this.depth = 0,
    this.replies = 0,
    this.collapsed = false,
    this.orphan = false,
    this.onToggle,
    this.onDelete,
  });
  final CommentView c;
  final int depth;
  final int replies;
  final bool collapsed;
  final bool orphan;
  final VoidCallback? onToggle;
  final VoidCallback onReply;
  final VoidCallback onLike;
  final VoidCallback? onDelete;

  /// Past this depth replies stop moving right, but keep their lines.
  static const _maxIndent = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final prov = ProvenanceTag.of(c.item);
    return InkWell(
      onLongPress: () => showActions(context, [
        SheetAction(
          Icons.copy_rounded,
          'Copy',
          () => Clipboard.setData(ClipboardData(text: c.text)),
        ),
        SheetAction(Icons.reply_rounded, 'Reply', onReply),
        if (c.item.author == e.me.id)
          SheetAction(Icons.edit_outlined, 'Edit', () async {
            final next = await prompt(
              context,
              title: 'Edit comment',
              body: 'Replaces this comment for everyone who has it.',
              initial: c.text,
              maxLength: 2000,
              allowEmpty: false,
            );
            if (next != null &&
                next.trim().isNotEmpty &&
                next.trim() != c.text) {
              await e.edit(c.item.e.scope, c.item.id, next.trim());
            }
          }),
        if (onDelete != null)
          SheetAction(
            Icons.delete_outline_rounded,
            'Delete',
            onDelete!,
            danger: true,
          ),
      ]),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(width: Space.gutter - 6),
            // One thread line per ancestor, so every reply visibly hangs
            // from its root; the nearest one is a shade darker.
            for (var level = 1; level <= depth.clamp(0, _maxIndent); level++)
              SizedBox(
                width: 18,
                child: Center(
                  child: Container(
                    width: 2,
                    color: level == depth.clamp(0, _maxIndent) ? p.faint.withValues(alpha: .7) : p.line,
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, Space.sm, Space.gutter, Space.sm),
                child: _body(context, ref, p, e, prov),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, Palette p, Engine e, Provenance prov) {
    return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => c.item.author == e.me.id ? context.go('/me') : context.push('/u/${c.item.author}'),
              child: Avatar(id: c.item.author, size: 30),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          e.nameOf(c.item.author),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Txt.small(p.ink)
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        timeAgo(c.item.ts),
                        style: Txt.mono(p.faint, size: 10.5),
                      ),
                      if (prov != Provenance.mine) ...[
                        const SizedBox(width: 6),
                        ProvenanceTag(prov, compact: true),
                      ],
                    ],
                  ),
                  if (orphan)
                    Text('replying to a comment not on this phone', style: Txt.mono(p.faint, size: 10.5)),
                  const SizedBox(height: 2),
                  Text(
                    c.text + (c.edited ? '  (edited)' : ''),
                    style: Txt.body(p.ink).copyWith(fontSize: 14.5),
                  ),
                  if (c.media.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    MediaGrid(media: c.media, item: c.item, maxHeight: 220),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: onReply,
                        child: Text(
                          'Reply',
                          style: Txt.mono(p.muted, size: 11),
                        ),
                      ),
                      if (onToggle != null) ...[
                        const SizedBox(width: Space.md),
                        GestureDetector(
                          onTap: onToggle,
                          child: Text(
                            collapsed
                                ? 'Show $replies ${replies == 1 ? 'reply' : 'replies'}'
                                : 'Hide replies',
                            style: Txt.mono(p.accent, size: 11),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: onLike,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  children: [
                    Icon(
                      c.liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      size: 16,
                      color: c.liked ? p.ink : p.faint,
                    ),
                    if (c.likes > 0)
                      Text('${c.likes}', style: Txt.mono(p.muted, size: 10)),
                  ],
                ),
              ),
            ),
          ],
        );
  }
}
