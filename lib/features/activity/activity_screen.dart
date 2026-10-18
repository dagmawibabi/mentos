import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/engine.dart';
import '../../net/pay/coin.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/media.dart';
import '../../widgets/ui.dart';

/// Everything that happened for this identity, grouped by day, each with
/// the context needed to act on it without opening something else first.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key, this.embedded = false});
  final bool embedded;

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

const _filters = <String, String>{
  'all': 'All',
  'unread': 'Unread',
  'social': 'Social',
  'money': 'Money',
  'market': 'Market',
  'files': 'Files',
  'requests': 'Requests',
};

bool _matches(Activity a, String f) => switch (f) {
  'unread' => !a.seen,
  'social' => const {'like', 'comment', 'follow', 'react', 'subscribe', 'space', 'peer'}.contains(a.kind),
  'money' => const {'coin', 'pay'}.contains(a.kind),
  'market' => a.kind == 'market',
  'files' => a.kind == 'xfer',
  'requests' => const {'sync', 'invite', 'xfer'}.contains(a.kind),
  _ => true,
};

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  Engine? _engine;
  String _filter = 'all';

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
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const SizedBox.shrink();
    final items = ref.watch(activityProvider).value ?? const <Activity>[];
    final unread = items.where((a) => !a.seen).length;
    final shown = items.where((a) => _matches(a, _filter)).toList();
    final groups = <String, List<Activity>>{};
    for (final a in shown) {
      (groups[_bucket(a.ts)] ??= []).add(a);
    }

    final body = Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 8),
            children: [
              for (final f in _filters.entries)
                if (f.key == 'all' || items.any((a) => _matches(a, f.key)))
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.key == 'unread' && unread > 0 ? '${f.value} $unread' : f.value),
                      selected: _filter == f.key,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _filter = f.key),
                    ),
                  ),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? EmptyState(
                  icon: Icons.notifications_none_rounded,
                  title: _filter == 'all' ? 'All quiet' : 'Nothing here',
                  body: _filter == 'all'
                      ? 'Likes, replies, payments, orders and requests show up here as they happen.'
                      : null,
                  compact: true,
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: Space.xxl),
                  children: [
                    for (final g in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.xs),
                        child: Text(g.key, style: Txt.small(p.muted).copyWith(fontWeight: FontWeight.w600)),
                      ),
                      for (final a in g.value) _Row(a: a, e: e),
                    ],
                  ],
                ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: [
          if (unread > 0)
            IconBtn(Icons.done_all_rounded, tooltip: 'Mark all read', onTap: e.markActivitySeen),
          if (items.isNotEmpty)
            IconBtn(Icons.delete_sweep_outlined, tooltip: 'Clear all', onTap: () async {
              final ok = await confirm(context, title: 'Clear activity?', body: 'Removes every entry on this phone.', action: 'Clear', danger: true);
              if (ok) e.clearActivity();
            }),
          IconBtn(Icons.tune_rounded, tooltip: 'Notification settings', onTap: () => context.push('/notifications')),
          const SizedBox(width: 8),
        ],
      ),
      body: body,
    );
  }
}

String _bucket(int ts) {
  final t = DateTime.fromMillisecondsSinceEpoch(ts);
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(t.year, t.month, t.day)).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return 'This week';
  return 'Earlier';
}

/// Colour and icon for each kind, so the list scans at a glance.
(IconData, Color) _look(Activity a, Palette p) => switch (a.kind) {
  'like' => (Icons.favorite_rounded, const Color(0xFFF2386F)),
  'comment' => (Icons.mode_comment_rounded, const Color(0xFF3B82F6)),
  'react' => (Icons.add_reaction_rounded, const Color(0xFFF59E0B)),
  'follow' || 'peer' => (Icons.person_add_alt_1_rounded, p.accent),
  'subscribe' => (Icons.campaign_rounded, const Color(0xFF8B5CF6)),
  'call' => (Icons.call_missed_rounded, p.danger),
  'coin' || 'pay' => (Icons.toll_rounded, p.accent),
  'market' => (Icons.storefront_rounded, const Color(0xFF8B5CF6)),
  'sync' => (Icons.handshake_rounded, const Color(0xFF0EA5E9)),
  'xfer' => (Icons.swap_horiz_rounded, const Color(0xFF0EA5E9)),
  'invite' || 'space' => (Icons.group_add_rounded, p.accent),
  _ => (Icons.notifications_rounded, p.inkSoft),
};

class _Row extends ConsumerWidget {
  const _Row({required this.a, required this.e});
  final Activity a;
  final Engine e;

  String _text() => switch (a.kind) {
    'like' => 'liked your post',
    'comment' => 'commented on your post',
    'follow' => 'started following you',
    'react' => 'reacted to your ${(a.scope ?? '').startsWith('story:') ? 'story' : 'message'}',
    'subscribe' => 'subscribed to ${a.text ?? 'your channel'}',
    'call' => 'tried to call you',
    'pay' || 'coin' || 'market' => a.text ?? '',
    'sync' => 'asked you to keep their messages',
    'xfer' => 'wants to send you a file',
    'invite' => 'invited you to ${a.text ?? 'a group'}',
    'space' => a.text ?? 'joined your space',
    'peer' => a.text ?? 'connected',
    _ => a.text ?? a.kind,
  };

  void _open(BuildContext context) {
    e.setActivitySeen(a.id, true);
    switch (a.kind) {
      case 'like' || 'comment':
        if (a.ref != null) context.push('/post/${a.ref}');
      case 'react' when (a.scope ?? '').startsWith('story:'):
        context.push('/story/${e.me.id}');
      case 'react' || 'sync':
        context.push('/chat/${a.actor}');
      case 'call':
        context.push('/calls');
      case 'pay' || 'coin':
        context.go('/wallet');
      case 'market':
        context.push(a.ref?.startsWith('/') == true ? a.ref! : '/market/hub');
      case 'subscribe':
        if (a.ref != null) context.push('/ch/${e.me.id}/${a.ref}');
      case 'xfer':
        context.push('/transfer/${a.actor}');
      case 'invite':
        break;
      default:
        context.push('/u/${a.actor}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final (icon, color) = _look(a, p);
    final name = e.nameOf(a.actor);
    final detail = _Detail(a: a, e: e);
    return Dismissible(
      key: ValueKey(a.id),
      background: Container(
        color: p.accentSoft,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 24),
        child: Row(children: [
          Icon(a.seen ? Icons.mark_email_unread_outlined : Icons.done_rounded, color: p.accent),
          const SizedBox(width: 8),
          Text(a.seen ? 'Mark unread' : 'Mark read', style: Txt.small(p.accent)),
        ]),
      ),
      secondaryBackground: Container(
        color: p.dangerSoft,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: Icon(Icons.delete_outline_rounded, color: p.danger),
      ),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          e.setActivitySeen(a.id, !a.seen);
          return false;
        }
        return true;
      },
      onDismissed: (_) => e.deleteActivity(a.id),
      child: InkWell(
        onTap: () => _open(context),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 2),
          padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, Space.md),
          decoration: BoxDecoration(
            color: a.seen ? Colors.transparent : p.accentSoft.withValues(alpha: .45),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Avatar(id: a.actor, size: 44),
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: p.bg, width: 2)),
                      child: Icon(icon, size: 11, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(text: name, style: Txt.bodyStrong(p.ink)),
                              TextSpan(text: ' ${_text()}', style: Txt.body(p.inkSoft)),
                            ]),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: Space.sm),
                        Text(timeAgo(a.ts), style: Txt.mono(a.seen ? p.faint : p.accent, size: 11)),
                        if (!a.seen) ...[
                          const SizedBox(width: 6),
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Container(width: 7, height: 7, decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle)),
                          ),
                        ],
                      ],
                    ),
                    detail,
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

/// The part of a notification that is worth seeing without tapping: the
/// post it was about, the amount, the file, or the buttons to answer.
class _Detail extends ConsumerWidget {
  const _Detail({required this.a, required this.e});
  final Activity a;
  final Engine e;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    switch (a.kind) {
      case 'like' || 'comment' || 'react':
        final post = a.ref == null ? null : e.db.item(a.ref!);
        final text = post?.body['text'] is String ? post!.body['text'] as String : '';
        final media = post == null ? const <MediaRef>[] : MediaRef.listFrom(post.body['media']);
        final image = media.where((m) => m.isImage).firstOrNull;
        final file = image == null ? null : e.media.cached(image);
        return Padding(
          padding: const EdgeInsets.only(top: Space.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (a.kind == 'comment' && (a.text ?? '').isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(12)),
                  child: Text('“${a.text}”', maxLines: 3, overflow: TextOverflow.ellipsis, style: Txt.body(p.ink)),
                ),
              if (a.kind == 'react' && (a.text ?? '').isNotEmpty)
                Text(a.text!, style: const TextStyle(fontSize: 26)),
              if (text.isNotEmpty || file != null)
                Row(
                  children: [
                    if (file != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(file, width: 40, height: 40, fit: BoxFit.cover),
                      ),
                      const SizedBox(width: Space.sm),
                    ],
                    if (text.isNotEmpty)
                      Expanded(
                        child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted)),
                      ),
                  ],
                ),
            ],
          ),
        );
      case 'follow':
        final following = e.db.peer(a.actor)?.iFollow ?? false;
        if (following) return const SizedBox.shrink();
        return _Buttons([
          ('Follow back', true, () => e.follow(a.actor, true)),
        ]);
      case 'coin':
        final tx = a.ref == null ? null : e.coin?.tx(a.ref!);
        if (tx == null || tx.amount == 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(Radii.pill)),
                child: Text('${tx.kind == 'lock' ? '' : '+'}${Coin.format(tx.amount)} MNT',
                    style: Txt.mono(p.accent, size: 12, w: FontWeight.w600)),
              ),
              if (tx.memo.isNotEmpty && !tx.isEscrowOp) ...[
                const SizedBox(width: Space.sm),
                Flexible(child: Text(tx.memo, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted))),
              ],
            ],
          ),
        );
      case 'market':
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            switch (a.scope) {
              'placed' => 'Accept or decline in My market',
              'shipped' || 'delivered' => 'Confirm when it arrives to release payment',
              'disputed' || 'rejected' => 'Payment is frozen until it is settled',
              'submitted' => 'Review the evidence and approve',
              'locked' => 'Coins are in escrow. Pay the birr, then mark it paid',
              'paid' => 'Check the birr arrived, then release',
              _ => 'Open the deal',
            },
            style: Txt.small(p.muted),
          ),
        );
      case 'xfer':
        final x = e.transfers().where((t) => 'xfer:${t.id}' == a.id).firstOrNull;
        return Padding(
          padding: const EdgeInsets.only(top: Space.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(fileIcon(x?.media.mime ?? ''), size: 18, color: p.inkSoft),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      [a.text ?? x?.media.name ?? 'a file', if (x != null) bytes(x.media.size)].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Txt.small(p.ink),
                    ),
                  ),
                ],
              ),
              if (x != null && x.state == XferState.offer)
                _Buttons([
                  ('Decline', false, () => e.respondTransfer(x.id, false)),
                  ('Receive', true, () => e.respondTransfer(x.id, true)),
                ])
              else if (x != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    switch (x.state) {
                      XferState.done => 'Received',
                      XferState.active => 'Receiving · ${(x.progress * 100).round()}%',
                      XferState.declined => 'You declined',
                      _ => x.state.name,
                    },
                    style: Txt.mono(p.muted, size: 11),
                  ),
                ),
            ],
          ),
        );
      case 'sync':
        if (a.scope == null) return const SizedBox.shrink();
        return _Buttons([
          ('Not now', false, () => e.acceptSync(a.scope!, a.actor, false)),
          ('Keep them', true, () => e.acceptSync(a.scope!, a.actor, true)),
        ]);
      case 'invite':
        if (a.ref == null) return const SizedBox.shrink();
        return _Buttons([
          ('Decline', false, () => e.respondGroupInvite(a.ref!, false)),
          ('Join', true, () => e.respondGroupInvite(a.ref!, true)),
        ]);
      case 'call':
        return _Buttons([
          ('Message', false, () => GoRouter.of(context).push('/chat/${a.actor}')),
        ]);
    }
    return const SizedBox.shrink();
  }
}

class _Buttons extends StatelessWidget {
  const _Buttons(this.buttons);
  final List<(String, bool, Future<void> Function())> buttons;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.sm),
    child: Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final (label, primary, onTap) in buttons)
          primary
              ? FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 34), visualDensity: VisualDensity.compact),
                  onPressed: () => onTap(),
                  child: Text(label),
                )
              : OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34), visualDensity: VisualDensity.compact),
                  onPressed: () => onTap(),
                  child: Text(label),
                ),
      ],
    ),
  );
}
