import 'package:flutter/material.dart';

import '../../net/call/calls.dart';
import '../calls/call_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';
import 'chat_view.dart';
import 'chat_wallpaper.dart';

class GroupChatScreen extends ConsumerWidget {
  const GroupChatScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final g = e.group(id);
    if (g == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.groups_outlined, title: 'Group not found'));
    }
    final online = ({g.owner, ...g.members}.where(e.isOnline)).length;
    final scope = Scope.gdm(id);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(g.name, style: Txt.heading(p.ink)),
            Text('$online of ${({g.owner, ...g.members}).length} online', style: Txt.mono(p.muted, size: 11)),
          ],
        ),
        actions: [
          Builder(builder: (btn) {
            final others = {g.owner, ...g.members}.where((m) => m != ref.read(engineProvider).me.id).toList();
            return IconBtn(Icons.call_outlined, tooltip: 'Call', onTap: () {
              if (others.length + 1 > CallManager.maxMembers) {
                toast(context, 'Group calls are limited to ${CallManager.maxMembers} people for now');
                return;
              }
              showCallMenu(btn, ref, others);
            });
          }),
          IconBtn(Icons.groups_outlined, tooltip: 'Members', onTap: () => context.push('/g/${g.id}/info')),
          IconBtn(Icons.more_vert_rounded, onTap: () => _menu(context, ref, g)),
          const SizedBox(width: 4),
        ],
      ),
      body: ChatView(
        scope: scope,
        group: true,
        emptyTitle: 'Group is quiet',
        emptyBody: 'Messages are sealed with the group key and signed by each member. Offline members see history only if someone kept it.',
      ),
    );
  }

  void _menu(BuildContext context, WidgetRef ref, GroupInfo g) {
    final e = ref.read(engineProvider);
    showActions(context, [
      SheetAction(Icons.groups_outlined, 'Members and roles', () => context.push('/g/${g.id}/info')),
      SheetAction(Icons.info_outline_rounded, 'Technical details', () => showScopeTech(context, Scope.gdm(g.id), groupId: g.id)),
      SheetAction(
        Icons.wallpaper_rounded,
        'Chat wallpaper',
        () => showWallpaperPicker(context, scope: Scope.gdm(g.id)),
        subtitle: wallpaperName(e.chatWallpaper(Scope.gdm(g.id))),
      ),
      SheetAction(g.preserve ? Icons.cloud_done_rounded : Icons.cloud_outlined,
          g.preserve ? 'Stop keeping history' : 'Keep history on this phone', () {
        e.updateGroup(g.id, (x) => x.copyWith(preserve: !x.preserve));
      }),
      SheetAction(g.shareMine ? Icons.share_rounded : Icons.share_outlined,
          g.shareMine ? 'Stop letting others keep my messages' : 'Let members keep my messages', () {
        e.updateGroup(g.id, (x) => x.copyWith(shareMine: !x.shareMine));
      }),
      SheetAction(Icons.logout_rounded, 'Leave group', () async {
        final ok = await confirm(context,
            title: 'Leave ${g.name}?',
            body: 'This phone drops the group. Your messages disappear for others unless they kept them.',
            action: 'Leave',
            danger: true);
        if (!ok) return;
        await e.leaveGroup(g.id);
        if (context.mounted) context.pop();
      }, danger: true),
    ], title: g.name.toUpperCase());
  }
}
