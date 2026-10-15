import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/notifications.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  static String _time(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final s = ref.watch(settingsProvider);
    final n = s.notify;
    final notifier = ref.read(settingsProvider.notifier);
    void set(NotifyPrefs Function(NotifyPrefs) f) => notifier.update((x) => x.copyWith(notify: f(x.notify)));
    final on = s.systemNotify;

    Future<void> pickQuiet() async {
      final from = await showTimePicker(
        context: context,
        helpText: 'Quiet from',
        initialTime: TimeOfDay(hour: n.hasQuietHours ? n.quietFrom ~/ 60 : 22, minute: n.hasQuietHours ? n.quietFrom % 60 : 0),
      );
      if (from == null || !context.mounted) return;
      final to = await showTimePicker(
        context: context,
        helpText: 'Quiet until',
        initialTime: TimeOfDay(hour: n.hasQuietHours ? n.quietTo ~/ 60 : 7, minute: n.hasQuietHours ? n.quietTo % 60 : 0),
      );
      if (to == null) return;
      set((x) => x.copyWith(quietFrom: from.hour * 60 + from.minute, quietTo: to.hour * 60 + to.minute));
    }

    Widget cat(IconData icon, String title, String subtitle, bool value, NotifyPrefs Function(bool) change) => SwitchTile(
          icon: icon,
          title: title,
          subtitle: subtitle,
          value: on && value,
          onChanged: on ? (v) => set((_) => change(v)) : null,
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          SwitchTile(
            icon: Icons.notifications_active_outlined,
            title: 'Allow notifications',
            subtitle: 'Shown by your phone while Mentos is running in the background. Nothing goes through a server.',
            value: on,
            onChanged: (v) async {
              notifier.update((x) => x.copyWith(systemNotify: v));
              if (v) {
                final ok = await ref.read(notificationServiceProvider)?.requestPermission() ?? true;
                if (!ok && context.mounted) toast(context, 'Notifications are blocked in system settings');
              }
            },
          ),
          SwitchTile(
            icon: Icons.visibility_outlined,
            title: 'Show names and text',
            subtitle: 'Off shows only "New message" and hides it on the lock screen.',
            value: on && n.preview,
            onChanged: on ? (v) => set((x) => x.copyWith(preview: v)) : null,
          ),
          RowTile(
            icon: Icons.bedtime_outlined,
            title: 'Quiet hours',
            subtitle: n.hasQuietHours ? '${_time(n.quietFrom)} – ${_time(n.quietTo)}' : 'Off',
            onTap: on ? pickQuiet : null,
            trailing: n.hasQuietHours
                ? TextButton(onPressed: () => set((x) => x.copyWith(quietFrom: -1, quietTo: -1)), child: const Text('Off'))
                : null,
          ),
          SectionLabel('Chats'),
          cat(Icons.chat_bubble_outline_rounded, 'Direct messages', 'One-to-one chats', n.dms, (v) => n.copyWith(dms: v)),
          cat(Icons.groups_outlined, 'Group messages', 'Muted groups stay quiet', n.groups, (v) => n.copyWith(groups: v)),
          cat(Icons.alternate_email_rounded, 'Mentions', 'When someone writes @you, even in a muted group', n.mentions, (v) => n.copyWith(mentions: v)),
          SectionLabel('Social'),
          cat(Icons.mode_comment_outlined, 'Replies', 'Comments on your posts', n.replies, (v) => n.copyWith(replies: v)),
          cat(Icons.favorite_border_rounded, 'Likes', 'Can be a lot', n.likes, (v) => n.copyWith(likes: v)),
          cat(Icons.person_add_alt_outlined, 'New followers', 'When someone follows you', n.follows, (v) => n.copyWith(follows: v)),
          cat(Icons.amp_stories_outlined, 'Stories', 'From people you follow', n.stories, (v) => n.copyWith(stories: v)),
          cat(Icons.campaign_outlined, 'Channels', 'New posts in channels you follow', n.channels, (v) => n.copyWith(channels: v)),
          SectionLabel('Network'),
          cat(Icons.mail_outline_rounded, 'Invitations', 'Groups, and requests to keep a copy of a chat', n.invites, (v) => n.copyWith(invites: v)),
          cat(Icons.swap_vert_rounded, 'File transfers', 'Someone wants to send you a file', n.transfers, (v) => n.copyWith(transfers: v)),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
            child: Text(
              'Mentos has no push server, so notifications only arrive while the app is alive in the background '
              'and the sender is reachable. If your phone closes the app, messages wait on the sender\'s device '
              'and arrive when you both are online.',
              style: Txt.small(p.muted),
            ),
          ),
        ],
      ),
    );
  }
}
