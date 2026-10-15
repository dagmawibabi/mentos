import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';

class GroupInfoScreen extends ConsumerWidget {
  const GroupInfoScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final g = e.group(id);
    if (g == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.groups_outlined, title: 'Group not found'));
    }
    final ids = {g.owner, ...g.members}.toList();
    final myRole = g.roleOf(e.me.id);
    final canAdmin = myRole.index <= Role.mod.index;

    return Scaffold(
      appBar: AppBar(
        title: Text(g.name),
        actions: [
          IconBtn(Icons.info_outline_rounded, onTap: () => showScopeTech(context, Scope.gdm(id), groupId: id)),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
            child: Text('${ids.length} members · sealed with a group key', style: Txt.mono(p.muted, size: 12)),
          ),
          SectionLabel('Members',
              trailing: canAdmin
                  ? GestureDetector(
                      onTap: () => _invite(context, ref, g),
                      child: Icon(Icons.person_add_alt_rounded, size: 18, color: p.muted),
                    )
                  : null),
          for (final mid in ids)
            ListTile(
              leading: Avatar(id: mid, size: 40),
              title: Text(e.nameOf(mid)),
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.pill), border: Border.all(color: p.line)),
                child: Text(g.roleOf(mid).name, style: Txt.mono(p.inkSoft, size: 10.5)),
              ),
              onTap: () => context.push(mid == e.me.id ? '/me' : '/u/$mid'),
              onLongPress: canAdmin && mid != e.me.id && mid != g.owner
                  ? () => showActions(context, [
                        if (g.roleOf(mid) != Role.mod)
                          SheetAction(Icons.shield_outlined, 'Make admin', () {
                            e.updateGroup(g.id, (x) => x.copyWith(roles: {...x.roles, mid: Role.mod}));
                          }),
                        if (g.roleOf(mid) == Role.mod)
                          SheetAction(Icons.remove_moderator_outlined, 'Remove admin', () {
                            e.updateGroup(g.id, (x) => x.copyWith(roles: {...x.roles}..remove(mid)));
                          }),
                        SheetAction(Icons.person_remove_outlined, 'Remove from group', () {
                          e.updateGroup(g.id, (x) => x.copyWith(members: x.members.where((m) => m != mid).toList()));
                        }, danger: true),
                      ], title: e.nameOf(mid).toUpperCase())
                  : null,
            ),
        ],
      ),
    );
  }

  Future<void> _invite(BuildContext context, WidgetRef ref, GroupInfo g) async {
    final e = ref.read(engineProvider);
    final people = e.people().where((x) => !x.blocked && !g.has(x.id)).toList();
    if (people.isEmpty) {
      toast(context, 'Everyone you know is already in this group');
      return;
    }
    final picked = <String>{};
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: Space.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(Space.gutter),
                  child: Text('Invite', style: Txt.heading(ctx.pal.ink)),
                ),
                Text('They get a request first. Nothing is shared until they accept.',
                    style: Txt.small(ctx.pal.muted)),
                const SizedBox(height: Space.md),
                for (final x in people)
                  CheckboxListTile(
                    value: picked.contains(x.id),
                    onChanged: (v) => set(() => v == true ? picked.add(x.id) : picked.remove(x.id)),
                    secondary: Avatar(id: x.id, size: 36),
                    title: Text(x.name),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                  child: FilledButton(
                    onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, true),
                    child: const Text('Send invite'),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
    if (ok == true) {
      await e.inviteToGroup(g.id, picked.toList());
      if (context.mounted) toast(context, 'Invite sent');
    }
  }
}
