import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../state/session.dart';

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
    final unread = ref.watch(unreadChatsProvider).value ?? 0;
    final net = ref.watch(netStatusProvider).value;
    final peers = net?.links.length ?? 0;

    final items = [
      (Icons.view_agenda_outlined, Icons.view_agenda_rounded, 'Feed', 0),
      (Icons.grid_view_outlined, Icons.grid_view_rounded, 'Spaces', 0),
      (Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, 'Chats', unread),
      (Icons.hub_outlined, Icons.hub_rounded, 'Network', 0),
      (Icons.person_outline_rounded, Icons.person_rounded, 'You', 0),
    ];

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
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _NavItem(
                      icon: items[i].$1,
                      activeIcon: items[i].$2,
                      label: items[i].$3,
                      badge: items[i].$4,
                      active: shell.currentIndex == i,
                      live: i == 3 && peers > 0,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        shell.goBranch(i, initialLocation: i == shell.currentIndex);
                      },
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

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge = 0,
    this.live = false,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final int badge;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
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
