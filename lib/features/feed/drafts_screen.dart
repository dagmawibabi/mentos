import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/engine.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';

class DraftsScreen extends ConsumerStatefulWidget {
  const DraftsScreen({super.key});

  @override
  ConsumerState<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends ConsumerState<DraftsScreen> {
  String? _busy;

  @override
  Widget build(BuildContext context) {
    final held = ref.watch(heldPostsProvider).value;
    final scheduled = held?.scheduled ?? const <HeldPost>[];
    final drafts = held?.drafts ?? const <HeldPost>[];
    final e = ref.watch(maybeEngineProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Drafts')),
      body: scheduled.isEmpty && drafts.isEmpty
          ? const EmptyState(
              icon: Icons.schedule_rounded,
              title: 'Nothing waiting',
              body: 'Schedule a post, or leave the composer with text still in it. Both stay here until you post or remove them.',
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: Space.xxl),
              children: [
                const SectionLabel('Scheduled'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.gutter,
                    0,
                    Space.gutter,
                    Space.sm,
                  ),
                  child: Text(
                    'These publish from this phone while Mentos is open.',
                    style: Txt.small(context.pal.muted),
                  ),
                ),
                if (scheduled.isEmpty)
                  const _EmptyLine('Nothing is set to publish.')
                else
                  for (final post in scheduled) ...[
                    _HeldRow(
                      post: post,
                      when: _due(post.at),
                      place: e == null ? 'Feed' : _place(e, post),
                      busy: _busy == post.key,
                      onOpen: () =>
                          context.push('/compose?scheduled=${post.key}'),
                      onPost: () => _post(post, draft: false),
                      onReschedule: () => _reschedule(post),
                      onRemove: () => _remove(post, draft: false),
                    ),
                    const Hairline(indent: Space.gutter),
                  ],
                const SectionLabel('Drafts'),
                if (drafts.isEmpty)
                  const _EmptyLine('A post you leave unfinished is kept here.')
                else
                  for (final post in drafts) ...[
                    _HeldRow(
                      post: post,
                      when: 'Saved ${timeAgo(post.at)}',
                      place: e == null ? 'Feed' : _place(e, post),
                      busy: _busy == post.key,
                      onOpen: () => context.push('/compose?draft=${post.key}'),
                      onPost: () => _post(post, draft: true),
                      onRemove: () => _remove(post, draft: true),
                    ),
                    const Hairline(indent: Space.gutter),
                  ],
              ],
            ),
    );
  }

  Future<void> _post(HeldPost post, {required bool draft}) async {
    final e = ref.read(maybeEngineProvider);
    if (e == null || _busy != null) return;
    setState(() => _busy = post.key);
    try {
      await e.publishHeld(post, draft: draft);
      if (mounted) toast(context, 'Posted');
    } catch (err) {
      if (mounted) toast(context, 'Could not post: $err');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _reschedule(HeldPost post) async {
    final e = ref.read(maybeEngineProvider);
    if (e == null) return;
    final minutes = await pickMinutes(
      context,
      title: 'Change time',
      body: 'Counted from now. It still publishes only while Mentos is open.',
      action: 'Schedule',
      choices: const [15, 30, 60, 180, 720],
    );
    if (minutes == null) return;
    e.saveScheduled(
      post.copyWith(
        at: DateTime.now()
            .add(Duration(minutes: minutes))
            .millisecondsSinceEpoch,
      ),
      replaceKey: post.key,
    );
    if (mounted) toast(context, 'Time updated');
  }

  Future<void> _remove(HeldPost post, {required bool draft}) async {
    final e = ref.read(maybeEngineProvider);
    if (e == null) return;
    final ok = await confirm(
      context,
      title: draft ? 'Remove this draft?' : 'Remove this scheduled post?',
      body: draft
          ? 'The text is deleted from this phone.'
          : 'It will not be published.',
      action: 'Remove',
      danger: true,
    );
    if (!ok) return;
    if (draft) {
      e.deletePostDraft(post.key);
    } else {
      e.deleteScheduled(post.key);
    }
  }
}

String _place(Engine e, HeldPost post) {
  if (post.bcastId != null && post.spaceId == null) return 'Channel';
  final space = post.spaceId == null ? null : e.db.space(post.spaceId!);
  if (space == null) return 'Feed';
  if (post.boardId != null) {
    final board = space.forums.where((c) => c.id == post.boardId).firstOrNull;
    return '${space.name} · #${board?.name ?? post.boardId}';
  }
  if (post.channelId != null) {
    final channel = space.channels
        .where((c) => c.id == post.channelId)
        .firstOrNull;
    return '${space.name} · #${channel?.name ?? post.channelId}';
  }
  return space.name;
}

String _due(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = day.difference(today).inDays;
  final dayName = switch (diff) {
    0 => 'Today',
    1 => 'Tomorrow',
    _ => dayLabel(ms),
  };
  if (!t.isAfter(now)) return 'Due now · $dayName ${clock(ms)}';
  final left = t.difference(now);
  if (left.inMinutes < 60) {
    return 'In ${left.inMinutes.clamp(1, 59)} min · ${clock(ms)}';
  }
  if (diff == 0) return 'In ${left.inHours} h · ${clock(ms)}';
  return '$dayName · ${clock(ms)}';
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        0,
        Space.gutter,
        Space.sm,
      ),
      child: Text(text, style: Txt.small(context.pal.faint)),
    );
  }
}

class _HeldRow extends StatelessWidget {
  const _HeldRow({
    required this.post,
    required this.when,
    required this.place,
    required this.busy,
    required this.onOpen,
    required this.onPost,
    required this.onRemove,
    this.onReschedule,
  });

  final HeldPost post;
  final String when;
  final String place;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onPost;
  final VoidCallback onRemove;
  final VoidCallback? onReschedule;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final marks = [
      place,
      if (post.poll != null) 'Poll · ${post.poll!.options.length}',
      if (post.nsfw) 'NSFW',
      if (post.ai) 'AI',
      if (post.repost != null) 'Repost',
    ].join(' · ');
    return InkWell(
      onTap: busy ? null : onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 12, Space.gutter, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(when, style: Txt.mono(p.muted, size: 11)),
            if (post.title.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                post.title.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Txt.heading(p.ink),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              post.preview,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: Txt.body(p.ink),
            ),
            const SizedBox(height: 4),
            Text(marks, style: Txt.small(p.muted)),
            Row(
              children: [
                TextButton(
                  onPressed: busy ? null : onPost,
                  child: Text(busy ? 'Posting…' : 'Post now'),
                ),
                if (onReschedule != null)
                  TextButton(
                    onPressed: busy ? null : onReschedule,
                    child: const Text('Change time'),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: busy ? null : onRemove,
                  child: Text('Remove', style: Txt.bodyStrong(p.danger)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
