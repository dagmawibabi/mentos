import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/activity/activity_screen.dart';
import '../features/bookmarks/bookmarks_screen.dart';
import '../features/calls/call_screen.dart';
import '../features/calls/live_screen.dart';
import '../features/chats/chat_screen.dart';
import '../features/data/data_explorer_screen.dart';
import '../features/chats/chats_screen.dart';
import '../features/connect/connect_screen.dart';
import '../features/feed/compose_screen.dart';
import '../features/feed/drafts_screen.dart';
import '../features/feed/feed_screen.dart';
import '../features/feed/post_screen.dart';
import '../features/feed/stories.dart';
import '../features/chats/group_info_screen.dart';
import '../features/chats/group_screen.dart';
import '../features/chats/new_group_screen.dart';
import '../features/files/files_screen.dart';
import '../features/files/transfer_screen.dart';
import '../features/network/atlas_screen.dart';
import '../features/plugins/plugins_screen.dart';
import '../features/market/box_screen.dart';
import '../features/ai/ai_chat_screen.dart';
import '../features/network/custody_screen.dart';
import '../features/network/diagnostics_screen.dart';
import '../features/network/network_screen.dart';
import '../features/network/node_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/profile/edit_profile_screen.dart';
import '../features/profile/insights_screen.dart';
import '../features/profile/people_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/settings/accounts_screen.dart';
import '../features/settings/help_screen.dart';
import '../features/settings/backup_screen.dart';
import '../features/settings/notifications_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/home_shell.dart';
import '../state/providers.dart';
import '../features/spaces/broadcast_screen.dart';
import '../features/spaces/channels_screen.dart';
import '../features/market/cart_screen.dart';
import '../features/feed/tag_screen.dart';
import '../features/spaces/discover_screen.dart';
import '../features/market/deal_screens.dart';
import '../features/market/device_check_screen.dart';
import '../features/market/hub_screen.dart';
import '../features/market/listing_screen.dart';
import '../features/market/market_screen.dart';
import '../features/market/sell_screen.dart';
import '../features/settings/dev_screen.dart';
import '../features/spaces/spaces_screen.dart';
import '../features/wallet/coin_wallet_screen.dart';
import '../features/wallet/send_screen.dart';
import '../features/spaces/create_space_screen.dart';
import '../features/spaces/forum_screen.dart';
import '../features/spaces/space_screen.dart';
import '../features/spaces/space_settings_screen.dart';
import '../state/session.dart';

class _SessionListenable extends ChangeNotifier {
  _SessionListenable(Ref ref) {
    ref.listen(sessionProvider, (_, _) => notifyListeners());
  }
}

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root navigator');

final _branchKeys = List<GlobalKey<NavigatorState>>.generate(
  5,
  (i) => GlobalKey<NavigatorState>(debugLabel: 'shell branch $i'),
);

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _SessionListenable(ref);
  final router = GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/feed',
    refreshListenable: listenable,
    redirect: (context, state) {
      final s = ref.read(sessionProvider);
      final loc = state.matchedLocation;
      final atOnboarding = loc == '/onboarding';
      final atBoot = loc == '/boot';
      if (s is SessionLoading || s is SessionError)
        return atBoot ? null : '/boot';
      if (s is SessionSignedOut) return atOnboarding ? null : '/onboarding';
      if (s is SessionReady && (atOnboarding || atBoot))
        return landingPath(ref.read(settingsProvider));
      final path = state.uri.path;
      if (path == '/credit' || path.startsWith('/wallet/')) return '/wallet';
      if (path == '/spaces') return '/communities';
      return null;
    },
    routes: [
      GoRoute(path: '/boot', builder: (_, _) => const SizedBox.shrink()),
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      StatefulShellRoute.indexedStack(
        pageBuilder: (_, _, shell) => MaterialPage(
          key: const ValueKey<String>('mentos-shell'),
          child: HomeShell(shell: shell),
        ),
        branches: [
          for (final (i, route) in [
            GoRoute(path: '/feed', builder: (_, _) => const FeedScreen()),
            GoRoute(
              path: '/wallet',
              builder: (_, _) => const CoinWalletScreen(),
            ),
            GoRoute(path: '/chats', builder: (_, _) => const ChatsScreen()),
            GoRoute(path: '/network', builder: (_, _) => const NetworkScreen()),
            GoRoute(path: '/me', builder: (_, _) => const MyProfileScreen()),
          ].indexed)
            StatefulShellBranch(navigatorKey: _branchKeys[i], routes: [route]),
        ],
      ),
      GoRoute(
        path: '/send',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, s) => MaterialPage(
          key: s.pageKey,
          child: SendMentosScreen(to: s.uri.queryParameters['to']),
        ),
      ),
      GoRoute(
        path: '/compose',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, s) => MaterialPage(
          key: s.pageKey,
          fullscreenDialog: true,
          child: ComposeScreen(
            spaceId: s.uri.queryParameters['space'],
            boardId: s.uri.queryParameters['board'],
            channelId: s.uri.queryParameters['channel'],
            bcastId: s.uri.queryParameters['bcast'],
            repostId: s.uri.queryParameters['repost'],
            draftId: s.uri.queryParameters['draft'],
            scheduledId: s.uri.queryParameters['scheduled'],
          ),
        ),
      ),
      GoRoute(
        path: '/post/:id',
        builder: (_, s) => PostScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/chat/:peer',
        builder: (_, s) => ChatScreen(peer: s.pathParameters['peer']!),
      ),
      GoRoute(
        path: '/g/:id',
        builder: (_, s) => GroupChatScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/g/:id/info',
        builder: (_, s) => GroupInfoScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/ch/:owner/:id',
        builder: (_, s) => BroadcastScreen(
          owner: s.pathParameters['owner']!,
          channelId: s.pathParameters['id']!,
        ),
      ),
      GoRoute(path: '/insights', builder: (_, _) => const InsightsScreen()),
      GoRoute(path: '/new-group', builder: (_, _) => const NewGroupScreen()),
      GoRoute(path: '/transfer', builder: (_, _) => const TransfersScreen()),
      GoRoute(
        path: '/transfer/:peer',
        builder: (_, s) => PeerTransferScreen(peer: s.pathParameters['peer']!),
      ),
      GoRoute(
        path: '/u/:id',
        builder: (_, s) => ProfileScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/edit-profile',
        builder: (_, _) => const EditProfileScreen(),
      ),
      GoRoute(
        path: '/people',
        builder: (_, s) => PeopleScreen(
          initialTab: int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0,
        ),
      ),
      GoRoute(path: '/new-space', builder: (_, _) => const CreateSpaceScreen()),
      GoRoute(
        path: '/s/:id',
        builder: (_, s) => SpaceScreen(id: s.pathParameters['id']!),
      ),
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
      GoRoute(
        path: '/s/:id/settings',
        builder: (_, s) => SpaceSettingsScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/connect',
        builder: (_, s) =>
            ConnectScreen(scan: s.uri.queryParameters['scan'] == '1'),
      ),
      GoRoute(
        path: '/call',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, s) => MaterialPage(
          key: s.pageKey,
          fullscreenDialog: true,
          child: const CallScreen(),
        ),
      ),
      GoRoute(
        path: '/live',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, s) => MaterialPage(
          key: s.pageKey,
          fullscreenDialog: true,
          child: const LiveScreen(),
        ),
      ),
      GoRoute(path: '/communities', builder: (_, _) => const SpacesScreen()),
      GoRoute(path: '/communities/discover', builder: (_, _) => const DiscoverSpacesScreen()),
      GoRoute(
        path: '/market',
        builder: (_, s) => MarketScreen(
          initial: MarketTab.values.where((t) => t.name == s.uri.queryParameters['tab']).firstOrNull ?? MarketTab.plugins,
        ),
      ),
      GoRoute(path: '/market/l/:id', builder: (_, s) => ListingScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/market/cart', builder: (_, s) => CartScreen(seller: s.uri.queryParameters['seller'])),
      GoRoute(path: '/market/hub', builder: (_, s) => MarketHubScreen(tab: s.uri.queryParameters['tab'])),
      GoRoute(path: '/market/diagnostics', builder: (_, _) => const DeviceCheckScreen()),
      GoRoute(
        path: '/market/sell/:kind',
        builder: (_, s) => SellScreen(kind: s.pathParameters['kind']!, id: s.uri.queryParameters['id']),
      ),
      GoRoute(
        path: '/market/r/:kind/:id',
        builder: (_, s) => DealScreen(kind: s.pathParameters['kind']!, id: s.pathParameters['id']!),
      ),
      GoRoute(path: '/market/box/:bid', builder: (_, s) => BoxScreen(bid: s.pathParameters['bid']!)),
      GoRoute(path: '/market/task/:id', redirect: (_, s) => '/market/r/task/${s.pathParameters['id']}'),
      GoRoute(path: '/dev', builder: (_, _) => const DevScreen()),
      GoRoute(path: '/ai', builder: (_, s) => AiChatScreen(conversation: s.uri.queryParameters['c'])),
      GoRoute(path: '/plugins', builder: (_, _) => const PluginsScreen()),
      GoRoute(path: '/plugins/:id', builder: (_, s) => PluginDetailScreen(id: s.pathParameters['id']!)),
      GoRoute(
        path: '/plugins/:id/page/:page',
        builder: (_, s) => PluginPageScreen(plugin: s.pathParameters['id']!, page: s.pathParameters['page']!),
      ),
      GoRoute(path: '/calls', builder: (_, _) => const CallLogScreen()),
      GoRoute(path: '/accounts', builder: (_, _) => const AccountsScreen()),
      GoRoute(path: '/channels', builder: (_, _) => const ChannelsScreen()),
      GoRoute(
        path: '/notifications',
        builder: (_, _) => const NotificationsScreen(),
      ),
      GoRoute(path: '/data', builder: (_, _) => const DataExplorerScreen()),
      GoRoute(
        path: '/diagnostics',
        builder: (_, s) => DiagnosticsScreen(tab: s.uri.queryParameters['tab']),
      ),
      GoRoute(path: '/privacy', redirect: (_, _) => '/diagnostics?tab=privacy'),
      GoRoute(path: '/atlas', builder: (_, _) => const AtlasScreen()),
      GoRoute(path: '/custody', builder: (_, _) => const CustodyScreen()),
      GoRoute(
        path: '/node/:id',
        builder: (_, s) => NodeScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      GoRoute(path: '/help', builder: (_, _) => const HelpScreen()),
      GoRoute(path: '/backup', builder: (_, _) => const BackupScreen()),
      GoRoute(path: '/files', builder: (_, _) => const FilesScreen()),
      GoRoute(path: '/bookmarks', builder: (_, _) => const BookmarksScreen()),
      GoRoute(path: '/tag/:tag', builder: (_, s) => TagScreen(tag: s.pathParameters['tag']!)),
      GoRoute(path: '/activity', builder: (_, _) => const ActivityScreen()),
      GoRoute(path: '/drafts', builder: (_, _) => const DraftsScreen()),
      GoRoute(
        path: '/story/new',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, s) => MaterialPage(
          key: s.pageKey,
          fullscreenDialog: true,
          child: const StoryComposer(),
        ),
      ),
      GoRoute(
        path: '/story/:author',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, s) => CustomTransitionPage(
          key: s.pageKey,
          child: StoryViewer(author: s.pathParameters['author']!),
          transitionsBuilder: (_, a, _, child) =>
              FadeTransition(opacity: a, child: child),
        ),
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    listenable.dispose();
  });
  return router;
});
