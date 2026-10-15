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
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';
import 'chat_view.dart';

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key, required this.peer});
  final String peer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final scope = Scope.dm(e.me.id, peer);
    final person = ref.watch(peerProvider(peer)).value;
    final online = ref.watch(onlineProvider(peer)).value ?? false;
    final typing = (ref.watch(typingProvider(scope)).value ?? const {}).contains(peer);
    final sync = ref.watch(syncStateProvider(scope)).value;
    final hint = ref.watch(settingsProvider).showOfflineHint;

    Widget? banner;
    if (sync != null && sync.theirsOffered) {
      banner = _Banner(
        icon: Icons.handshake_outlined,
        text: '${person?.name ?? 'They'} asked you to keep a copy of their messages on this phone.',
        actions: [
          TextButton(onPressed: () => e.acceptSync(scope, peer, false), child: Text('Decline', style: Txt.small(p.muted))),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 34)),
            onPressed: () => e.acceptSync(scope, peer, true),
            child: const Text('Keep'),
          ),
        ],
      );
    } else if (!online && sync?.theirs != GrantState.active && hint) {
      banner = _Banner(
        icon: Icons.cloud_off_rounded,
        text: '${person?.name ?? 'They'} is offline, so their messages are hidden. Sync to keep each other\'s side.',
        actions: [
          TextButton(onPressed: () => showSyncSheet(context, scope, peer), child: const Text('Sync')),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          onTap: () => context.push('/u/$peer'),
          child: Row(
            children: [
              Avatar(id: peer, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Text(person?.name ?? alias(peer),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.heading(p.ink)),
              ),
              if (typing) ...[
                Text('typing…', style: Txt.mono(p.accent, size: 11)),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        actions: [
          _SyncButton(state: sync, onTap: () => showSyncSheet(context, scope, peer)),
          IconBtn(Icons.swap_horiz_rounded, tooltip: 'Send a file', onTap: () => context.push('/transfer/$peer')),
          IconBtn(Icons.info_outline_rounded, tooltip: 'Technical',
              onTap: () => showScopeTech(context, scope, peer: peer)),
          IconBtn(Icons.more_vert_rounded, onTap: () => _menu(context, ref, scope)),
          const SizedBox(width: 4),
        ],
      ),
      body: ChatView(
        scope: scope,
        banner: banner,
        emptyTitle: 'Start a conversation',
        emptyBody: 'Messages go straight to ${person?.name ?? 'them'}\'s phone over an encrypted link. '
            'No server ever sees them.',
      ),
    );
  }

  void _menu(BuildContext context, WidgetRef ref, String scope) {
    final e = ref.read(engineProvider);
    final chat = e.db.chat(scope);
    final ttl = chat['ttl'] as int? ?? 0;
    showActions(context, [
      SheetAction(Icons.person_outline_rounded, 'View profile', () => context.push('/u/$peer')),
      SheetAction(Icons.info_outline_rounded, 'Technical details', () => showScopeTech(context, scope, peer: peer)),
      SheetAction(Icons.swap_horiz_rounded, 'File transfer', () => context.push('/transfer/$peer')),
      SheetAction(Icons.timer_outlined, 'Disappearing messages', () => _ttl(context, ref, scope),
          subtitle: ttlLabel(ttl)),
      SheetAction(chat['pinned'] == 1 ? Icons.push_pin_rounded : Icons.push_pin_outlined,
          chat['pinned'] == 1 ? 'Unpin' : 'Pin', () {
        e.updateChat(scope, {'pinned': chat['pinned'] == 1 ? 0 : 1});
      }),
      SheetAction(chat['muted'] == 1 ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
          chat['muted'] == 1 ? 'Unmute' : 'Mute', () {
        e.updateChat(scope, {'muted': chat['muted'] == 1 ? 0 : 1});
      }),
      SheetAction(Icons.edit_outlined, 'Set nickname', () async {
        final n = await prompt(context, title: 'Nickname', initial: e.peerOf(peer).nickname ?? '', hint: 'Only you see this');
        if (n != null) e.setNickname(peer, n.trim().isEmpty ? null : n.trim());
      }),
      SheetAction(Icons.delete_outline_rounded, 'Clear chat on this phone', () async {
        final ok = await confirm(context,
            title: 'Clear this chat?',
            body: 'Removes your copy of the conversation. Their phone keeps its own side.',
            action: 'Clear',
            danger: true);
        if (ok) {
          e.clearChat(scope);
          if (context.mounted) context.pop();
        }
      }, danger: true),
      SheetAction(Icons.block_rounded, 'Block', () async {
        final ok = await confirm(context,
            title: 'Block ${e.nameOf(peer)}?',
            body: 'They can\'t reach you and anything of theirs kept here is deleted.',
            action: 'Block',
            danger: true);
        if (ok) {
          await e.block(peer, true);
          if (context.mounted) context.pop();
        }
      }, danger: true),
    ]);
  }

  Future<void> _ttl(BuildContext context, WidgetRef ref, String scope) async {
    final e = ref.read(engineProvider);
    final current = e.db.chat(scope)['ttl'] as int? ?? 0;
    const options = [0, 300, 3600, 86400, 604800];
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) {
        final p = ctx.pal;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
                child: Text('New messages you send disappear after the chosen time, on both phones.',
                    style: Txt.small(p.muted)),
              ),
              for (final o in options)
                ListTile(
                  title: Text(ttlLabel(o)),
                  trailing: o == current ? Icon(Icons.check_rounded, color: p.accent) : null,
                  onTap: () => Navigator.pop(ctx, o),
                ),
            ],
          ),
        );
      },
    );
    if (v != null) e.updateChat(scope, {'ttl': v});
  }
}

class _SyncButton extends StatelessWidget {
  const _SyncButton({required this.state, required this.onTap});
  final SyncState? state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final s = state;
    final (icon, color) = s == null
        ? (Icons.cloud_off_rounded, p.muted)
        : s.bothActive
            ? (Icons.cloud_done_rounded, p.accent)
            : (s.mine == GrantState.active || s.theirs == GrantState.active)
                ? (Icons.cloud_queue_rounded, p.accent)
                : (s.mine == GrantState.pending || s.theirsOffered)
                    ? (Icons.cloud_sync_rounded, p.ink)
                    : (Icons.cloud_off_rounded, p.muted);
    return IconBtn(icon, color: color, tooltip: 'Sync', onTap: onTap);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, required this.actions});
  final IconData icon;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      margin: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, 0),
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.sm, Space.sm),
      decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(
        children: [
          Icon(icon, size: 18, color: p.inkSoft),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: Txt.small(p.inkSoft))),
          ...actions,
        ],
      ),
    );
  }
}

Future<void> showSyncSheet(BuildContext context, String scope, String peer) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SyncSheet(scope: scope, peer: peer),
  );
}

class _SyncSheet extends ConsumerWidget {
  const _SyncSheet({required this.scope, required this.peer});
  final String scope;
  final String peer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final Engine e = ref.read(engineProvider);
    final s = ref.watch(syncStateProvider(scope)).value;
    final name = ref.watch(peerProvider(peer)).value?.name ?? alias(peer);
    if (s == null) return const SizedBox(height: 200, child: Loading());

    String mineLabel() => switch (s.mine) {
          GrantState.active => 'On — $name keeps your messages',
          GrantState.pending => 'Waiting for $name to accept',
          null => 'Off — only on your phone',
        };
    String theirsLabel() => switch (s.theirs) {
          GrantState.active => 'On — you keep $name\'s messages',
          GrantState.pending => '$name is asking you to keep them',
          null => 'Off — $name hasn\'t offered',
        };

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Chat sync', style: Txt.title(p.ink)),
            const SizedBox(height: 6),
            Text(
              'Without sync, each side of the chat lives only on its author\'s phone and shows up while they\'re online. '
              'Sync keeps an encrypted copy on the other phone — only with both of you agreeing.',
              style: Txt.small(p.muted),
            ),
            const SizedBox(height: Space.lg),
            _SyncRow(
              title: 'My messages on $name\'s phone',
              status: mineLabel(),
              active: s.mine == GrantState.active,
              pending: s.mine == GrantState.pending,
              value: s.mine != null,
              onChanged: (v) => e.setShareMine(scope, v),
            ),
            const SizedBox(height: Space.sm),
            _SyncRow(
              title: '$name\'s messages on my phone',
              status: theirsLabel(),
              active: s.theirs == GrantState.active,
              pending: s.theirsOffered,
              value: s.theirs == GrantState.active,
              onChanged: s.theirs == null
                  ? null
                  : (v) => s.theirsOffered
                      ? e.acceptSync(scope, peer, v)
                      : (v ? null : e.dropTheirs(scope)),
            ),
            const SizedBox(height: Space.lg),
            if (!s.bothActive)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    if (s.mine == null) await e.setShareMine(scope, true);
                    if (s.theirsOffered) await e.acceptSync(scope, peer, true);
                    if (context.mounted) toast(context, 'Sync requested. It turns on once $name agrees.');
                  },
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('Sync both ways'),
                ),
              ),
            const SizedBox(height: Space.sm),
            Text('Turning your side off asks $name\'s phone to delete its copy.',
                style: Txt.mono(p.faint, size: 10.5)),
          ],
        ),
      ),
    );
  }
}

class _SyncRow extends StatelessWidget {
  const _SyncRow({
    required this.title,
    required this.status,
    required this.active,
    required this.pending,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String status;
  final bool active;
  final bool pending;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.sm, Space.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: active ? p.accent : p.line),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? p.accent : Colors.transparent,
              border: Border.all(color: active ? p.accent : (pending ? p.ink : p.faint), width: 1.5),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Txt.bodyStrong(p.ink)),
                const SizedBox(height: 2),
                Text(status, style: Txt.mono(active ? p.accent : p.muted, size: 11)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
