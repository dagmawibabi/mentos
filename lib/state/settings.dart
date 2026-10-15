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
  });

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
      );
    } catch (_) {
      return const Settings();
    }
  }
}
