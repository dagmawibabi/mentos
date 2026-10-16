import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
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

  @override
  void initState() {
    super.initState();
    _c.addListener(() => setState(() {}));
  }

  Future<void> _send(PostView post) async {
    final t = _c.text.trim();
    if (t.isEmpty) return;
    _c.clear();
    final reply = _replyTo;
    setState(() => _replyTo = null);
    await ref.read(engineProvider).comment(post, t, replyTo: reply?.item.id);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final post = ref.watch(postProvider(widget.id));
    final comments = ref.watch(commentsProvider(widget.id)).value ?? const <CommentView>[];
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
              body: 'This post lives on its author\'s phone. It shows up again when they\'re online, '
                  'or if someone you follow keeps a copy.',
            );
          }
          WidgetsBinding.instance.addPostFrameCallback((_) => e.recordView(pv.item));
          final byId = {for (final c in comments) c.item.id: c};
          final open = e.commentsOpen(pv);
          return Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    PostCard(post: pv, detailed: true),
                    const Hairline(),
                    SectionLabel(
                      !open ? 'Comments are off' : comments.isEmpty ? 'No comments yet' : '${comments.length} comments',
                      trailing: Text('from people online or kept', style: Txt.mono(p.faint, size: 10.5)),
                    ),
                    for (final c in comments)
                      _CommentTile(
                        c: c,
                        parent: c.replyTo == null ? null : byId[c.replyTo],
                        onReply: () {
                          setState(() => _replyTo = c);
                          _focus.requestFocus();
                        },
                        onLike: () => e.like(pv.scope, c.item.id, !c.liked),
                        onDelete: c.item.author == e.me.id ? () => e.deleteItem(c.item) : null,
                      ),
                    const SizedBox(height: Space.xl),
                  ],
                ),
              ),
              if (open)
              Container(
                decoration: BoxDecoration(color: p.bg, border: Border(top: BorderSide(color: p.line))),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_replyTo != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(Space.gutter, 8, 8, 0),
                          child: Row(
                            children: [
                              Icon(Icons.reply_rounded, size: 16, color: p.muted),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text('Replying to ${e.nameOf(_replyTo!.item.author)}',
                                    style: Txt.small(p.muted)),
                              ),
                              IconBtn(Icons.close_rounded,
                                  size: 16, color: p.muted, onTap: () => setState(() => _replyTo = null)),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Space.gutter, 8, 8, 8),
                        child: Row(
                          children: [
                            Avatar(id: e.me.id, size: 30, presence: false),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: _c,
                                focusNode: _focus,
                                minLines: 1,
                                maxLines: 4,
                                textCapitalization: TextCapitalization.sentences,
                                decoration: const InputDecoration(hintText: 'Add a comment'),
                              ),
                            ),
                            IconBtn(
                              Icons.arrow_upward_rounded,
                              active: _c.text.trim().isNotEmpty,
                              onTap: _c.text.trim().isEmpty ? null : () => _send(pv),
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

class _CommentTile extends ConsumerWidget {
  const _CommentTile({required this.c, required this.onReply, required this.onLike, this.parent, this.onDelete});
  final CommentView c;
  final CommentView? parent;
  final VoidCallback onReply;
  final VoidCallback onLike;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final prov = ProvenanceTag.of(c.item);
    return InkWell(
      onLongPress: () => showActions(context, [
        SheetAction(Icons.copy_rounded, 'Copy', () => Clipboard.setData(ClipboardData(text: c.text))),
        SheetAction(Icons.reply_rounded, 'Reply', onReply),
        if (onDelete != null) SheetAction(Icons.delete_outline_rounded, 'Delete', onDelete!, danger: true),
      ]),
      child: Padding(
        padding: EdgeInsets.fromLTRB(parent == null ? Space.gutter : Space.gutter + 28, 10, Space.md, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => context.push(c.item.author == e.me.id ? '/me' : '/u/${c.item.author}'),
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
                        child: Text(e.nameOf(c.item.author),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.ink).copyWith(fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(width: 6),
                      Text(timeAgo(c.item.ts), style: Txt.mono(p.faint, size: 10.5)),
                      if (prov != Provenance.mine) ...[const SizedBox(width: 6), ProvenanceTag(prov, compact: true)],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(c.text + (c.edited ? '  (edited)' : ''), style: Txt.body(p.ink).copyWith(fontSize: 14.5)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      GestureDetector(onTap: onReply, child: Text('Reply', style: Txt.mono(p.muted, size: 11))),
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
                    Icon(c.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        size: 16, color: c.liked ? p.ink : p.faint),
                    if (c.likes > 0) Text('${c.likes}', style: Txt.mono(p.muted, size: 10)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
