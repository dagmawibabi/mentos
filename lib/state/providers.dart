import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../net/diagnostics.dart';
import '../net/engine.dart';
import '../net/engine_net.dart';
import '../net/transport.dart';
import '../net/views.dart';
import 'session.dart';
import 'settings.dart';

Engine? _eng(Ref ref) {
  final s = ref.watch(sessionProvider);
  return s is SessionReady ? s.engine : null;
}

/// Null until the local node is open. Prefer this in widgets that can
/// appear while the splash is still on screen.
final maybeEngineProvider = Provider<Engine?>((ref) => _eng(ref));

final engineProvider = Provider<Engine>((ref) {
  final e = ref.watch(maybeEngineProvider);
  if (e == null) throw StateError('Engine not ready');
  return e;
});

class SettingsNotifier extends Notifier<Settings> {
  @override
  Settings build() {
    final s = ref.watch(sessionProvider);
    return s is SessionReady ? s.engine.settings : const Settings();
  }

  void update(Settings Function(Settings) change) {
    final next = change(state);
    state = next;
    final s = ref.read(sessionProvider);
    if (s is SessionReady) s.engine.updateSettings(next);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(
  SettingsNotifier.new,
);

/// Which list the Chats tab is showing.
enum InboxPane { chats, groups, channels }

class InboxPaneNotifier extends Notifier<InboxPane> {
  @override
  InboxPane build() => InboxPane.chats;

  void show(InboxPane pane) => state = pane;
}

final inboxPaneProvider = NotifierProvider<InboxPaneNotifier, InboxPane>(
  InboxPaneNotifier.new,
);

final themeModeProvider = Provider<ThemeMode>(
  (ref) => ref.watch(settingsProvider).themeMode,
);

bool _any(Set<String> keys, Iterable<String> wanted) =>
    wanted.any(keys.contains);

Stream<T> _ready<T>(Ref ref, T empty, Stream<T> Function(Engine e) run) {
  final e = _eng(ref);
  if (e == null) return Stream.value(empty);
  try {
    return run(e);
  } catch (_) {
    return Stream.value(empty);
  }
}

final feedProvider = StreamProvider.autoDispose<List<PostView>>((ref) {
  return _ready(
    ref,
    const <PostView>[],
    (e) => e.watch(
      (k) =>
          _any(k, [Ch.feed, Ch.peers, Ch.bookmarks]) ||
          k.any((x) => x.startsWith('item:')),
      e.feed,
    ),
  );
});

final heldPostsProvider =
    StreamProvider.autoDispose<
      ({List<HeldPost> scheduled, List<HeldPost> drafts})
    >((ref) {
      return _ready(
        ref,
        (scheduled: const <HeldPost>[], drafts: const <HeldPost>[]),
        (e) => e.watch(
          (k) => k.contains(Ch.queue),
          () => (scheduled: e.scheduledPosts(), drafts: e.postDrafts()),
        ),
      );
    });

final authorFeedProvider = StreamProvider.autoDispose
    .family<List<PostView>, String>((ref, author) {
      return _ready(
        ref,
        const <PostView>[],
        (e) => e.watch(
          (k) => _any(k, [Ch.feed, Scope.feed(author), Ch.bookmarks, Ch.peers]),
          () => e.feed(author: author),
        ),
      );
    });

final spaceFeedProvider = StreamProvider.autoDispose
    .family<List<PostView>, String>((ref, spaceId) {
      return _ready(
        ref,
        const <PostView>[],
        (e) => e.watch(
          (k) => _any(k, [Ch.feed, Scope.spaceFeed(spaceId), Ch.bookmarks]),
          () => e.feed(spaceId: spaceId),
        ),
      );
    });

final forumFeedProvider = StreamProvider.autoDispose
    .family<List<PostView>, (String, String)>((ref, ids) {
      return _ready(
        ref,
        const <PostView>[],
        (e) => e.watch(
          (k) =>
              _any(k, [Ch.feed, Scope.forum(ids.$1, ids.$2), Ch.bookmarks]) ||
              k.any((x) => x.startsWith('forum:')),
          () => e.feed(spaceId: ids.$1, boardId: ids.$2),
        ),
      );
    });

final hostedProvider = StreamProvider.autoDispose.family<List<Item>, String>((
  ref,
  author,
) {
  return _ready(
    ref,
    const <Item>[],
    (e) => e.watch(
      (k) => _any(k, [Ch.files, Scope.files(author), Ch.peers]),
      () => e.hosted(author),
    ),
  );
});

final transfersProvider = StreamProvider.autoDispose<List<FileTransfer>>((ref) {
  return _ready(
    ref,
    const <FileTransfer>[],
    (e) => e.watch((k) => k.contains(Ch.xfers), e.transfers),
  );
});

final bookmarksProvider = StreamProvider.autoDispose<List<PostView>>((ref) {
  return _ready(
    ref,
    const <PostView>[],
    (e) => e.watch((k) => _any(k, [Ch.feed, Ch.bookmarks]), e.bookmarked),
  );
});

final postProvider = StreamProvider.autoDispose.family<PostView?, String>((
  ref,
  id,
) {
  return _ready(
    ref,
    null,
    (e) => e.watch(
      (k) =>
          _any(k, [Ch.feed, 'item:$id', Ch.bookmarks]) ||
          k.any((x) => x.startsWith('post:')),
      () => e.post(id),
    ),
  );
});

final commentsProvider = StreamProvider.autoDispose
    .family<List<CommentView>, String>((ref, postId) {
      return _ready(
        ref,
        const <CommentView>[],
        (e) => e.watch(
          (k) =>
              k.any((x) => x.startsWith('post:') || x.startsWith('item:')) ||
              k.contains(Ch.peers),
          () {
            final p = e.post(postId);
            return p == null ? const <CommentView>[] : e.comments(p);
          },
        ),
      );
    });

final storiesProvider = StreamProvider.autoDispose<List<StoryGroup>>((ref) {
  return _ready(
    ref,
    const <StoryGroup>[],
    (e) => e.watch(
      (k) => _any(k, [Ch.stories, Ch.peers, Ch.presence, Ch.net]),
      e.stories,
    ),
  );
});

final chatsProvider = StreamProvider.autoDispose<List<ChatSummary>>((ref) {
  return _ready(
    ref,
    const <ChatSummary>[],
    (e) => e.watch(
      (k) =>
          _any(k, [Ch.chats, Ch.presence, Ch.peers, Ch.grants, Ch.groups]) ||
          k.any((x) => x.startsWith('dm:') || x.startsWith('gdm:')),
      e.chats,
    ),
  );
});

final unreadChatsProvider = StreamProvider.autoDispose<int>((ref) {
  return _ready(
    ref,
    0,
    (e) => e.watch(
      (k) => k.contains(Ch.chats) || k.any((x) => x.startsWith('dm:')),
      e.unreadChats,
    ),
  );
});

final chatWallpaperProvider = StreamProvider.autoDispose
    .family<String, String>((ref, scope) {
      String defaultW;
      try {
        defaultW = ref.watch(settingsProvider).chatWallpaper ?? 'default';
      } catch (_) {
        defaultW = 'default';
      }
      if (defaultW.isEmpty) defaultW = 'default';
      if (scope.isEmpty) return Stream.value(defaultW);
      return _ready(
        ref,
        defaultW,
        (e) => e.watch(
          (k) => _any(k, [scope, Ch.chats]),
          () {
            try {
              final w = e.chatWallpaper(scope);
              return w.isNotEmpty ? w : defaultW;
            } catch (_) {
              return defaultW;
            }
          },
        ),
      );
    });

final messagesProvider = StreamProvider.autoDispose
    .family<List<MessageView>, String>((ref, scope) {
      return _ready(
        ref,
        const <MessageView>[],
        (e) => e.watch(
          (k) => _any(k, [scope, Ch.receipts(scope), Ch.presence]),
          () => e.messages(scope),
        ),
      );
    });

final typingProvider = StreamProvider.autoDispose.family<Set<String>, String>((
  ref,
  scope,
) {
  return _ready(
    ref,
    const <String>{},
    (e) =>
        e.watch((k) => k.contains(Ch.typing(scope)), () => e.typingIn(scope)),
  );
});

final syncStateProvider = StreamProvider.autoDispose.family<SyncState, String>((
  ref,
  scope,
) {
  return _ready(
    ref,
    const SyncState(mine: null, theirs: null, theirsOffered: false),
    (e) =>
        e.watch((k) => _any(k, [Ch.grants, scope]), () => e.syncState(scope)),
  );
});

final peerProvider = StreamProvider.autoDispose.family<Peer, String>((ref, id) {
  return _ready(
    ref,
    Peer(id: id),
    (e) => e.watch((k) => _any(k, [Ch.peers, Ch.presence]), () => e.peerOf(id)),
  );
});

final onlineProvider = StreamProvider.autoDispose.family<bool, String>((
  ref,
  id,
) {
  return _ready(
    ref,
    false,
    (e) => e.watch((k) => k.contains(Ch.presence), () => e.isOnline(id)),
  );
});

final peopleProvider = StreamProvider.autoDispose<List<Peer>>((ref) {
  return _ready(
    ref,
    const <Peer>[],
    (e) => e.watch((k) => _any(k, [Ch.peers, Ch.presence]), e.people),
  );
});

final myProfileProvider = StreamProvider.autoDispose<Profile>((ref) {
  return _ready(
    ref,
    const Profile(id: ''),
    (e) => e.watch((k) => k.contains(Ch.peers), () => e.myProfile),
  );
});

final spacesProvider = StreamProvider.autoDispose<List<SpaceInfo>>((ref) {
  return _ready(
    ref,
    const <SpaceInfo>[],
    (e) => e.watch((k) => k.contains(Ch.spaces), e.spaces),
  );
});

final spaceProvider = StreamProvider.autoDispose.family<SpaceInfo?, String>((
  ref,
  id,
) {
  return _ready(
    ref,
    null,
    (e) => e.watch((k) => k.contains(Ch.spaces), () => e.space(id)),
  );
});

final membersProvider = StreamProvider.autoDispose
    .family<List<({String id, Role role, bool online})>, String>((ref, id) {
      return _ready(
        ref,
        const <({String id, Role role, bool online})>[],
        (e) => e.watch(
          (k) =>
              _any(k, [Ch.spaces, Ch.presence, Ch.peers, Scope.spaceMeta(id)]),
          () => e.members(id),
        ),
      );
    });

final activityProvider = StreamProvider.autoDispose<List<Activity>>((ref) {
  return _ready(
    ref,
    const <Activity>[],
    (e) => e.watch((k) => k.contains(Ch.activity), () => e.db.activity()),
  );
});

final unseenActivityProvider = StreamProvider.autoDispose<int>((ref) {
  return _ready(
    ref,
    0,
    (e) => e.watch((k) => k.contains(Ch.activity), e.db.unseenActivity),
  );
});

final filesProvider = StreamProvider.autoDispose<List<StoredFile>>((ref) {
  return _ready(
    ref,
    const <StoredFile>[],
    (e) => e.watch(
      (k) =>
          k.contains(Ch.files) || k.contains(Ch.feed) || k.contains(Ch.chats),
      e.db.files,
    ),
  );
});

/// Network status, refreshed on network events and every few seconds.
final netStatusProvider = StreamProvider.autoDispose<NetStatus>((ref) {
  final e = _eng(ref);
  if (e == null) {
    return Stream.value(const NetStatus(nodeId: '', running: false));
  }
  return _networkPoll(
    ref,
    e.netStatus,
    const Duration(seconds: 4),
    updates: e.changes.where(
      (k) => k.contains(Ch.net) || k.contains(Ch.presence),
    ),
  );
});

/// Native diagnostics, re-measured every few seconds while watched.
final diagnosticsProvider = StreamProvider.autoDispose<NetDiagnostics?>((ref) {
  final e = _eng(ref);
  if (e == null || !e.hasDiagnostics) {
    return Stream.value(null);
  }
  return _networkPoll(ref, e.diagnostics, const Duration(seconds: 3));
});

/// Own timers explicitly: cancelling an async* stream waiting on a periodic
/// source can leave the old poll alive across refreshes and screen disposal.
Stream<T> _networkPoll<T>(
  Ref ref,
  Future<T> Function() read,
  Duration interval, {
  Stream<Object?>? updates,
}) {
  final controller = StreamController<T>();
  Timer? timer;
  StreamSubscription<Object?>? subscription;
  var disposed = false;
  var busy = false;
  Future<void> poll() async {
    if (disposed || busy) return;
    busy = true;
    try {
      final value = await read();
      if (!disposed) controller.add(value);
    } catch (error, stack) {
      if (!disposed) controller.addError(error, stack);
    } finally {
      busy = false;
    }
  }

  controller.onListen = () {
    if (disposed) return;
    timer = Timer.periodic(interval, (_) => unawaited(poll()));
    subscription = updates?.listen((_) => unawaited(poll()));
    unawaited(poll());
  };
  ref.onDispose(() {
    disposed = true;
    timer?.cancel();
    unawaited(subscription?.cancel());
    unawaited(controller.close());
  });
  return controller.stream;
}

final alertsProvider = StreamProvider.autoDispose<List<Alert>>((ref) {
  return _ready(
    ref,
    const <Alert>[],
    (e) =>
        e.watch((k) => k.contains(Ch.alerts) || k.contains(Ch.xfers), e.alerts),
  );
});

final broadcastsProvider = StreamProvider.autoDispose<List<Bcast>>((ref) {
  return _ready(
    ref,
    const <Bcast>[],
    (e) =>
        e.watch((k) => _any(k, [Ch.channels, Ch.feed, Ch.peers]), e.broadcasts),
  );
});

final channelFeedProvider = StreamProvider.autoDispose
    .family<List<PostView>, (String, String)>((ref, ids) {
      return _ready(
        ref,
        const <PostView>[],
        (e) => e.watch(
          (k) => _any(k, [
            Ch.feed,
            Scope.bcast(ids.$1, ids.$2),
            Scope.channel(ids.$1, ids.$2),
          ]),
          () => e.channelFeed(owner: ids.$1, channelId: ids.$2),
        ),
      );
    });

final grantsProvider = StreamProvider.autoDispose<List<Grant>>((ref) {
  return _ready(
    ref,
    const <Grant>[],
    (e) => e.watch((k) => _any(k, [Ch.grants, Ch.peers]), e.db.grants),
  );
});

/// Minimal stream merge to avoid an extra dependency.
class StreamGroup {
  static Stream<void> merge(List<Stream<dynamic>> streams) {
    final c = StreamController<void>();
    final subs = <StreamSubscription>[];
    c.onListen = () {
      for (final s in streams) {
        subs.add(s.listen((_) => c.add(null)));
      }
    };
    c.onCancel = () async {
      for (final s in subs) {
        await s.cancel();
      }
    };
    return c.stream;
  }
}
