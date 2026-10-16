import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';
import 'space_screen.dart';

class SpaceSettingsScreen extends ConsumerWidget {
  const SpaceSettingsScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final s = ref.watch(spaceProvider(id)).value;
    if (s == null) return Scaffold(appBar: AppBar());
    final e = ref.read(engineProvider);
    final role = s.roleOf(e.me.id);
    final owner = role == Role.owner;
    final canEdit = role.index <= Role.mod.index;

    return Scaffold(
      appBar: AppBar(title: const Text('Space settings')),
      body: ListView(
        children: [
          SectionLabel('About'),
          RowTile(
            icon: Icons.title_rounded,
            title: s.name,
            subtitle: 'Name',
            onTap: owner
                ? () async {
                    final n = await prompt(
                      context,
                      title: 'Space name',
                      body: 'People see this on the invite and in their space list.',
                      initial: s.name,
                      maxLength: 48,
                      selectAll: true,
                      allowEmpty: false,
                      capitalization: TextCapitalization.words,
                    );
                    if (n != null && n.trim().isNotEmpty)
                      await e.updateSpace(
                        id,
                        (x) => x.copyWith(name: n.trim()),
                      );
                  }
                : null,
          ),
          RowTile(
            icon: Icons.notes_rounded,
            title: s.about.isEmpty ? 'No description' : s.about,
            subtitle: 'Description',
            onTap: owner
                ? () async {
                    final n = await prompt(
                      context,
                      title: 'Description',
                      body: 'Shown at the top of the space. Clear it to remove the description.',
                      initial: s.about,
                      maxLength: 280,
                      multiline: true,
                      minLines: 4,
                    );
                    if (n != null)
                      await e.updateSpace(
                        id,
                        (x) => x.copyWith(about: n.trim()),
                      );
                  }
                : null,
          ),
          RowTile(
            icon: Icons.person_add_alt_rounded,
            title: 'Invite people',
            onTap: () => showInvite(context, ref, s),
          ),
          if (owner)
            SwitchTile(
              icon: Icons.public_rounded,
              title: 'Public space',
              subtitle: 'Contacts can see the name and ask to join. The key stays in the invite.',
              value: s.public,
              onChanged: (v) => e.updateSpace(id, (x) => x.copyWith(public: v)),
            ),
          SectionLabel('History and consent'),
          if (owner)
            SwitchTile(
              icon: Icons.inventory_2_outlined,
              title: 'Members may keep history',
              subtitle: 'When off, every message only shows while its author is online.',
              value: s.archive,
              onChanged: (v) =>
                  e.updateSpace(id, (x) => x.copyWith(archive: v)),
            ),
          SwitchTile(
            icon: Icons.cloud_done_outlined,
            title: 'Keep history on this phone',
            subtitle: s.archive
                ? 'Hold copies of messages whose authors allow it, and share them with other members.'
                : 'The owner has turned history off for this space.',
            value: s.preserve && s.archive,
            onChanged: s.archive
                ? (v) => e.updateSpace(id, (x) => x.copyWith(preserve: v))
                : null,
          ),
          SwitchTile(
            icon: Icons.share_outlined,
            title: 'Let members keep my messages',
            subtitle: 'Applies to messages you send from now on.',
            value: s.shareMine,
            onChanged: (v) =>
                e.updateSpace(id, (x) => x.copyWith(shareMine: v)),
          ),
          SwitchTile(
            icon: Icons.notifications_off_outlined,
            title: 'Mute',
            value: s.muted,
            onChanged: (v) => e.updateSpace(id, (x) => x.copyWith(muted: v)),
          ),
          SectionLabel('Technical'),
          RowTile(
            icon: Icons.info_outline_rounded,
            title: 'Scope and encryption',
            subtitle: 'space:${s.id}',
            onTap: () =>
                showScopeTech(context, Scope.spaceMeta(s.id), spaceId: s.id),
          ),
          if (canEdit) ...[
            SectionLabel('Forum boards'),
            for (final c in s.forums)
              RowTile(
                icon: Icons.forum_outlined,
                title: c.name,
                onTap: () => showActions(context, [
                  SheetAction(Icons.edit_outlined, 'Rename', () async {
                    final name = await askSlug(
                      context,
                      title: 'Rename board',
                      initial: c.name,
                      action: 'Save',
                      body: 'Posts stay on this board. The tag is what people see.',
                      taken: [
                        for (final y in s.forums)
                          if (y.id != c.id) y.name,
                      ],
                    );
                    if (name == null || name.isEmpty) return;
                    await e.updateSpace(
                      id,
                      (x) => x.copyWith(
                        forums: x.forums
                            .map((y) => y.id == c.id ? Channel(c.id, name) : y)
                            .toList(),
                      ),
                    );
                  }),
                  if (s.forums.length > 1)
                    SheetAction(
                      Icons.delete_outline_rounded,
                      'Remove',
                      () async {
                        await e.updateSpace(
                          id,
                          (x) => x.copyWith(
                            forums: x.forums
                                .where((y) => y.id != c.id)
                                .toList(),
                          ),
                        );
                      },
                      danger: true,
                    ),
                ], title: c.name),
              ),
            RowTile(
              icon: Icons.add_rounded,
              title: 'New board',
              onTap: () async {
                final name = await askSlug(
                  context,
                  title: 'New board',
                  hint: 'board-name',
                  action: 'Create',
                  body: 'A board holds posts. The tag is short, like ideas or bugs.',
                  taken: s.forums.map((b) => b.name).toList(),
                );
                if (name == null || name.isEmpty) return;
                await e.updateSpace(
                  id,
                  (x) => x.copyWith(
                    forums: [
                      ...x.forums,
                      Channel(newId().substring(0, 8), name),
                    ],
                  ),
                );
              },
            ),
            SectionLabel('Channels'),
            for (final c in s.channels)
              RowTile(
                icon: Icons.tag_rounded,
                title: c.name,
                onTap: () => showActions(context, [
                  SheetAction(Icons.edit_outlined, 'Edit', () async {
                    final drafted = await askNamed(
                      context,
                      title: '#${c.name}',
                      name: c.name,
                      about: c.about,
                      action: 'Save',
                      slug: true,
                      nameMax: 32,
                      body: 'The tag is what people see. Messages stay in this channel.',
                      taken: [
                        for (final y in s.channels)
                          if (y.id != c.id) y.name,
                      ],
                    );
                    if (drafted == null || drafted.name.isEmpty) return;
                    await e.updateSpace(
                      id,
                      (x) => x.copyWith(
                        channels: x.channels
                            .map(
                              (y) => y.id == c.id
                                  ? Channel(
                                      c.id,
                                      drafted.name,
                                      about: drafted.about,
                                    )
                                  : y,
                            )
                            .toList(),
                      ),
                    );
                  }),
                  if (s.channels.length > 1)
                    SheetAction(
                      Icons.delete_outline_rounded,
                      'Remove',
                      () async {
                        await e.updateSpace(
                          id,
                          (x) => x.copyWith(
                            channels: x.channels
                                .where((y) => y.id != c.id)
                                .toList(),
                          ),
                        );
                      },
                      danger: true,
                    ),
                ], title: '#${c.name}'),
              ),
            RowTile(
              icon: Icons.add_rounded,
              title: 'New channel',
              subtitle: 'Tag and what it is for',
              onTap: () async {
                final drafted = await askNamed(
                  context,
                  title: 'New channel',
                  action: 'Create',
                  slug: true,
                  nameMax: 32,
                  nameHint: 'general',
                  body: 'You post here with the rest of the space. The tag is short, like general or announcements.',
                  taken: s.channels.map((c) => c.name).toList(),
                );
                if (drafted == null || drafted.name.isEmpty) return;
                await e.updateSpace(
                  id,
                  (x) => x.copyWith(
                    channels: [
                      ...x.channels,
                      Channel(
                        newId().substring(0, 8),
                        drafted.name,
                        about: drafted.about,
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
          SectionLabel('Security'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Text(
              'Messages are sealed with XChaCha20-Poly1305 using the space key and signed with each '
              'member\'s Ed25519 key. Relaying peers can\'t read them.',
              style: Txt.small(p.muted),
            ),
          ),
          const SizedBox(height: Space.xl),
          RowTile(
            icon: Icons.logout_rounded,
            title: 'Leave space',
            danger: true,
            onTap: () async {
              final ok = await confirm(
                context,
                title: 'Leave ${s.name}?',
                body:
                    'Your copy of the space is deleted from this phone. Your messages disappear for others '
                    'unless members kept them.',
                action: 'Leave',
                danger: true,
              );
              if (!ok) return;
              await e.leaveSpace(id);
              ref.read(inboxPaneProvider.notifier).show(InboxPane.channels);
              if (context.mounted) context.go('/communities');
            },
          ),
          const SizedBox(height: Space.xxl),
        ],
      ),
    );
  }
}
