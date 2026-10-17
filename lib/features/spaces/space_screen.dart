import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';
import 'broadcast_screen.dart';
import 'spaces_screen.dart';

class SpaceScreen extends ConsumerStatefulWidget {
  const SpaceScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<SpaceScreen> createState() => _SpaceScreenState();
}

class _SpaceScreenState extends ConsumerState<SpaceScreen> {
  @override
  void initState() {
    super.initState();
    ref.read(engineProvider).refreshSpace(widget.id);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final space = ref.watch(spaceProvider(widget.id)).value;
    if (space == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.grid_off_rounded,
          title: 'Space not found',
        ),
      );
    }
    final e = ref.read(engineProvider);
    final role = space.roleOf(e.me.id);
    final members = ref.watch(membersProvider(widget.id)).value ?? const [];

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Row(
            children: [
              SpaceGlyph(space: space, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      space.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Txt.heading(p.ink),
                    ),
                    Text(
                      '${members.where((m) => m.online).length} of ${members.length} online',
                      style: Txt.mono(p.muted, size: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconBtn(
              Icons.info_outline_rounded,
              tooltip: 'Technical',
              onTap: () => showScopeTech(
                context,
                Scope.spaceMeta(space.id),
                spaceId: space.id,
              ),
            ),
            IconBtn(
              Icons.person_add_alt_rounded,
              tooltip: 'Invite',
              onTap: () => showInvite(context, ref, space),
            ),
            IconBtn(
              Icons.tune_rounded,
              tooltip: 'Settings',
              onTap: () => context.push('/s/${space.id}/settings'),
            ),
            const SizedBox(width: 4),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Forum'),
              Tab(text: 'Members'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _Forum(space: space, canEdit: role.index <= Role.mod.index),
            _Members(space: space, members: members, myRole: role),
          ],
        ),
      ),
    );
  }
}

class _Forum extends ConsumerWidget {
  const _Forum({required this.space, required this.canEdit});
  final SpaceInfo space;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final boards = space.forums.isEmpty
        ? const [Channel('general', 'general')]
        : space.forums;
    return ListView(
      children: [
        if (space.about.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.lg,
              Space.gutter,
              0,
            ),
            child: Text(space.about, style: Txt.body(p.inkSoft)),
          ),
        SectionLabel(
          'Rooms',
          trailing: canEdit
              ? GestureDetector(
                  onTap: () async {
                    final name = await askSlug(
                      context,
                      title: 'New room',
                      hint: 'room-name',
                      action: 'Create',
                      body: 'Rooms are live chats. The tag is what people see, like general or trading.',
                      taken: space.forums.map((b) => b.name).toList(),
                    );
                    if (name == null || name.isEmpty) return;
                    await e.updateSpace(
                      space.id,
                      (s) => s.copyWith(
                        forums: [
                          ...s.forums,
                          Channel(newId().substring(0, 8), name),
                        ],
                      ),
                    );
                  },
                  child: Icon(Icons.add_rounded, size: 18, color: p.muted),
                )
              : null,
        ),
        for (final b in boards) ForumRoomRow(space: space, board: b),
        Padding(
          padding: const EdgeInsets.all(Space.gutter),
          child: Text(
            'Forum rooms are live chats among members. History follows the space keep setting.',
            style: Txt.mono(p.faint, size: 11),
          ),
        ),
      ],
    );
  }
}

class _Members extends ConsumerWidget {
  const _Members({
    required this.space,
    required this.members,
    required this.myRole,
  });
  final SpaceInfo space;
  final List<({String id, Role role, bool online})> members;
  final Role myRole;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    return ListView(
      children: [
        SectionLabel('${members.length} members'),
        for (final m in members)
          ListTile(
            leading: Avatar(id: m.id, size: 38),
            title: Text(e.nameOf(m.id)),
            subtitle: Text(
              m.online ? 'online' : 'offline',
              style: Txt.mono(m.online ? p.accent : p.faint, size: 11),
            ),
            trailing: m.role == Role.member
                ? null
                : Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(Radii.pill),
                      border: Border.all(color: p.line),
                    ),
                    child: Text(
                      m.role.name,
                      style: Txt.mono(p.inkSoft, size: 10.5),
                    ),
                  ),
            onTap: m.id == e.me.id
                ? () => context.go('/me')
                : () => context.push('/u/${m.id}'),
            onLongPress: myRole == Role.owner && m.id != e.me.id
                ? () => showActions(context, [
                    if (m.role != Role.mod)
                      SheetAction(Icons.shield_outlined, 'Make moderator', () {
                        e.updateSpace(
                          space.id,
                          (s) =>
                              s.copyWith(roles: {...s.roles, m.id: Role.mod}),
                        );
                      }),
                    if (m.role == Role.mod)
                      SheetAction(
                        Icons.remove_moderator_outlined,
                        'Remove moderator',
                        () {
                          e.updateSpace(
                            space.id,
                            (s) =>
                                s.copyWith(roles: {...s.roles}..remove(m.id)),
                          );
                        },
                      ),
                    SheetAction(Icons.block_rounded, 'Ban from space', () {
                      e.updateSpace(
                        space.id,
                        (s) =>
                            s.copyWith(roles: {...s.roles, m.id: Role.banned}),
                      );
                    }, danger: true),
                  ], title: e.nameOf(m.id).toUpperCase())
                : null,
          ),
        Padding(
          padding: const EdgeInsets.all(Space.gutter),
          child: Text(
            'Members are known from their signed join notes. Owners can promote moderators or ban.',
            style: Txt.mono(p.faint, size: 11),
          ),
        ),
      ],
    );
  }
}

Future<void> _sendInvite(
  BuildContext context,
  WidgetRef ref,
  String link,
) async {
  final e = ref.read(engineProvider);
  final people = e.people().where((x) => !x.blocked).toList();
  final groups = e.db.groups();
  final picked = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .7),
        child: ListView(
          shrinkWrap: true,
          children: [
            if (groups.isNotEmpty) const SectionLabel('Groups'),
            for (final g in groups)
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: Text(g.name),
                onTap: () => Navigator.pop(ctx, Scope.gdm(g.id)),
              ),
            const SectionLabel('People'),
            for (final person in people)
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: Text(e.nameOf(person.id)),
                onTap: () => Navigator.pop(ctx, Scope.dm(e.me.id, person.id)),
              ),
          ],
        ),
      ),
    ),
  );
  if (picked == null) return;
  await e.sendMessage(picked, text: link);
  if (context.mounted) toast(context, 'Invite sent');
}

Future<void> showInvite(
  BuildContext context,
  WidgetRef ref,
  SpaceInfo space,
) async {
  late final String link;
  try {
    link = await ref.read(engineProvider).spaceLink(space.id);
  } catch (e) {
    if (context.mounted) toast(context, '$e');
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final p = ctx.pal;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.gutter,
            0,
            Space.gutter,
            Space.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Invite to ${space.name}', style: Txt.heading(p.ink)),
              const SizedBox(height: Space.sm),
              Text(
                space.public
                    ? 'This space is public and listed in the network directory, so anyone may join.'
                    : 'Anyone with this invite holds the space key. Share it only with people you trust.',
                textAlign: TextAlign.center,
                style: Txt.small(p.muted),
              ),
              const SizedBox(height: Space.lg),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(Radii.lg),
                ),
                child: QrImageView(
                  data: link,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: Space.lg),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: link));
                        toast(ctx, 'Invite copied');
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Copy'),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _sendInvite(ctx, ref, link),
                      icon: const Icon(Icons.send_rounded, size: 18),
                      label: const Text('Send in chat'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
