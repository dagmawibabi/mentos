import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../widgets/ui.dart';
import '../../core/pin.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconBtn(
            Icons.help_outline_rounded,
            tooltip: 'Help',
            onTap: () => context.push('/help'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          SectionLabel('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Segmented<ThemeMode>(
              value: s.themeMode,
              options: const {
                ThemeMode.system: 'System',
                ThemeMode.light: 'Light',
                ThemeMode.dark: 'Dark',
              },
              onChanged: (v) => n.update((x) => x.copyWith(themeMode: v)),
            ),
          ),
          const SizedBox(height: Space.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Segmented<String>(
              value: s.accent,
              options: const {
                'emerald': 'Emerald',
                'blue': 'Blue',
                'amber': 'Amber',
                'ink': 'Ink',
              },
              onChanged: (v) => n.update((x) => x.copyWith(accent: v)),
            ),
          ),
          const SizedBox(height: Space.sm),
          SwitchTile(
            icon: Icons.animation_rounded,
            title: 'Reduce motion',
            value: s.reduceMotion,
            onChanged: (v) => n.update((x) => x.copyWith(reduceMotion: v)),
          ),
          SectionLabel('Navigation'),
          SwitchTile(
            icon: Icons.view_agenda_outlined,
            title: 'Feed tab',
            subtitle: 'Show Feed in the bottom bar',
            value: s.showFeedTab,
            onChanged: (v) => n.update((x) => x.copyWith(showFeedTab: v)),
          ),
          SwitchTile(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Wallet tab',
            subtitle:
                'Show Wallet in the bottom bar. Settings can still open it.',
            value: s.showWalletTab,
            onChanged: (v) => n.update((x) => x.copyWith(showWalletTab: v)),
          ),
          SectionLabel('What others may keep'),
          SwitchTile(
            icon: Icons.article_outlined,
            title: 'Followers may keep my posts',
            subtitle:
                'Your posts stay visible while you\'re away, through followers who agree. '
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
          RowTile(
            icon: Icons.notifications_outlined,
            title: 'Notifications',
            subtitle: s.systemNotify
                ? 'Messages, mentions, invites and more'
                : 'Off',
            onTap: () => context.push('/notifications'),
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
            subtitle: s.lockHash.isEmpty
                ? 'Ask for a PIN after you leave'
                : 'Relocks after ${s.lockAfter}s in the background',
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
              subtitle: s.lockAfter == 0
                  ? 'Immediately'
                  : '${s.lockAfter} seconds',
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
            subtitle: s.quotaMb >= 1024
                ? '${s.quotaMb ~/ 1024} GB'
                : '${s.quotaMb} MB',
            onTap: () => _quota(context, ref),
          ),
          SwitchTile(
            icon: Icons.wifi_tethering_rounded,
            title: 'Stay connected in the background',
            subtitle: 'Keep the node running when Mentos is not on screen',
            value: s.keepAlive,
            onChanged: (v) => n.update((x) => x.copyWith(keepAlive: v)),
          ),
          RowTile(
            icon: Icons.folder_outlined,
            title: 'Hosted files',
            subtitle: 'Files this phone is serving',
            onTap: () => context.push('/files'),
          ),
          RowTile(
            icon: Icons.data_object_rounded,
            title: 'Data explorer',
            subtitle: 'Browse, verify and export everything stored here',
            onTap: () => context.push('/data'),
          ),
          RowTile(
            icon: Icons.hub_outlined,
            title: 'Network and custody',
            onTap: () => context.go('/network'),
          ),
          RowTile(
            icon: Icons.shield_outlined,
            title: 'Privacy and transports',
            subtitle: switch (s.privacy) {
              'relay' => 'Hide my IP',
              'tor' => 'Tor via ${s.proxyUrl}',
              _ => 'Standard',
            },
            onTap: () => context.push('/privacy'),
          ),
          RowTile(
            icon: Icons.monitor_heart_outlined,
            title: 'Network diagnostics',
            onTap: () => context.push('/diagnostics'),
          ),
          RowTile(
            icon: Icons.block_rounded,
            title: 'Blocked people',
            onTap: () => context.push('/people?tab=3'),
          ),
          SectionLabel('Money'),
          RowTile(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Wallet',
            subtitle: 'Mentos coins on the shared ledger',
            onTap: () => context.go('/wallet'),
          ),
          RowTile(
            icon: Icons.storefront_outlined,
            title: 'Marketplace',
            subtitle: 'Mentos for birr, plugins, ads, tasks',
            onTap: () => context.push('/market'),
          ),
          RowTile(
            icon: Icons.terminal_rounded,
            title: 'Developer',
            subtitle: s.devMode ? 'Local API is on' : 'Logs and the local API',
            onTap: () => context.push('/dev'),
          ),
          SectionLabel('Identity'),
          RowTile(
            icon: Icons.switch_account_outlined,
            title: 'Accounts',
            subtitle: 'Add another identity or switch between them',
            onTap: () => context.push('/accounts'),
          ),
          RowTile(
            icon: Icons.key_rounded,
            title: 'Recovery phrase',
            subtitle:
                'Restores this identity and the chats and files saved with it',
            onTap: () => context.push('/backup'),
          ),
          RowTile(
            icon: Icons.delete_forever_outlined,
            title: 'Erase identity and data',
            danger: true,
            onTap: () async {
              final ok = await confirm(
                context,
                title: 'Erase everything?',
                body:
                    'Deletes your key, posts, messages and files from this phone. Copies others kept '
                    'stay with them. Without your recovery phrase this can\'t be undone.',
                action: 'Erase',
                danger: true,
              );
              if (ok) await ref.read(sessionProvider.notifier).wipe();
            },
          ),
          const SizedBox(height: Space.xxl),
          Center(child: const MentosMark(size: 22)),
          const SizedBox(height: Space.sm),
          Center(
            child: Text(
              'Mentos 1.0 · peer-to-peer over iroh',
              style: Txt.mono(p.faint, size: 11),
            ),
          ),
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
                trailing: o == s.defaultTtl
                    ? Icon(Icons.check_rounded, color: ctx.pal.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      ),
    );
    if (v != null)
      ref
          .read(settingsProvider.notifier)
          .update((x) => x.copyWith(defaultTtl: v));
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
                trailing: o == s.quotaMb
                    ? Icon(Icons.check_rounded, color: ctx.pal.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      ),
    );
    if (v != null)
      ref.read(settingsProvider.notifier).update((x) => x.copyWith(quotaMb: v));
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
                trailing: o == s.lockAfter
                    ? Icon(Icons.check_rounded, color: ctx.pal.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      ),
    );
    if (v != null)
      ref
          .read(settingsProvider.notifier)
          .update((x) => x.copyWith(lockAfter: v));
  }

  Future<void> _pin(BuildContext context, WidgetRef ref) async {
    final has = ref.read(settingsProvider).lockHash.isNotEmpty;
    final pin = await showInputSheet<String>(
      context,
      (_) => _PinSheet(canClear: has),
    );
    if (pin == null || !context.mounted) return;
    if (pin.isEmpty) {
      ref
          .read(settingsProvider.notifier)
          .update((x) => x.copyWith(lockHash: '', lockBio: false));
      return;
    }
    final hash = await PinHash.create(pin);
    ref
        .read(settingsProvider.notifier)
        .update(
          (x) => x.copyWith(
            lockHash: hash,
            lockAfter: x.lockAfter == 0 ? 60 : x.lockAfter,
          ),
        );
  }
}

class _PinSheet extends StatefulWidget {
  const _PinSheet({required this.canClear});
  final bool canClear;

  @override
  State<_PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<_PinSheet> {
  final _pin = TextEditingController();
  final _again = TextEditingController();
  bool _hide = true;

  @override
  void dispose() {
    _pin.dispose();
    _again.dispose();
    super.dispose();
  }

  bool get _digits => RegExp(r'^\d{4,}$').hasMatch(_pin.text.trim());

  bool get _ok => _digits && _pin.text.trim() == _again.text.trim();

  String? get _error {
    final a = _pin.text.trim();
    final b = _again.text.trim();
    if (b.isNotEmpty && a != b) return 'Those PINs do not match';
    if (b.isNotEmpty && a.length < 4) return 'Use at least 4 digits';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final error = _error;
    return InputSheet(
      title: 'App lock',
      body: widget.canClear
          ? 'A new PIN replaces the current one. Mentos asks for it after the app has been in the background.'
          : 'Four or more digits. Mentos asks for it after the app has been in the background.',
      action: 'Save PIN',
      enabled: _ok,
      onAction: () => Navigator.pop(context, _pin.text.trim()),
      secondary: widget.canClear ? 'Turn off' : null,
      secondaryDanger: true,
      onSecondary: widget.canClear ? () => Navigator.pop(context, '') : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetLabel(
            'PIN',
            trailing: _pin.text.isEmpty ? null : '${_pin.text.length}',
          ),
          TextField(
            controller: _pin,
            autofocus: true,
            obscureText: _hide,
            keyboardType: TextInputType.number,
            maxLength: 32,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '4 or more digits',
              counterText: '',
              suffixIcon: IconButton(
                tooltip: _hide ? 'Show' : 'Hide',
                onPressed: () => setState(() => _hide = !_hide),
                icon: Icon(
                  _hide
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color: p.muted,
                ),
              ),
            ),
          ),
          const SizedBox(height: Space.lg),
          const SheetLabel('Repeat'),
          TextField(
            controller: _again,
            obscureText: _hide,
            keyboardType: TextInputType.number,
            maxLength: 32,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_ok) Navigator.pop(context, _pin.text.trim());
            },
            decoration: const InputDecoration(
              hintText: 'Same digits again',
              counterText: '',
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(error, style: Txt.small(p.danger)),
          ],
        ],
      ),
    );
  }
}
