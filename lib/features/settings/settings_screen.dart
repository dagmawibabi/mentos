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
import '../../widgets/avatar.dart';
import '../../net/market/market.dart';
import '../../net/pay/coin.dart';
import '../../widgets/input_sheet.dart';
import '../wallet/coin_wallet_screen.dart';
import '../../widgets/ui.dart';
import '../../core/pin.dart';

/// Settings, by topic. Each topic opens its own page so this one stays short.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final s = ref.watch(settingsProvider);
    final e = ref.watch(maybeEngineProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconBtn(Icons.help_outline_rounded, tooltip: 'Help', onTap: () => context.push('/help')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          if (e != null) const _ProfileCard(),
          _Group(title: 'Preferences', children: [
            _Nav(
              icon: Icons.palette_outlined,
              color: const Color(0xFF8B5CF6),
              title: 'Appearance',
              subtitle: '${switch (s.themeMode) {
                ThemeMode.light => 'Light',
                ThemeMode.dark => 'Dark',
                _ => 'System theme',
              }} · ${s.accent[0].toUpperCase()}${s.accent.substring(1)} · tabs',
              onTap: () => _open(context, const AppearanceSettings()),
            ),
            _Nav(
              icon: Icons.notifications_outlined,
              color: const Color(0xFFF43F5E),
              title: 'Notifications',
              subtitle: s.systemNotify ? 'Messages, mentions, money and more' : 'Off',
              onTap: () => context.push('/notifications'),
            ),
            _Nav(
              icon: Icons.chat_bubble_outline_rounded,
              color: const Color(0xFF0EA5E9),
              title: 'Chats',
              subtitle: 'Receipts, typing, sync, disappearing messages',
              onTap: () => _open(context, const ChatSettings()),
            ),
          ]),
          _Group(title: 'Privacy and security', children: [
            _Nav(
              icon: Icons.privacy_tip_outlined,
              color: p.accent,
              title: 'Privacy',
              subtitle: '${s.discoverable ? 'Discoverable' : 'Not discoverable'} · what others may keep',
              onTap: () => _open(context, const PrivacySettings()),
            ),
            _Nav(
              icon: Icons.lock_outline_rounded,
              color: const Color(0xFFF59E0B),
              title: 'App lock',
              subtitle: s.lockHash.isEmpty ? 'Off' : 'On · relocks after ${s.lockAfter == 0 ? 'leaving' : '${s.lockAfter}s'}',
              onTap: () => _open(context, const SecuritySettings()),
            ),
            _Nav(
              icon: Icons.block_rounded,
              color: p.danger,
              title: 'Blocked people',
              onTap: () => context.push('/people?tab=3'),
            ),
          ]),
          _Group(title: 'Data and network', children: [
            _Nav(
              icon: Icons.sd_storage_outlined,
              color: const Color(0xFF14B8A6),
              title: 'Storage and files',
              subtitle: '${s.quotaMb >= 1024 ? '${s.quotaMb ~/ 1024} GB' : '${s.quotaMb} MB'} limit · hosted files, transfers',
              onTap: () => _open(context, const StorageSettings()),
            ),
            _Nav(
              icon: Icons.inventory_2_outlined,
              color: const Color(0xFF6366F1),
              title: 'Who holds what',
              subtitle: 'What you keep for others, and who keeps yours',
              onTap: () => context.push('/custody'),
            ),
            _Nav(
              icon: Icons.hub_outlined,
              color: const Color(0xFF3B82F6),
              title: 'Network',
              subtitle: '${switch (s.privacy) {
                'relay' => 'Hide my IP',
                'tor' => 'Tor',
                _ => 'Standard transport',
              }} · ${s.keepAlive ? 'stays connected' : 'connects while open'}',
              onTap: () => _open(context, const NetworkSettings()),
            ),
          ]),
          _Group(title: 'Money', children: [
            _Nav(
              icon: Icons.account_balance_wallet_outlined,
              color: p.accent,
              title: 'Wallet and market',
              subtitle: [
                ref.watch(walletHiddenProvider) ? 'Balance hidden' : 'Balance shown',
                (e?.market?.adsEnabled ?? false) ? 'ads on' : 'ads off',
              ].join(' · '),
              onTap: () => _open(context, const MoneySettings()),
            ),
          ]),
          _Group(title: 'Account', children: [
            _Nav(
              icon: Icons.switch_account_outlined,
              color: const Color(0xFF0EA5E9),
              title: 'Accounts',
              subtitle: 'Add another identity or switch',
              onTap: () => context.push('/accounts'),
            ),
            _Nav(
              icon: Icons.key_rounded,
              color: const Color(0xFFF59E0B),
              title: 'Recovery phrase and backup',
              subtitle: 'Restores this identity on another phone',
              onTap: () => context.push('/backup'),
            ),
          ]),
          _Group(title: 'More', children: [
            _Nav(
              icon: Icons.terminal_rounded,
              color: p.inkSoft,
              title: 'Developer',
              subtitle: !s.devMode ? 'Console, API and a browser dashboard' : (s.devLan ? 'Dashboard open to your network' : 'Dashboard on this device'),
              onTap: () => context.push('/dev'),
            ),
            _Nav(
              icon: Icons.menu_book_outlined,
              color: p.inkSoft,
              title: 'How Mentos works',
              onTap: () => context.push('/help'),
            ),
          ]),
          _Group(title: 'Danger zone', children: [
            _Nav(
              icon: Icons.delete_forever_outlined,
              color: p.danger,
              title: 'Erase identity and data',
              danger: true,
              onTap: () async {
                final ok = await confirm(
                  context,
                  title: 'Erase everything?',
                  body: 'Deletes your key, posts, messages and files from this phone. Copies others kept '
                      'stay with them. Without your recovery phrase this can\'t be undone.',
                  action: 'Erase',
                  danger: true,
                );
                if (ok) await ref.read(sessionProvider.notifier).wipe();
              },
            ),
          ]),
          const SizedBox(height: Space.xl),
          const Center(child: MentosMark(size: 22)),
          const SizedBox(height: Space.sm),
          Center(child: Text('Mentos 1.0 · peer-to-peer over iroh', style: Txt.mono(p.faint, size: 11))),
        ],
      ),
    );
  }
}

void _open(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(engineProvider);
    final profile = ref.watch(myProfileProvider).value;
    final name = profile?.displayName ?? e.myProfile.displayName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: p.line)),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => context.push('/edit-profile'),
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Row(
              children: [
                Avatar(id: e.me.id, size: 58, presence: false),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.title(p.ink)),
                      const SizedBox(height: 2),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: e.me.id));
                          toast(context, 'Address copied');
                        },
                        child: Row(
                          children: [
                            Text('${e.me.id.substring(0, 8)}…${e.me.id.substring(56)}', style: Txt.mono(p.muted, size: 11.5)),
                            const SizedBox(width: 4),
                            Icon(Icons.copy_rounded, size: 12, color: p.faint),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('Edit profile', style: Txt.small(p.accent).copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                IconBtn(Icons.qr_code_rounded, tooltip: 'Your code', onTap: () => context.push('/connect')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A titled card of rows.
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(title),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
          child: Container(
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: p.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Hairline(indent: 60),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Nav extends StatelessWidget {
  const _Nav({required this.icon, required this.color, required this.title, this.subtitle, required this.onTap, this.danger = false});
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: color.withValues(alpha: .14), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 19, color: color),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Txt.bodyStrong(danger ? p.danger : p.ink)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 1),
                    Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted)),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: p.faint),
          ],
        ),
      ),
    );
  }
}

/// A settings subpage: a title and grouped controls.
class _Page extends StatelessWidget {
  const _Page({required this.title, required this.children, this.intro});
  final String title;
  final String? intro;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          if (intro != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
              child: Text(intro!, style: Txt.small(p.muted)),
            ),
          ...children,
        ],
      ),
    );
  }
}

class AppearanceSettings extends ConsumerWidget {
  const AppearanceSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return _Page(title: 'Appearance', children: [
      SectionLabel('Theme'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
        child: Segmented<ThemeMode>(
          value: s.themeMode,
          options: const {ThemeMode.system: 'System', ThemeMode.light: 'Light', ThemeMode.dark: 'Dark'},
          onChanged: (v) => n.update((x) => x.copyWith(themeMode: v)),
        ),
      ),
      SectionLabel('Accent'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
        child: _AccentPicker(value: s.accent, onChanged: (v) => n.update((x) => x.copyWith(accent: v))),
      ),
      const SizedBox(height: Space.md),
      SwitchTile(
        icon: Icons.animation_rounded,
        title: 'Reduce motion',
        subtitle: 'Fewer animations and transitions',
        value: s.reduceMotion,
        onChanged: (v) => n.update((x) => x.copyWith(reduceMotion: v)),
      ),
      SectionLabel('Bottom bar'),
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
        subtitle: 'Show Wallet in the bottom bar. Settings can still open it.',
        value: s.showWalletTab,
        onChanged: (v) => n.update((x) => x.copyWith(showWalletTab: v)),
      ),
    ]);
  }
}

class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    const accents = {
      'emerald': Color(0xFF0E9F6E),
      'blue': Color(0xFF2563EB),
      'amber': Color(0xFFD97706),
      'ink': Color(0xFF0D1110),
    };
    return Row(
      children: [
        for (final a in accents.entries)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(a.key),
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: Motion.fast,
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: a.value,
                      shape: BoxShape.circle,
                      border: Border.all(color: value == a.key ? p.ink : Colors.transparent, width: 3),
                    ),
                    child: value == a.key ? const Icon(Icons.check_rounded, color: Colors.white, size: 20) : null,
                  ),
                  const SizedBox(height: 6),
                  Text('${a.key[0].toUpperCase()}${a.key.substring(1)}', style: Txt.small(value == a.key ? p.ink : p.muted)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class ChatSettings extends ConsumerWidget {
  const ChatSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return _Page(title: 'Chats', children: [
      SectionLabel('Signals'),
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
      SectionLabel('History'),
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
        subtitle: 'Explains when someone is offline and their messages are hidden',
        value: s.showOfflineHint,
        onChanged: (v) => n.update((x) => x.copyWith(showOfflineHint: v)),
      ),
      RowTile(
        icon: Icons.timer_outlined,
        title: 'Default disappearing timer',
        subtitle: ttlLabel(s.defaultTtl),
        onTap: () => _ttl(context, ref),
      ),
    ]);
  }
}

class PrivacySettings extends ConsumerWidget {
  const PrivacySettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return _Page(
      title: 'Privacy',
      intro: 'Nothing leaves this phone unless you share it. These decide who can find you and what others may hold for you.',
      children: [
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
          icon: Icons.visibility_off_outlined,
          title: 'Hide NSFW',
          subtitle: 'Blurred posts, stories and messages stay covered.',
          value: s.hideNsfw,
          onChanged: (v) => n.update((x) => x.copyWith(hideNsfw: v)),
        ),
        SectionLabel('What others may keep'),
        SwitchTile(
          icon: Icons.article_outlined,
          title: 'Followers may keep my posts',
          subtitle: 'Your posts stay visible while you\'re away, through followers who agree. Turning this off asks them to delete their copies.',
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
        RowTile(
          icon: Icons.inventory_2_outlined,
          title: 'See who holds what',
          onTap: () => context.push('/custody'),
        ),
        SectionLabel('People'),
        RowTile(icon: Icons.block_rounded, title: 'Blocked people', onTap: () => context.push('/people?tab=3')),
      ],
    );
  }
}

class SecuritySettings extends ConsumerWidget {
  const SecuritySettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return _Page(
      title: 'App lock',
      intro: 'A PIN on this app, stored as a slow salted hash. Your data is encrypted either way; this keeps someone holding your phone out of Mentos.',
      children: [
        SectionLabel('PIN'),
        RowTile(
          icon: Icons.pin_outlined,
          title: s.lockHash.isEmpty ? 'Set a PIN' : 'Change or turn off PIN',
          subtitle: s.lockHash.isEmpty ? 'Ask for a PIN after you leave' : 'App lock is on',
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
        SectionLabel('Identity'),
        RowTile(
          icon: Icons.key_rounded,
          title: 'Recovery phrase',
          subtitle: 'Write it down; it is the only way back',
          onTap: () => context.push('/backup'),
        ),
      ],
    );
  }
}

class StorageSettings extends ConsumerWidget {
  const StorageSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return _Page(title: 'Storage and files', children: [
      SectionLabel('Media'),
      SwitchTile(
        icon: Icons.download_rounded,
        title: 'Load media automatically',
        subtitle: 'Photos and videos download as they appear',
        value: s.autoDownload,
        onChanged: (v) => n.update((x) => x.copyWith(autoDownload: v)),
      ),
      RowTile(
        icon: Icons.sd_storage_outlined,
        title: 'File storage limit',
        subtitle: s.quotaMb >= 1024 ? '${s.quotaMb ~/ 1024} GB' : '${s.quotaMb} MB',
        onTap: () => _quota(context, ref),
      ),
      SectionLabel('Files'),
      RowTile(icon: Icons.folder_outlined, title: 'Hosted files', subtitle: 'Files this phone serves to others', onTap: () => context.push('/files')),
      RowTile(icon: Icons.swap_horiz_rounded, title: 'File transfers', subtitle: 'Send and receive directly', onTap: () => context.push('/transfer')),
      RowTile(icon: Icons.bookmark_outline_rounded, title: 'Bookmarks', onTap: () => context.push('/bookmarks')),
      SectionLabel('Everything stored'),
      RowTile(
        icon: Icons.data_object_rounded,
        title: 'Data explorer',
        subtitle: 'Browse, verify and export everything stored here',
        onTap: () => context.push('/data'),
      ),
      RowTile(
        icon: Icons.inventory_2_outlined,
        title: 'Who holds what',
        subtitle: 'Copies you keep for others, and who keeps yours',
        onTap: () => context.push('/custody'),
      ),
    ]);
  }
}

class NetworkSettings extends ConsumerWidget {
  const NetworkSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return _Page(title: 'Network', children: [
      SectionLabel('Connection'),
      SwitchTile(
        icon: Icons.wifi_tethering_rounded,
        title: 'Stay connected in the background',
        subtitle: 'Keep the node running when Mentos is not on screen',
        value: s.keepAlive,
        onChanged: (v) => n.update((x) => x.copyWith(keepAlive: v)),
      ),
      RowTile(
        icon: Icons.shield_outlined,
        title: 'Privacy and transports',
        subtitle: switch (s.privacy) {
          'relay' => 'Hide my IP',
          'tor' => 'Tor via ${s.proxyUrl}',
          _ => 'Standard',
        },
        onTap: () => context.push('/diagnostics?tab=privacy'),
      ),
      SectionLabel('Look inside'),
      RowTile(icon: Icons.monitor_heart_outlined, title: 'Network diagnostics', subtitle: 'Reachability, relays, connections', onTap: () => context.push('/diagnostics')),
      RowTile(icon: Icons.travel_explore_rounded, title: 'Network atlas', subtitle: 'Every node and relay heard on the network', onTap: () => context.push('/atlas')),
    ]);
  }
}

class MoneySettings extends ConsumerWidget {
  const MoneySettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final e = ref.watch(engineProvider);
    final hidden = ref.watch(walletHiddenProvider);
    final market = e.market;
    final payout = market?.payoutDetails() ?? '';
    return _Page(title: 'Wallet and market', children: [
      SectionLabel('Wallet'),
      SwitchTile(
        icon: Icons.visibility_off_outlined,
        title: 'Hide balance',
        subtitle: 'Show dots until you tap the balance',
        value: hidden,
        onChanged: (v) {
          if (v != hidden) ref.read(walletHiddenProvider.notifier).toggle();
        },
      ),
      SwitchTile(
        icon: Icons.space_dashboard_outlined,
        title: 'Wallet tab',
        subtitle: 'Show Wallet in the bottom bar',
        value: s.showWalletTab,
        onChanged: (v) => n.update((x) => x.copyWith(showWalletTab: v)),
      ),
      RowTile(
        icon: Icons.qr_code_rounded,
        title: 'Copy my address',
        subtitle: 'People pay this. It is your Mentos id.',
        onTap: () {
          Clipboard.setData(ClipboardData(text: e.me.id));
          toast(context, 'Address copied');
        },
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xs, Space.gutter, 0),
        child: Text('Balance ${hidden ? '••••' : Coin.format(e.coin?.balance() ?? 0)} Mentos', style: Txt.mono(p.muted, size: 11)),
      ),
      if (market != null) ...[
        SectionLabel('Ads'),
        SwitchTile(
          icon: Icons.campaign_outlined,
          title: 'See ads and earn',
          subtitle: 'Advertisers pay you Mentos for each ad you view. Matching happens on this phone.',
          value: market.adsEnabled,
          onChanged: (v) => market.setAds(on: v),
        ),
        RowTile(
          icon: Icons.interests_outlined,
          title: 'Interests',
          subtitle: market.adInterests.isEmpty ? 'None, ads are not targeted' : market.adInterests.join(', '),
          onTap: () async {
            final text = await prompt(
              context,
              title: 'Interests',
              body: 'Used only on this phone to pick which ads you see.',
              hint: 'food, music, phones',
              initial: market.adInterests.join(', '),
              action: 'Save',
              maxLength: 200,
            );
            if (text == null) return;
            market.setAds(interests: text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList());
          },
        ),
        SectionLabel('Exchange'),
        RowTile(
          icon: Icons.account_balance_outlined,
          title: 'Birr payout details',
          subtitle: payout.isEmpty ? 'Not set. Buyers see this privately when they trade with you.' : payout.split('\n').first,
          onTap: () async {
            final text = await prompt(
              context,
              title: 'Birr payout details',
              body: 'Shared privately with a buyer only after they lock Mentos in escrow. For example: telebirr number, or bank and account.',
              initial: payout,
              action: 'Save',
              maxLength: 300,
              multiline: true,
              minLines: 3,
            );
            if (text != null) market.setPayoutDetails(text);
          },
        ),
      ],
    ]);
  }
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
