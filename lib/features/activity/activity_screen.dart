import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/engine.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key, this.embedded = false});
  final bool embedded;

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  Engine? _engine;

  @override
  void initState() {
    super.initState();
    try {
      _engine = ref.read(engineProvider);
    } catch (_) {}
  }

  @override
  void dispose() {
    _engine?.markActivitySeen();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    Engine? e;
    try {
      e = ref.read(engineProvider);
    } catch (_) {}
    if (e == null) return const SizedBox.shrink();
    final items = ref.watch(activityProvider).value ?? const <Activity>[];
    final tabs = {
      'All': items,
      'Social': items.where((a) => const {'like', 'comment', 'follow', 'react'}.contains(a.kind)).toList(),
      'Files': items.where((a) => a.kind == 'xfer').toList(),
      'Requests': items.where((a) => const {'sync', 'invite'}.contains(a.kind)).toList(),
    };
    final body = widget.embedded ? _EmbeddedActivity(tabs: tabs, e: e) : DefaultTabController(
      length: tabs.length,
      child: Column(
        children: [
          TabBar(isScrollable: true, tabs: [for (final k in tabs.keys) Tab(text: k)]),
          Expanded(
            child: TabBarView(
              children: [
                for (final list in tabs.values)
                  list.isEmpty
                      ? const EmptyState(
                          icon: Icons.notifications_none_rounded,
                          title: 'Nothing here',
                          compact: true,
                        )
                      : ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (_, i) => _Row(a: list[i], e: e!),
                        ),
              ],
            ),
          ),
        ],
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: [
          if (items.isNotEmpty)
            TextButton(onPressed: e.clearActivity, child: Text('Clear', style: Txt.small(p.muted))),
          const SizedBox(width: 8),
        ],
      ),
      body: body,
    );
  }
}

class _EmbeddedActivity extends StatefulWidget {
  const _EmbeddedActivity({required this.tabs, required this.e});
  final Map<String, List<Activity>> tabs;
  final Engine e;

  @override
  State<_EmbeddedActivity> createState() => _EmbeddedActivityState();
}

class _EmbeddedActivityState extends State<_EmbeddedActivity> {
  late String _k = widget.tabs.keys.first;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final list = widget.tabs[_k] ?? const <Activity>[];
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, 4),
          child: Row(
            children: [
              for (final k in widget.tabs.keys)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(k),
                    selected: _k == k,
                    onSelected: (_) => setState(() => _k = k),
                    visualDensity: VisualDensity.compact,
                    selectedColor: p.accentSoft,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const EmptyState(
                  icon: Icons.notifications_none_rounded,
                  title: 'Nothing here',
                  compact: true,
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) => _Row(a: list[i], e: widget.e),
                ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.a, required this.e});
  final Activity a;
  final Engine e;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final name = e.nameOf(a.actor);
    final (icon, text) = switch (a.kind) {
      'like' => (Icons.favorite_rounded, 'liked your post'),
      'comment' => (Icons.mode_comment_rounded, 'commented: ${a.text ?? ''}'),
      'follow' => (Icons.person_add_alt_1_rounded, 'started following you'),
      'react' => (Icons.add_reaction_rounded,
          'reacted ${a.text ?? ''} to your ${(a.scope ?? '').startsWith('story:') ? 'story' : 'message'}'),
      'subscribe' => (Icons.campaign_rounded, 'subscribed to ${a.text ?? 'your channel'}'),
      'call' => (Icons.call_missed_rounded, 'called you (${a.text ?? 'voice'})'),
      'pay' => (Icons.account_balance_wallet_rounded, a.text ?? 'payment'),
      'sync' => (Icons.handshake_rounded, 'asked you to keep their messages'),
      'xfer' => (Icons.swap_horiz_rounded, 'wants to send ${a.text ?? 'a file'}'),
      'invite' => (Icons.group_add_outlined, 'invited you to ${a.text ?? 'a group'}'),
      _ => (Icons.circle_outlined, a.kind),
    };
    return Dismissible(
      key: ValueKey(a.id),
      background: Container(color: p.accentSoft, alignment: Alignment.centerLeft, padding: const EdgeInsets.only(left: 20), child: Icon(Icons.done_rounded, color: p.accent)),
      secondaryBackground: Container(color: p.dangerSoft, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: Icon(Icons.delete_outline_rounded, color: p.danger)),
      onDismissed: (_) {},
      child: InkWell(
      onTap: () {
        switch (a.kind) {
          case 'like' || 'comment':
            if (a.ref != null) context.push('/post/${a.ref}');
          case 'react' when (a.scope ?? '').startsWith('story:'):
            context.push('/story/${e.me.id}');
          case 'react' || 'sync':
            context.push('/chat/${a.actor}');
          case 'call':
            context.push('/calls');
          case 'pay':
            context.push('/wallet/${a.actor}');
          case 'subscribe':
            if (a.ref != null) context.push('/ch/${e.me.id}/${a.ref}');
          case 'xfer':
            context.push('/transfer/${a.actor}');
          case 'invite':
            if (a.ref != null) _invite(context, e, a);
          default:
            context.push('/u/${a.actor}');
        }
      },
      child: Container(
        color: a.seen ? null : p.accentSoft.withValues(alpha: .4),
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Avatar(id: a.actor, size: 40),
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(color: p.ink, shape: BoxShape.circle, border: Border.all(color: p.bg, width: 2)),
                    child: Icon(icon, size: 10, color: p.bg),
                  ),
                ),
              ],
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: name, style: Txt.bodyStrong(p.ink)),
                      TextSpan(text: ' $text', style: Txt.body(p.inkSoft)),
                    ]),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(timeAgo(a.ts), style: Txt.mono(p.faint, size: 11)),
                  if (a.kind == 'invite' && a.ref != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          OutlinedButton(
                            onPressed: () => e.respondGroupInvite(a.ref!, false),
                            child: const Text('Decline'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () => e.respondGroupInvite(a.ref!, true),
                            child: const Text('Join'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

void _invite(BuildContext context, Engine e, Activity a) {
  showActions(context, [
    SheetAction(Icons.info_outline_rounded, 'View group', () {}),
    SheetAction(Icons.check_rounded, 'Accept', () => e.respondGroupInvite(a.ref!, true)),
    SheetAction(Icons.close_rounded, 'Decline', () => e.respondGroupInvite(a.ref!, false), danger: true),
  ], title: (a.text ?? 'GROUP').toUpperCase());
}