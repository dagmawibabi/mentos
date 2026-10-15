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
                    final n = await prompt(context, title: 'Space name', initial: s.name, maxLength: 48);
                    if (n != null && n.trim().isNotEmpty) await e.updateSpace(id, (x) => x.copyWith(name: n.trim()));
                  }
                : null,
          ),
          RowTile(
            icon: Icons.notes_rounded,
            title: s.about.isEmpty ? 'No description' : s.about,
            subtitle: 'Description',
            onTap: owner
                ? () async {
                    final n = await prompt(context, title: 'Description', initial: s.about, maxLength: 280);
                    if (n != null) await e.updateSpace(id, (x) => x.copyWith(about: n.trim()));
                  }
                : null,
          ),
          RowTile(icon: Icons.person_add_alt_rounded, title: 'Invite people', onTap: () => showInvite(context, ref, s)),
          SectionLabel('History and consent'),
          if (owner)
            SwitchTile(
              icon: Icons.inventory_2_outlined,
              title: 'Members may keep history',
              subtitle: 'When off, every message only shows while its author is online.',
              value: s.archive,
              onChanged: (v) => e.updateSpace(id, (x) => x.copyWith(archive: v)),
            ),
          SwitchTile(
            icon: Icons.cloud_done_outlined,
            title: 'Keep history on this phone',
            subtitle: s.archive
                ? 'Hold copies of messages whose authors allow it, and share them with other members.'
                : 'The owner has turned history off for this space.',
            value: s.preserve && s.archive,
            onChanged: s.archive ? (v) => e.updateSpace(id, (x) => x.copyWith(preserve: v)) : null,
          ),
          SwitchTile(
            icon: Icons.share_outlined,
            title: 'Let members keep my messages',
            subtitle: 'Applies to messages you send from now on.',
            value: s.shareMine,
            onChanged: (v) => e.updateSpace(id, (x) => x.copyWith(shareMine: v)),
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
            onTap: () => showScopeTech(context, Scope.spaceMeta(s.id), spaceId: s.id),
          ),
          if (canEdit) ...[
            SectionLabel('Forum boards'),
            for (final c in s.forums)
              RowTile(
                icon: Icons.forum_outlined,
                title: c.name,
                onTap: () => showActions(context, [
                  SheetAction(Icons.edit_outlined, 'Rename', () async {
                    final n = await prompt(context, title: 'Rename board', initial: c.name, maxLength: 32);
                    final name = n?.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9\-_]+'), '-');
                    if (name == null || name.isEmpty) return;
                    await e.updateSpace(id, (x) => x.copyWith(
                        forums: x.forums.map((y) => y.id == c.id ? Channel(c.id, name) : y).toList()));
                  }),
                  if (s.forums.length > 1)
                    SheetAction(Icons.delete_outline_rounded, 'Remove', () async {
                      await e.updateSpace(id, (x) => x.copyWith(forums: x.forums.where((y) => y.id != c.id).toList()));
                    }, danger: true),
                ], title: c.name),
              ),
            RowTile(
              icon: Icons.add_rounded,
              title: 'New board',
              onTap: () async {
                final n = await prompt(context, title: 'New board', hint: 'board-name', action: 'Create', maxLength: 32);
                final name = n?.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9\-_]+'), '-');
                if (name == null || name.isEmpty) return;
                await e.updateSpace(id, (x) => x.copyWith(forums: [...x.forums, Channel(newId().substring(0, 8), name)]));
              },
            ),
            SectionLabel('Channels'),
            for (final c in s.channels)
              RowTile(
                icon: Icons.tag_rounded,
                title: c.name,
                onTap: () => showActions(context, [
                  SheetAction(Icons.edit_outlined, 'Rename', () async {
                    final n = await prompt(context, title: 'Rename channel', initial: c.name, maxLength: 32);
                    final name = n?.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9\-_]+'), '-');
                    if (name == null || name.isEmpty) return;
                    await e.updateSpace(id, (x) => x.copyWith(
                        channels: x.channels.map((y) => y.id == c.id ? Channel(c.id, name, about: c.about) : y).toList()));
                  }),
                  SheetAction(Icons.notes_rounded, 'Description', () async {
                    final drafted = await _askChannel(context, name: c.name, about: c.about, title: 'Channel');
                    if (drafted == null) return;
                    await e.updateSpace(id, (x) => x.copyWith(
                        channels: x.channels.map((y) => y.id == c.id ? Channel(c.id, c.name, about: drafted.about) : y).toList()));
                  }),
                  if (s.channels.length > 1)
                    SheetAction(Icons.delete_outline_rounded, 'Remove', () async {
                      await e.updateSpace(id, (x) => x.copyWith(channels: x.channels.where((y) => y.id != c.id).toList()));
                    }, danger: true),
                ], title: '#${c.name}'),
              ),
            RowTile(
              icon: Icons.add_rounded,
              title: 'New channel',
              subtitle: 'Name and what it is for',
              onTap: () async {
                final drafted = await _askChannel(context);
                if (drafted == null || drafted.name.isEmpty) return;
                final slug = drafted.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\-_]+'), '-');
                if (slug.isEmpty) return;
                await e.updateSpace(id, (x) => x.copyWith(
                    channels: [...x.channels, Channel(newId().substring(0, 8), slug, about: drafted.about)]));
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
              final ok = await confirm(context,
                  title: 'Leave ${s.name}?',
                  body: 'Your copy of the space is deleted from this phone. Your messages disappear for others '
                      'unless members kept them.',
                  action: 'Leave',
                  danger: true);
              if (!ok) return;
              await e.leaveSpace(id);
              if (context.mounted) context.go('/spaces');
            },
          ),
          const SizedBox(height: Space.xxl),
        ],
      ),
    );
  }
}

Future<({String name, String about})?> _askChannel(
  BuildContext context, {
  String name = '',
  String about = '',
  String title = 'New channel',
}) {
  return showDialog<({String name, String about})>(
    context: context,
    builder: (ctx) => _ChannelDialog(title: title, name: name, about: about),
  );
}

class _ChannelDialog extends StatefulWidget {
  const _ChannelDialog({required this.title, required this.name, required this.about});
  final String title;
  final String name;
  final String about;

  @override
  State<_ChannelDialog> createState() => _ChannelDialogState();
}

class _ChannelDialogState extends State<_ChannelDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.name);
  late final TextEditingController _about = TextEditingController(text: widget.about);

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: widget.name.isEmpty,
            maxLength: 32,
            decoration: const InputDecoration(hintText: 'Name', counterText: ''),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _about,
            maxLength: 240,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(hintText: 'What this channel is for', counterText: ''),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, (name: name, about: _about.text.trim()));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
