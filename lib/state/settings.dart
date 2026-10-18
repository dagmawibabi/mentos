import 'dart:convert';

import 'package:flutter/material.dart';

class Settings {
  const Settings({
    this.themeMode = ThemeMode.system,
    this.readReceipts = true,
    this.typingIndicators = true,
    this.keepPosts = false,
    this.keepReplies = true,
    this.keepProfile = true,
    this.autoAcceptSync = false,
    this.autoDownload = true,
    this.defaultTtl = 0,
    this.showOfflineHint = true,
    this.reduceMotion = false,
    this.hideStrangers = true,
    this.discoverable = false,
    this.systemNotify = true,
    this.hideNsfw = false,
    this.quotaMb = 2048,
    this.lockHash = '',
    this.lockAfter = 60,
    this.lockBio = false,
    this.privacy = 'standard',
    this.proxyUrl = defaultProxy,
    this.notify = const NotifyPrefs(),
    this.xferAutoAccept = false,
    this.xferAutoMaxMb = 50,
    this.xferParallel = 3,
    this.keepAlive = true,
    this.accent = 'emerald',
    this.devMode = false,
    this.devLan = false,
    this.devToken = '',
    this.showFeedTab = true,
    this.showWalletTab = true,
  });

  /// Orbot's HTTP CONNECT proxy.
  static const defaultProxy = 'http://127.0.0.1:8118';

  final ThemeMode themeMode;
  final bool readReceipts;
  final bool typingIndicators;

  /// Followers may preserve my posts and stories.
  final bool keepPosts;

  /// Post authors may keep my comments, likes and votes.
  final bool keepReplies;

  /// Contacts may remember my name and avatar while I'm away.
  final bool keepProfile;

  /// Accept chat sync requests without asking.
  final bool autoAcceptSync;
  final bool autoDownload;

  /// Default disappearing-message timer for new chats, in seconds (0 = off).
  final int defaultTtl;
  final bool showOfflineHint;
  final bool reduceMotion;

  /// Hide posts and stories from people you have not followed or chatted with.
  final bool hideStrangers;

  /// Let newly connected nodes see this profile and public posts.
  final bool discoverable;
  final bool systemNotify;

  /// Keep NSFW posts, stories, and messages covered. No tap-to-reveal.
  final bool hideNsfw;

  /// Soft cap for encrypted blobs on this device, in megabytes.
  final int quotaMb;

  /// SHA-256 of the app PIN. Empty means the lock is off.
  final String lockHash;

  /// Relock after this many seconds in the background.
  final int lockAfter;
  final bool lockBio;

  /// standard | relay | tor. See native/src/diag.rs.
  final String privacy;

  /// HTTP CONNECT proxy for relay and DNS traffic in tor mode.
  final String proxyUrl;
  final NotifyPrefs notify;

  /// Accept file transfers from people you follow without asking.
  final bool xferAutoAccept;

  /// Largest file accepted automatically, in megabytes.
  final int xferAutoMaxMb;

  /// Incoming transfers that may run at once; the rest wait in a queue.
  final int xferParallel;

  /// Keep the node running in the background so messages arrive without
  /// opening the app. Turn this off in Settings.
  final bool keepAlive;

  /// emerald | blue | amber | ink. Recolors the live accent.
  final String accent;

  /// Localhost API, logs, and extra network detail.
  final bool devMode;

  /// Developer API also answers other devices on the local network.
  final bool devLan;

  /// Access code browsers and scripts must present to the developer API.
  final String devToken;

  /// Feed icon in the bottom bar. The feed route still exists.
  final bool showFeedTab;

  /// Wallet icon in the bottom bar. Settings can still open the wallet.
  final bool showWalletTab;

  /// The options string handed to the native node before it binds.
  Map<String, Object?> get netOptions => {
        'privacy': privacy,
        if (privacy == 'tor') 'proxy': proxyUrl,
      };

  Settings copyWith({
    ThemeMode? themeMode,
    bool? readReceipts,
    bool? typingIndicators,
    bool? keepPosts,
    bool? keepReplies,
    bool? keepProfile,
    bool? autoAcceptSync,
    bool? autoDownload,
    int? defaultTtl,
    bool? showOfflineHint,
    bool? reduceMotion,
    bool? hideStrangers,
    bool? discoverable,
    bool? systemNotify,
    bool? hideNsfw,
    int? quotaMb,
    String? lockHash,
    int? lockAfter,
    bool? lockBio,
    String? privacy,
    String? proxyUrl,
    NotifyPrefs? notify,
    bool? xferAutoAccept,
    int? xferAutoMaxMb,
    int? xferParallel,
    bool? keepAlive,
    String? accent,
    bool? devMode,
    bool? devLan,
    String? devToken,
    bool? showFeedTab,
    bool? showWalletTab,
  }) =>
      Settings(
        themeMode: themeMode ?? this.themeMode,
        readReceipts: readReceipts ?? this.readReceipts,
        typingIndicators: typingIndicators ?? this.typingIndicators,
        keepPosts: keepPosts ?? this.keepPosts,
        keepReplies: keepReplies ?? this.keepReplies,
        keepProfile: keepProfile ?? this.keepProfile,
        autoAcceptSync: autoAcceptSync ?? this.autoAcceptSync,
        autoDownload: autoDownload ?? this.autoDownload,
        defaultTtl: defaultTtl ?? this.defaultTtl,
        showOfflineHint: showOfflineHint ?? this.showOfflineHint,
        reduceMotion: reduceMotion ?? this.reduceMotion,
        hideStrangers: hideStrangers ?? this.hideStrangers,
        discoverable: discoverable ?? this.discoverable,
        systemNotify: systemNotify ?? this.systemNotify,
        hideNsfw: hideNsfw ?? this.hideNsfw,
        quotaMb: quotaMb ?? this.quotaMb,
        lockHash: lockHash ?? this.lockHash,
        lockAfter: lockAfter ?? this.lockAfter,
        lockBio: lockBio ?? this.lockBio,
        privacy: privacy ?? this.privacy,
        proxyUrl: proxyUrl ?? this.proxyUrl,
        notify: notify ?? this.notify,
        xferAutoAccept: xferAutoAccept ?? this.xferAutoAccept,
        xferAutoMaxMb: xferAutoMaxMb ?? this.xferAutoMaxMb,
        xferParallel: xferParallel ?? this.xferParallel,
        keepAlive: keepAlive ?? this.keepAlive,
        accent: accent ?? this.accent,
        devMode: devMode ?? this.devMode,
        devLan: devLan ?? this.devLan,
        devToken: devToken ?? this.devToken,
        showFeedTab: showFeedTab ?? this.showFeedTab,
        showWalletTab: showWalletTab ?? this.showWalletTab,
      );

  String encode() => jsonEncode({
        'theme': themeMode.name,
        'rr': readReceipts,
        'ti': typingIndicators,
        'kp': keepPosts,
        'kr': keepReplies,
        'kpr': keepProfile,
        'aas': autoAcceptSync,
        'ad': autoDownload,
        'ttl': defaultTtl,
        'hint': showOfflineHint,
        'rm': reduceMotion,
        'hs': hideStrangers,
        'disc': discoverable,
        'sn': systemNotify,
        'nsfw': hideNsfw,
        'quota': quotaMb,
        'pin': lockHash,
        'lock': lockAfter,
        'bio': lockBio,
        'priv': privacy,
        'proxy': proxyUrl,
        'notify': notify.toJson(),
        'xa': xferAutoAccept,
        'xmax': xferAutoMaxMb,
        'xpar': xferParallel,
        'bg': keepAlive,
        'accent': accent,
        'dev': devMode,
        'devLan': devLan,
        'devTok': devToken,
        'navFeed': showFeedTab,
        'navWallet': showWalletTab,
      });

  static Settings decode(String? s) {
    if (s == null) return const Settings();
    try {
      final j = jsonDecode(s) as Map;
      return Settings(
        themeMode: ThemeMode.values.firstWhere((m) => m.name == j['theme'], orElse: () => ThemeMode.system),
        readReceipts: j['rr'] != false,
        typingIndicators: j['ti'] != false,
        keepPosts: j['kp'] == true,
        keepReplies: j['kr'] != false,
        keepProfile: j['kpr'] != false,
        autoAcceptSync: j['aas'] == true,
        autoDownload: j['ad'] != false,
        defaultTtl: (j['ttl'] as num?)?.toInt() ?? 0,
        showOfflineHint: j['hint'] != false,
        reduceMotion: j['rm'] == true,
        hideStrangers: j['hs'] != false,
        discoverable: j['disc'] == true,
        systemNotify: j['sn'] != false,
        hideNsfw: j['nsfw'] == true,
        quotaMb: (j['quota'] as num?)?.toInt() ?? 2048,
        lockHash: (j['pin'] as String?) ?? '',
        lockAfter: (j['lock'] as num?)?.toInt() ?? 60,
        lockBio: j['bio'] == true,
        privacy: const {'standard', 'relay', 'tor'}.contains(j['priv']) ? j['priv'] as String : 'standard',
        proxyUrl: j['proxy'] is String ? j['proxy'] as String : defaultProxy,
        notify: NotifyPrefs.fromJson(j['notify']),
        xferAutoAccept: j['xa'] == true,
        xferAutoMaxMb: ((j['xmax'] as num?)?.toInt() ?? 50).clamp(1, 4096),
        xferParallel: ((j['xpar'] as num?)?.toInt() ?? 3).clamp(1, 8),
        keepAlive: j['bg'] is bool ? j['bg'] as bool : true,
        accent: const {'emerald', 'blue', 'amber', 'ink'}.contains(j['accent']) ? j['accent'] as String : 'emerald',
        devMode: j['dev'] == true,
        devLan: j['devLan'] == true,
        devToken: j['devTok'] is String ? j['devTok'] as String : '',
        showFeedTab: j['navFeed'] != false,
        showWalletTab: j['navWallet'] != false,
      );
    } catch (_) {
      return const Settings();
    }
  }
}

/// Which events raise an operating-system notification.
class NotifyPrefs {
  const NotifyPrefs({
    this.dms = true,
    this.groups = true,
    this.mentions = true,
    this.replies = true,
    this.likes = false,
    this.follows = true,
    this.invites = true,
    this.transfers = true,
    this.stories = false,
    this.channels = true,
    this.preview = true,
    this.quietFrom = -1,
    this.quietTo = -1,
  });

  final bool dms;
  final bool groups;
  final bool mentions;
  final bool replies;
  final bool likes;
  final bool follows;
  final bool invites;
  final bool transfers;
  final bool stories;
  final bool channels;

  /// Show who and what in the notification. Off shows only "New message".
  final bool preview;

  /// Quiet hours as minutes after midnight; -1 means off.
  final int quietFrom;
  final int quietTo;

  bool get hasQuietHours => quietFrom >= 0 && quietTo >= 0 && quietFrom != quietTo;

  /// True when [at] falls inside quiet hours, including windows across midnight.
  bool quietAt(DateTime at) {
    if (!hasQuietHours) return false;
    final m = at.hour * 60 + at.minute;
    return quietFrom < quietTo ? m >= quietFrom && m < quietTo : m >= quietFrom || m < quietTo;
  }

  /// Whether a notification of [category] is wanted. Categories match the
  /// field names; unknown categories are allowed.
  bool wants(String category) => switch (category) {
        'dm' => dms,
        'group' => groups,
        'mention' => mentions,
        'reply' => replies,
        'like' => likes,
        'follow' => follows,
        'invite' => invites,
        'xfer' => transfers,
        'story' => stories,
        'channel' => channels,
        _ => true,
      };

  NotifyPrefs copyWith({
    bool? dms,
    bool? groups,
    bool? mentions,
    bool? replies,
    bool? likes,
    bool? follows,
    bool? invites,
    bool? transfers,
    bool? stories,
    bool? channels,
    bool? preview,
    int? quietFrom,
    int? quietTo,
  }) =>
      NotifyPrefs(
        dms: dms ?? this.dms,
        groups: groups ?? this.groups,
        mentions: mentions ?? this.mentions,
        replies: replies ?? this.replies,
        likes: likes ?? this.likes,
        follows: follows ?? this.follows,
        invites: invites ?? this.invites,
        transfers: transfers ?? this.transfers,
        stories: stories ?? this.stories,
        channels: channels ?? this.channels,
        preview: preview ?? this.preview,
        quietFrom: quietFrom ?? this.quietFrom,
        quietTo: quietTo ?? this.quietTo,
      );

  Map<String, Object> toJson() => {
        'dm': dms,
        'gr': groups,
        'me': mentions,
        're': replies,
        'li': likes,
        'fo': follows,
        'in': invites,
        'xf': transfers,
        'st': stories,
        'ch': channels,
        'pv': preview,
        'qf': quietFrom,
        'qt': quietTo,
      };

  static NotifyPrefs fromJson(Object? j) {
    if (j is! Map) return const NotifyPrefs();
    int minutes(Object? v) => v is num && v >= -1 && v < 1440 ? v.toInt() : -1;
    return NotifyPrefs(
      dms: j['dm'] != false,
      groups: j['gr'] != false,
      mentions: j['me'] != false,
      replies: j['re'] != false,
      likes: j['li'] == true,
      follows: j['fo'] != false,
      invites: j['in'] != false,
      transfers: j['xf'] != false,
      stories: j['st'] == true,
      channels: j['ch'] != false,
      preview: j['pv'] != false,
      quietFrom: minutes(j['qf']),
      quietTo: minutes(j['qt']),
    );
  }
}
