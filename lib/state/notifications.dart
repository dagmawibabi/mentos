import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/router.dart';
import '../data/models.dart';
import '../net/engine.dart';
import 'session.dart';
import 'settings.dart';

/// Decides whether a note becomes a notification. Pure apart from the
/// de-duplication set, so it is unit tested without a platform.
class NotifyGate {
  final _shown = <String>{};

  /// Older events arrive again when history re-syncs after a restart; they
  /// are not news.
  static const maxAge = Duration(minutes: 15);

  OsNote? decide(
    OsNote n,
    Settings s, {
    required DateTime now,
    required bool foreground,
    required bool muted,
  }) {
    if (!s.systemNotify) return null;
    if (foreground) return null;
    if (!s.notify.wants(n.category)) return null;
    // A mention still gets through a muted group, like Telegram.
    if (muted && n.category != 'mention') return null;
    if (s.notify.quietAt(now)) return null;
    if (now.millisecondsSinceEpoch - n.at > maxAge.inMilliseconds) return null;
    if (!_shown.add(n.id)) return null;
    if (_shown.length > 4000) _shown.remove(_shown.first);
    if (s.notify.preview) return n;
    return OsNote(id: n.id, category: n.category, title: 'Mentos', body: genericBody(n.category), at: n.at, route: n.route, scope: n.scope);
  }

  static String genericBody(String category) => switch (category) {
        'dm' => 'New message',
        'group' => 'New group message',
        'mention' => 'You were mentioned',
        'reply' => 'New reply',
        'like' => 'New like',
        'follow' => 'New follower',
        'invite' => 'New invitation',
        'xfer' => 'Incoming file',
        'story' => 'New story',
        'channel' => 'New channel post',
        _ => 'Something new',
      };
}

const _channels = {
  'dm': ('Direct messages', Importance.high),
  'group': ('Group messages', Importance.high),
  'mention': ('Mentions', Importance.high),
  'reply': ('Replies', Importance.defaultImportance),
  'like': ('Likes', Importance.low),
  'follow': ('Followers', Importance.defaultImportance),
  'invite': ('Invitations', Importance.high),
  'xfer': ('File transfers', Importance.high),
  'story': ('Stories', Importance.low),
  'channel': ('Channels', Importance.defaultImportance),
  'other': ('Other', Importance.low),
};

/// Shows operating-system notifications for one engine. Each category is its
/// own Android channel so people can also tune them in system settings.
class NotificationService with WidgetsBindingObserver {
  NotificationService(this.engine, this.router);

  final Engine engine;
  final GoRouter router;
  final gate = NotifyGate();
  final _plugin = FlutterLocalNotificationsPlugin();
  StreamSubscription<OsNote>? _sub;
  bool _ready = false;
  bool _foreground = true;

  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isLinux);

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.hidden;
    _sub = engine.notes.listen(_onNote);
    if (!supported) return;
    try {
      _ready = await _plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher'),
              iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
              macOS: DarwinInitializationSettings(),
              linux: LinuxInitializationSettings(defaultActionName: 'Open'),
            ),
            onDidReceiveNotificationResponse: (r) => _open(r.payload),
          ) ??
          false;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) _open(launch!.notificationResponse?.payload);
    } catch (_) {
      _ready = false;
    }
  }

  /// Asks the OS for permission (Android 13+, iOS). Returns whether granted.
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    try {
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
                ?.requestNotificationsPermission() ??
            false;
      }
      if (Platform.isIOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
    } catch (_) {}
    return true;
  }

  void _open(String? route) {
    if (route == null || route.isEmpty) return;
    try {
      router.push(route);
    } catch (_) {}
  }

  bool _muted(OsNote n) {
    final scope = n.scope;
    if (scope == null) return false;
    try {
      if (engine.db.chat(scope)['muted'] == 1) return true;
      final spaceId = Scope.spaceOf(scope);
      if (spaceId != null && (engine.space(spaceId)?.muted ?? false)) return true;
    } catch (_) {}
    return false;
  }

  Future<void> _onNote(OsNote n) async {
    final show = gate.decide(n, engine.settings, now: DateTime.now(), foreground: _foreground, muted: _muted(n));
    if (show == null || !_ready) return;
    final (name, importance) = _channels[show.category] ?? _channels['other']!;
    try {
      await _plugin.show(
        id: show.id.hashCode & 0x7fffffff,
        title: show.title,
        body: show.body,
        payload: show.route,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'mentos.${show.category}',
            name,
            importance: importance,
            priority: importance == Importance.high ? Priority.high : Priority.defaultPriority,
            groupKey: show.scope,
            category: show.category == 'dm' || show.category == 'group' ? AndroidNotificationCategory.message : null,
            visibility: engine.settings.notify.preview ? NotificationVisibility.private : NotificationVisibility.secret,
          ),
          iOS: DarwinNotificationDetails(threadIdentifier: show.scope),
          macOS: DarwinNotificationDetails(threadIdentifier: show.scope),
        ),
      );
    } catch (_) {}
  }

  /// Clears shown notifications once the person is back in the app.
  Future<void> clearAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (state == AppLifecycleState.resumed) unawaited(clearAll());
  }

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    await _sub?.cancel();
  }
}

/// Alive while a session is open; watched by the app root.
final notificationServiceProvider = Provider<NotificationService?>((ref) {
  final s = ref.watch(sessionProvider);
  if (s is! SessionReady) return null;
  final service = NotificationService(s.engine, ref.read(routerProvider));
  unawaited(service.start());
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
