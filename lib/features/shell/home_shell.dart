import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../state/settings.dart';

/// One bottom-bar destination. [branch] is the shell index, which stays put
/// when Feed or Wallet is hidden.
class ShellTab {
  const ShellTab({required this.label, required this.branch, this.badge = 0, this.live = false});
  final String label;
  final int branch;
  final int badge;
  final bool live;
}

/// Tabs currently shown in the bottom bar, in bar order.
List<ShellTab> shellTabs(Settings settings, {required int unread, required int peers}) {
  return [
    if (settings.showFeedTab) const ShellTab(label: 'Feed', branch: 0),
    if (settings.showWalletTab) const ShellTab(label: 'Wallet', branch: 1),
    ShellTab(label: 'Spaces', branch: 2, badge: unread),
    ShellTab(label: 'Network', branch: 3, live: peers > 0),
    const ShellTab(label: 'You', branch: 4),
  ];
}

/// Where the app opens, and where to go when the current tab is turned off.
int landingBranch(Settings settings) {
  if (settings.showFeedTab) return 0;
  if (settings.showWalletTab) return 1;
  return 2;
}

/// Route for [landingBranch].
String landingPath(Settings settings) => switch (landingBranch(settings)) {
      0 => '/feed',
      1 => '/wallet',
      _ => '/chats',
    };

(IconData, IconData) _tabIcons(int branch) => switch (branch) {
      0 => (Icons.view_agenda_outlined, Icons.view_agenda_rounded),
      1 => (Icons.account_balance_wallet_outlined, Icons.account_balance_wallet_rounded),
      2 => (Icons.forum_outlined, Icons.forum_rounded),
      3 => (Icons.hub_outlined, Icons.hub_rounded),
      _ => (Icons.person_outline_rounded, Icons.person_rounded),
    };

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (session is! SessionReady) {
      return const Scaffold(body: SizedBox.shrink());
    }
    final p = context.pal;
    final settings = ref.watch(settingsProvider);
    final unread = ref.watch(unreadChatsProvider).value ?? 0;
    final net = ref.watch(netStatusProvider).value;
    final peers = net?.links.length ?? 0;
    final tabs = shellTabs(settings, unread: unread, peers: peers);

    ref.listen(settingsProvider, (prev, next) {
      if (prev == null) return;
      final branch = shell.currentIndex;
      final turnedOff = (branch == 0 && prev.showFeedTab && !next.showFeedTab) ||
          (branch == 1 && prev.showWalletTab && !next.showWalletTab);
      if (!turnedOff) return;
      final dest = landingBranch(next);
      WidgetsBinding.instance.addPostFrameCallback((_) => shell.goBranch(dest));
    });

    return Scaffold(
      body: shell,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(color: p.bg, border: Border(top: BorderSide(color: p.line))),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 60,
            child: Row(
              children: [
                for (final tab in tabs)
                  Expanded(
                    child: _NavItem(
                      icon: _tabIcons(tab.branch).$1,
                      activeIcon: _tabIcons(tab.branch).$2,
                      label: tab.label,
                      badge: tab.badge,
                      active: shell.currentIndex == tab.branch,
                      live: tab.live,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        shell.goBranch(tab.branch, initialLocation: tab.branch == shell.currentIndex);
                      },
                      onLongPress: tab.branch == 4 ? () => _accounts(context, ref) : null,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _accounts(BuildContext context, WidgetRef ref) async {
  final session = ref.read(sessionProvider.notifier);
  final data = await session.accounts();
  if (!context.mounted) return;
  final picked = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('Accounts on this device')),
          for (final a in data.accounts)
            ListTile(
              title: Text(a.name.isEmpty ? 'Account' : a.name),
              trailing: a.dir == data.active ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(ctx, a.dir),
            ),
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const Text('Add account'),
            onTap: () => Navigator.pop(ctx, 'add'),
          ),
        ],
      ),
    ),
  );
  if (picked == null) return;
  if (picked == 'add') {
    await session.addAccount();
  } else if (picked != data.active) {
    await session.switchAccount(picked);
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge = 0,
    this.live = false,
    this.onLongPress,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final int badge;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedSwitcher(
                duration: Motion.fast,
                child: Icon(active ? activeIcon : icon,
                    key: ValueKey(active), size: 23, color: active ? p.ink : p.faint),
              ),
              if (badge > 0)
                Positioned(
                  right: -8,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: p.accent,
                      borderRadius: BorderRadius.circular(Radii.pill),
                      border: Border.all(color: p.bg, width: 1.5),
                    ),
                    child: Text(badge > 9 ? '9+' : '$badge',
                        style: Txt.mono(p.accentInk, size: 9.5, w: FontWeight.w500)),
                  ),
                ),
              if (live)
                Positioned(
                  right: -2,
                  top: -1,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: p.accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: p.bg, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(label,
              style: Txt.mono(active ? p.ink : p.faint, size: 10, w: active ? FontWeight.w500 : FontWeight.w400)),
        ],
      ),
    );
  }
}
