import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/activity/activity_screen.dart';
import '../features/bookmarks/bookmarks_screen.dart';
import '../features/chats/chat_screen.dart';
import '../features/chats/chats_screen.dart';
import '../features/connect/connect_screen.dart';
import '../features/feed/compose_screen.dart';
import '../features/feed/feed_screen.dart';
import '../features/feed/post_screen.dart';
import '../features/feed/stories.dart';
import '../features/chats/group_info_screen.dart';
import '../features/chats/group_screen.dart';
import '../features/chats/new_group_screen.dart';
import '../features/files/files_screen.dart';
import '../features/files/transfer_screen.dart';
import '../features/network/network_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/profile/edit_profile_screen.dart';
import '../features/profile/insights_screen.dart';
import '../features/profile/people_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/settings/backup_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/home_shell.dart';
import '../features/spaces/broadcast_screen.dart';
import '../features/spaces/create_space_screen.dart';
import '../features/spaces/forum_screen.dart';
import '../features/spaces/space_screen.dart';
import '../features/spaces/space_settings_screen.dart';
import '../features/spaces/spaces_screen.dart';
import '../state/session.dart';

class _SessionListenable extends ChangeNotifier {
  _SessionListenable(Ref ref) {
    ref.listen(sessionProvider, (_, _) => notifyListeners());
  }
}

final _rootKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _SessionListenable(ref);
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/feed',
    refreshListenable: listenable,
    redirect: (context, state) {
      final s = ref.read(sessionProvider);
      final loc = state.matchedLocation;
      final atOnboarding = loc == '/onboarding';
      final atBoot = loc == '/boot';
      if (s is SessionLoading || s is SessionError) return atBoot ? null : '/boot';
      if (s is SessionSignedOut) return atOnboarding ? null : '/onboarding';
      if (s is SessionReady && (atOnboarding || atBoot)) return '/feed';
      return null;
    },
    routes: [
      GoRoute(path: '/boot', builder: (_, _) => const SizedBox.shrink()),
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => HomeShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/feed', builder: (_, _) => const FeedScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/spaces', builder: (_, _) => const SpacesScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/chats', builder: (_, _) => const ChatsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/network', builder: (_, _) => const NetworkScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/me', builder: (_, _) => const MyProfileScreen())]),
        ],
      ),
      GoRoute(
        path: '/compose',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, s) => MaterialPage(
          fullscreenDialog: true,
          child: ComposeScreen(
            spaceId: s.uri.queryParameters['space'],
            boardId: s.uri.queryParameters['board'],
            channelId: s.uri.queryParameters['channel'],
            bcastId: s.uri.queryParameters['bcast'],
            repostId: s.uri.queryParameters['repost'],
          ),
        ),
      ),
      GoRoute(path: '/post/:id', builder: (_, s) => PostScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/chat/:peer', builder: (_, s) => ChatScreen(peer: s.pathParameters['peer']!)),
      GoRoute(path: '/g/:id', builder: (_, s) => GroupChatScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/g/:id/info', builder: (_, s) => GroupInfoScreen(id: s.pathParameters['id']!)),
      GoRoute(
        path: '/ch/:owner/:id',
        builder: (_, s) => BroadcastScreen(owner: s.pathParameters['owner']!, channelId: s.pathParameters['id']!),
      ),
      GoRoute(path: '/insights', builder: (_, _) => const InsightsScreen()),
      GoRoute(path: '/new-group', builder: (_, _) => const NewGroupScreen()),
      GoRoute(path: '/transfer', builder: (_, _) => const TransfersScreen()),
      GoRoute(path: '/transfer/:peer', builder: (_, s) => PeerTransferScreen(peer: s.pathParameters['peer']!)),
      GoRoute(path: '/u/:id', builder: (_, s) => ProfileScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/edit-profile', builder: (_, _) => const EditProfileScreen()),
      GoRoute(
        path: '/people',
        builder: (_, s) => PeopleScreen(initialTab: int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0),
      ),
      GoRoute(path: '/new-space', builder: (_, _) => const CreateSpaceScreen()),
      GoRoute(path: '/s/:id', builder: (_, s) => SpaceScreen(id: s.pathParameters['id']!)),
      GoRoute(
        path: '/s/:id/c/:cid',
        builder: (_, s) => BroadcastScreen(
          owner: s.pathParameters['id']!,
          channelId: s.pathParameters['cid']!,
          spaceId: s.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/s/:id/f/:fid',
        builder: (_, s) => ForumScreen(
          spaceId: s.pathParameters['id']!,
          boardId: s.pathParameters['fid']!,
          legacyChannel: s.uri.queryParameters['chan'] == '1',
        ),
      ),
      GoRoute(path: '/s/:id/settings', builder: (_, s) => SpaceSettingsScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/connect', builder: (_, s) => ConnectScreen(scan: s.uri.queryParameters['scan'] == '1')),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      GoRoute(path: '/backup', builder: (_, _) => const BackupScreen()),
      GoRoute(path: '/files', builder: (_, _) => const FilesScreen()),
      GoRoute(path: '/bookmarks', builder: (_, _) => const BookmarksScreen()),
      GoRoute(path: '/activity', builder: (_, _) => const ActivityScreen()),
      GoRoute(
        path: '/story/new',
        pageBuilder: (_, _) => const MaterialPage(fullscreenDialog: true, child: StoryComposer()),
      ),
      GoRoute(
        path: '/story/:author',
        pageBuilder: (_, s) => CustomTransitionPage(
          child: StoryViewer(author: s.pathParameters['author']!),
          transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
        ),
      ),
    ],
  );
});
