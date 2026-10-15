import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../widgets/ui.dart';
import 'lock_gate.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          SectionLabel('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Segmented<ThemeMode>(
              value: s.themeMode,
              options: const {ThemeMode.system: 'System', ThemeMode.light: 'Light', ThemeMode.dark: 'Dark'},
              onChanged: (v) => n.update((x) => x.copyWith(themeMode: v)),
            ),
          ),
          const SizedBox(height: Space.sm),
          SwitchTile(
            icon: Icons.animation_rounded,
            title: 'Reduce motion',
            value: s.reduceMotion,
            onChanged: (v) => n.update((x) => x.copyWith(reduceMotion: v)),
          ),
          SectionLabel('What others may keep'),
          SwitchTile(
            icon: Icons.article_outlined,
            title: 'Followers may keep my posts',
            subtitle: 'Your posts stay visible while you\'re away, through followers who agree. '
                'Turning this off asks them to delete their copies.',
            value: s.keepPosts,
            onChanged: (v) => n.update((x) => x.copyWith(keepPosts: v)),
          ),
          SwitchTile(
            icon: Icons.mode_comment_outlined,
            title: 'Post authors may keep my replies',
            subtitle: 'Comments, likes and votes you leave on someone\'s post.',
            value: s.keepReplies,
            onChanged: (v) => n.update((x) => x.copyWith(keepReplies: v)),
          ),
          SwitchTile(
            icon: Icons.badge_outlined,
            title: 'Contacts may remember my profile',
            subtitle: 'Your name and photo, so they don\'t see an alias while you\'re offline.',
            value: s.keepProfile,
            onChanged: (v) => n.update((x) => x.copyWith(keepProfile: v)),
          ),
          SectionLabel('Chats'),
          SwitchTile(
            icon: Icons.done_all_rounded,
            title: 'Read receipts',
            subtitle: 'If off, you won\'t send them either.',
            value: s.readReceipts,
            onChanged: (v) => n.update((x) => x.copyWith(readReceipts: v)),
          ),
          SwitchTile(
            icon: Icons.more_horiz_rounded,
            title: 'Typing indicators',
            value: s.typingIndicators,
            onChanged: (v) => n.update((x) => x.copyWith(typingIndicators: v)),
          ),
          SwitchTile(
            icon: Icons.handshake_outlined,
            title: 'Accept sync requests automatically',
            subtitle: 'Keep a contact\'s messages whenever they ask, without confirming.',
            value: s.autoAcceptSync,
            onChanged: (v) => n.update((x) => x.copyWith(autoAcceptSync: v)),
          ),
          SwitchTile(
            icon: Icons.info_outline_rounded,
            title: 'Show offline hints in chats',
            value: s.showOfflineHint,
            onChanged: (v) => n.update((x) => x.copyWith(showOfflineHint: v)),
          ),
          RowTile(
            icon: Icons.timer_outlined,
            title: 'Default disappearing timer',
            subtitle: ttlLabel(s.defaultTtl),
            onTap: () => _ttl(context, ref),
          ),
          SectionLabel('Discovery'),
          SwitchTile(
            icon: Icons.radar_outlined,
            title: 'Let new connections discover me',
            subtitle: 'People you have not followed yet may see this profile and public posts when your nodes meet.',
            value: s.discoverable,
            onChanged: (v) => n.update((x) => x.copyWith(discoverable: v)),
          ),
          SwitchTile(
            icon: Icons.filter_alt_outlined,
            title: 'Hide people I\'m not connected with',
            subtitle: 'Feed and stories only show accounts you follow, chat with, or keep.',
            value: s.hideStrangers,
            onChanged: (v) => n.update((x) => x.copyWith(hideStrangers: v)),
          ),
          SwitchTile(
            icon: Icons.notifications_outlined,
            title: 'Banner when a file arrives',
            subtitle: 'Nothing else interrupts the screen. Muted chats stay quiet.',
            value: s.systemNotify,
            onChanged: (v) => n.update((x) => x.copyWith(systemNotify: v)),
          ),
          SwitchTile(
            icon: Icons.visibility_off_outlined,
            title: 'Hide NSFW',
            subtitle: 'Blurred posts, stories and messages stay covered.',
            value: s.hideNsfw,
            onChanged: (v) => n.update((x) => x.copyWith(hideNsfw: v)),
          ),
          RowTile(
            icon: Icons.lock_outline_rounded,
            title: s.lockHash.isEmpty ? 'App lock' : 'App lock is on',
            subtitle: s.lockHash.isEmpty ? 'Ask for a PIN after you leave' : 'Relocks after ${s.lockAfter}s in the background',
            onTap: () => _pin(context, ref),
          ),
          if (s.lockHash.isNotEmpty) ...[
            SwitchTile(
              icon: Icons.fingerprint_rounded,
              title: 'Unlock with biometrics',
              subtitle: 'Fingerprint or face, when this device has it.',
              value: s.lockBio,
              onChanged: (v) => n.update((x) => x.copyWith(lockBio: v)),
            ),
            RowTile(
              icon: Icons.timer_outlined,
              title: 'Lock after leaving',
              subtitle: s.lockAfter == 0 ? 'Immediately' : '${s.lockAfter} seconds',
              onTap: () => _lockAfter(context, ref),
            ),
          ],
          SectionLabel('Storage and network'),
          SwitchTile(
            icon: Icons.download_rounded,
            title: 'Load media automatically',
            value: s.autoDownload,
            onChanged: (v) => n.update((x) => x.copyWith(autoDownload: v)),
          ),
          RowTile(
            icon: Icons.sd_storage_outlined,
            title: 'File storage limit',
            subtitle: s.quotaMb >= 1024 ? '${s.quotaMb ~/ 1024} GB' : '${s.quotaMb} MB',
            onTap: () => _quota(context, ref),
          ),
          RowTile(icon: Icons.folder_outlined, title: 'Files on this phone', onTap: () => context.push('/files')),
          RowTile(icon: Icons.hub_outlined, title: 'Network and custody', onTap: () => context.go('/network')),
          RowTile(icon: Icons.block_rounded, title: 'Blocked people', onTap: () => context.push('/people?tab=3')),
          SectionLabel('Identity'),
          RowTile(
            icon: Icons.key_rounded,
            title: 'Recovery phrase',
            subtitle: 'Restores this identity and the chats and files saved with it',
            onTap: () => context.push('/backup'),
          ),
          RowTile(
            icon: Icons.delete_forever_outlined,
            title: 'Erase identity and data',
            danger: true,
            onTap: () async {
              final ok = await confirm(context,
                  title: 'Erase everything?',
                  body: 'Deletes your key, posts, messages and files from this phone. Copies others kept '
                      'stay with them. Without your recovery phrase this can\'t be undone.',
                  action: 'Erase',
                  danger: true);
              if (ok) await ref.read(sessionProvider.notifier).wipe();
            },
          ),
          const SizedBox(height: Space.xxl),
          Center(child: const MentosMark(size: 22)),
          const SizedBox(height: Space.sm),
          Center(child: Text('Mentos 1.0 · peer-to-peer over iroh', style: Txt.mono(p.faint, size: 11))),
        ],
      ),
    );
  }

  Future<void> _ttl(BuildContext context, WidgetRef ref) async {
    final s = ref.read(settingsProvider);
    const options = [0, 300, 3600, 86400, 604800];
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in options)
              ListTile(
                title: Text(ttlLabel(o)),
                trailing: o == s.defaultTtl ? Icon(Icons.check_rounded, color: ctx.pal.accent) : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      ),
    );
    if (v != null) ref.read(settingsProvider.notifier).update((x) => x.copyWith(defaultTtl: v));
  }

  Future<void> _quota(BuildContext context, WidgetRef ref) async {
    final s = ref.read(settingsProvider);
    const options = [512, 1024, 2048, 8192];
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in options)
              ListTile(
                title: Text(o >= 1024 ? '${o ~/ 1024} GB' : '$o MB'),
                trailing: o == s.quotaMb ? Icon(Icons.check_rounded, color: ctx.pal.accent) : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      ),
    );
    if (v != null) ref.read(settingsProvider.notifier).update((x) => x.copyWith(quotaMb: v));
  }

  Future<void> _lockAfter(BuildContext context, WidgetRef ref) async {
    final s = ref.read(settingsProvider);
    const options = [0, 15, 60, 300];
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in options)
              ListTile(
                title: Text(o == 0 ? 'Immediately' : '$o seconds'),
                trailing: o == s.lockAfter ? Icon(Icons.check_rounded, color: ctx.pal.accent) : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      ),
    );
    if (v != null) ref.read(settingsProvider.notifier).update((x) => x.copyWith(lockAfter: v));
  }

  Future<void> _pin(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('App PIN'),
        content: TextField(
          controller: c,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '4 or more digits, empty to turn off'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (pin == null || (pin.isNotEmpty && pin.length < 4)) return;
    if (pin.isEmpty) {
      ref.read(settingsProvider.notifier).update((x) => x.copyWith(lockHash: '', lockBio: false));
      return;
    }
    ref.read(settingsProvider.notifier).update((x) => x.copyWith(
          lockHash: pin.isEmpty ? '' : pinHash(pin),
          lockAfter: x.lockAfter == 0 ? 60 : x.lockAfter,
        ));
  }
}
