import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/spark.dart';
import '../../widgets/ui.dart';

class InsightsScreen extends ConsumerStatefulWidget {
  const InsightsScreen({super.key});

  @override
  ConsumerState<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends ConsumerState<InsightsScreen> {
  int _tab = 0;
  int _days = 30;
  _Sort _sort = _Sort.latest;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final totals = e.insightTotals(days: _days);
    final series = e.insightSeries(days: _days);
    final posts = [...(ref.watch(authorFeedProvider(e.me.id)).value ?? const <PostView>[])];
    switch (_sort) {
      case _Sort.latest:
        posts.sort((a, b) => b.item.ts.compareTo(a.item.ts));
      case _Sort.views:
        posts.sort((a, b) => b.views.compareTo(a.views));
      case _Sort.replies:
        posts.sort((a, b) => b.comments.compareTo(a.comments));
    }
    final people = ref.watch(peopleProvider).value ?? const [];
    final followers = people.where((x) => x.followsMe).toList();
    final keepers = (ref.watch(grantsProvider).value ?? const [])
        .where((g) => g.dir == GrantDir.out && g.state == GrantState.active)
        .map((g) => g.peer)
        .toSet();

    return Scaffold(
      appBar: AppBar(title: const Text('Insights')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            child: Segmented<int>(
              value: _tab,
              options: const {0: 'Overview', 1: 'Audience'},
              onChanged: (v) => setState(() => _tab = v),
            ),
          ),
          if (_tab == 0) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, Space.sm),
              child: Row(
                children: [
                  Text('Profile', style: Txt.heading(p.ink)),
                  const Spacer(),
                  _Period(value: _days, onChanged: (v) => setState(() => _days = v)),
                ],
              ),
            ),
            SizedBox(
              height: 96,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                children: [
                  _StatCard(label: 'Views', value: compact(totals.views)),
                  _StatCard(label: 'Viewers', value: compact(totals.viewers)),
                  _StatCard(label: 'Followers', value: compact(totals.followers)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
              child: SparkLine(points: [
                for (final s in series) s.views.toDouble(),
                if (series.isEmpty) 0,
              ]),
            ),
            if (series.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(DateFormat('MMM d').format(DateTime.fromMillisecondsSinceEpoch(series.first.ts)),
                        style: Txt.mono(p.faint, size: 10.5)),
                    Text(DateFormat('MMM d').format(DateTime.fromMillisecondsSinceEpoch(series.last.ts)),
                        style: Txt.mono(p.faint, size: 10.5)),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.gutter, Space.sm),
              child: Text('Posts', style: Txt.heading(p.ink)),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Row(
                children: [
                  for (final s in _Sort.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(s.label),
                        selected: _sort == s,
                        onSelected: (_) => setState(() => _sort = s),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Space.sm),
            if (posts.isEmpty)
              const EmptyState(icon: Icons.insights_outlined, title: 'No posts in this window', compact: true)
            else
              for (final post in posts.take(40))
                ListTile(
                  onTap: () => context.push('/post/${post.id}'),
                  title: Text(
                    post.text.isEmpty ? (post.title.isEmpty ? 'Post' : post.title) : post.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${timeAgo(post.item.ts)} · ${post.likes} likes · ${post.comments} replies',
                    style: Txt.mono(p.muted, size: 11),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${post.views}', style: Txt.heading(p.ink)),
                      Text('views', style: Txt.mono(p.faint, size: 10)),
                    ],
                  ),
                ),
          ] else ...[
            SectionLabel('Followers', trailing: Text('${followers.length}', style: Txt.mono(p.muted, size: 11))),
            if (followers.isEmpty)
              const EmptyState(icon: Icons.people_outline, title: 'No followers yet', compact: true)
            else
              for (final x in followers)
                ListTile(
                  leading: Avatar(id: x.id, size: 40),
                  title: Text(x.name),
                  subtitle: Text(keepers.contains(x.id) ? 'keeps a copy of your posts' : 'follower',
                      style: Txt.mono(p.muted, size: 11)),
                  onTap: () => context.push('/u/${x.id}'),
                ),
            Padding(
              padding: const EdgeInsets.all(Space.gutter),
              child: Text(
                'Counts come from devices that told this node they looked. There is no central analytics server.',
                style: Txt.mono(p.faint, size: 11),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _Sort {
  latest,
  views,
  replies;

  String get label => switch (this) {
        latest => 'Latest',
        views => 'Most views',
        replies => 'Most replies',
      };
}

class _Period extends StatelessWidget {
  const _Period({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return GestureDetector(
      onTap: () async {
        final v = await showModalBottomSheet<int>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final d in const [7, 30, 90])
                  ListTile(
                    title: Text('$d days'),
                    trailing: d == value ? Icon(Icons.check_rounded, color: ctx.pal.accent) : null,
                    onTap: () => Navigator.pop(ctx, d),
                  ),
              ],
            ),
          ),
        );
        if (v != null) onChanged(v);
      },
      child: Text('$value days', style: Txt.mono(p.muted, size: 12)),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      width: 148,
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Txt.mono(p.muted, size: 11)),
          const Spacer(),
          Text(value, style: Txt.display(p.ink).copyWith(fontSize: 28)),
        ],
      ),
    );
  }
}
