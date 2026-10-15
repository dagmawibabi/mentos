import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../core/crypto/crypto.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();
int nowMs() => DateTime.now().millisecondsSinceEpoch;

/// Item kinds. Everything a person creates is one signed item.
abstract final class K {
  static const post = 'post';
  static const comment = 'comment';
  static const like = 'like';
  static const vote = 'vote';
  static const msg = 'msg';
  static const react = 'react';
  static const edit = 'edit';
  static const del = 'del';
  static const story = 'story';
  static const profile = 'profile';
  static const spaceMeta = 'space';
  static const member = 'member';
  static const host = 'host';
  static const group = 'group';
  static const chan = 'chan';
  static const view = 'view';
  static const invite = 'invite';

  static const known = {
    post, comment, like, vote, msg, react, edit, del, story, profile, spaceMeta, member, host, group, chan, view, invite,
  };

  static const mutations = {like, vote, react, edit, del, view};
}

/// Scopes say where an item belongs, and therefore who may see or keep it.
abstract final class Scope {
  static String dm(String a, String b) {
    final s = [a, b]..sort();
    return 'dm:${s[0]}:${s[1]}';
  }

  static String feed(String author) => 'feed:$author';
  static String story(String author) => 'story:$author';
  static String profile(String author) => 'profile:$author';
  static String post(String postAuthor, String postId) => 'post:$postAuthor:$postId';
  static String channel(String spaceId, String channelId) => 'chan:$spaceId:$channelId';
  static String spaceFeed(String spaceId) => 'sfeed:$spaceId';
  static String spaceMeta(String spaceId) => 'space:$spaceId';
  static String files(String author) => 'files:$author';
  static String forum(String spaceId, String boardId) => 'forum:$spaceId:$boardId';
  static String gdm(String groupId) => 'gdm:$groupId';
  static String gmeta(String groupId) => 'gmeta:$groupId';
  static String bcast(String author, String channelId) => 'bcast:$author:$channelId';

  static String type(String scope) {
    final i = scope.indexOf(':');
    if (i <= 0) return '';
    return scope.substring(0, i);
  }

  static List<String> parts(String scope) => scope.split(':');

  static String? dmPeer(String scope, String me) {
    final p = parts(scope);
    if (p.length != 3 || p.first != 'dm' || p[1].isEmpty || p[2].isEmpty) return null;
    if (p[1] != me && p[2] != me) return null;
    return p[1] == me ? p[2] : p[1];
  }

  /// The space id for space-bound scopes, null otherwise.
  static String? spaceOf(String scope) {
    final p = parts(scope);
    if (p.length < 2 || p[1].isEmpty) return null;
    return switch (p.first) { 'chan' || 'sfeed' || 'space' || 'forum' => p[1], _ => null };
  }

  static String? bcastOwner(String scope) {
    final p = parts(scope);
    if (p.length < 2 || p.first != 'bcast' || p[1].isEmpty) return null;
    return p[1];
  }

  /// Comments and likes on a post live in the post's own scope; returns the
  /// post author encoded in it.
  static String? postAuthor(String scope) {
    final p = parts(scope);
    if (p.length < 2 || p.first != 'post' || p[1].isEmpty) return null;
    return p[1];
  }
}

/// A signed, immutable unit of content. [payload] is the exact JSON string the
/// signature covers, so it is relayed verbatim and never re-serialized.
class Envelope {
  Envelope._(this.payload, this.sig, this._m);

  final String payload;
  final String sig;
  final Map<String, dynamic> _m;

  String get id => _m['id'] as String;
  String get kind => _m['k'] as String;
  String get author => _m['a'] as String;
  String get scope => _m['s'] as String;
  int get ts => (_m['t'] as num).toInt();
  Map<String, dynamic> get body => (_m['b'] as Map).cast<String, dynamic>();

  /// True when this kind is allowed to live in [scope]. A profile in a chat
  /// used to pass the participant check and then delete the chat history.
  bool get allowedHere {
    final type = Scope.type(scope);
    if (type.isEmpty) return false;
    const chats = {'dm', 'gdm', 'chan'};
    const posts = {'feed', 'sfeed', 'forum', 'bcast', 'chan'};
    const social = {'feed', 'sfeed', 'forum', 'bcast', 'post', 'story', 'dm', 'gdm', 'chan'};
    switch (kind) {
      case K.profile:
        return scope == Scope.profile(author);
      case K.msg:
        return chats.contains(type);
      case K.react:
        return chats.contains(type) || type == 'story';
      case K.post:
        return posts.contains(type);
      case K.comment:
        return type == 'post' || type == 'story';
      case K.story:
        return scope == Scope.story(author);
      case K.host:
        return scope == Scope.files(author);
      case K.spaceMeta:
      case K.member:
      case K.invite:
        return type == 'space';
      case K.group:
        return type == 'gmeta';
      case K.chan:
        return type == 'feed' || type == 'bcast';
      case K.like:
      case K.vote:
      case K.view:
      case K.edit:
      case K.del:
        return social.contains(type);
      default:
        return false;
    }
  }

  /// The author's consent for recipients to keep a copy.
  bool get keep => _m['kp'] == true;

  /// Mutations point at another item.
  String? get target => body['target'] as String?;

  /// Expiry for disappearing content, ms since epoch.
  int? get expires => (body['exp'] as num?)?.toInt();

  static Future<Envelope> create(
    Identity me, {
    required String kind,
    required String scope,
    required Map<String, dynamic> body,
    bool keep = false,
    String? id,
    int? ts,
  }) async {
    final m = <String, dynamic>{
      'v': 1,
      'id': id ?? newId(),
      'k': kind,
      'a': me.id,
      's': scope,
      't': ts ?? nowMs(),
      'b': body,
      'kp': keep,
    };
    final payload = jsonEncode(m);
    final sig = await me.sign(utf8.encode(payload));
    return Envelope._(payload, sig, m);
  }

  static Envelope? fromParts(String payload, String sig) {
    try {
      if (payload.length > 256 * 1024 || sig.length > 4096) return null;
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      final m = decoded.cast<String, dynamic>();
      if (m['id'] is! String || m['k'] is! String || m['a'] is! String || m['s'] is! String) return null;
      if (m['t'] is! num || m['b'] is! Map) return null;
      return Envelope._(payload, sig, m);
    } catch (_) {
      return null;
    }
  }

  static Envelope? fromWire(Object? w) {
    if (w is! Map) return null;
    final p = w['p'], s = w['s'];
    if (p is! String || s is! String) return null;
    return fromParts(p, s);
  }

  Map<String, String> toWire() => {'p': payload, 's': sig};

  Future<bool> verify() => Identity.verify(author, utf8.encode(payload), sig);

  /// Rejects shapes that would crash a renderer or bloat the database.
  bool get sane {
    if (!K.known.contains(kind) || !allowedHere) return false;
    if (id.isEmpty || id.length > 80 || scope.isEmpty || scope.length > 180) return false;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(author)) return false;
    if (ts < 0) return false;
    final text = body['text'];
    if (text != null && (text is! String || text.length > 20000)) return false;
    final bio = body['bio'];
    if (bio != null && (bio is! String || bio.length > 4000)) return false;
    final title = body['name'];
    if (title != null && (title is! String || title.length > 200)) return false;
    final media = body['media'];
    if (media != null && (media is! List || media.length > 12)) return false;
    if (media is List) {
      for (final entry in media) {
        if (entry != null && MediaRef.fromJson(entry) == null) return false;
      }
    }
    final avatar = body['avatar'];
    if (avatar != null && MediaRef.fromJson(avatar) == null) return false;
    if (!_pollOk(body['poll'])) return false;
    final repost = body['repost'];
    if (repost != null && repost is! Map) return false;
    final board = body['board'];
    if (board != null && board is! String) return false;
    final channel = body['channel'];
    if (channel != null && channel is! String) return false;
    final reply = body['replyTo'];
    if (reply != null && reply is! String) return false;
    final emoji = body['emoji'];
    if (emoji != null && (emoji is! String || emoji.length > 32)) return false;
    final stickers = body['stk'];
    if (stickers != null) {
      if (kind != K.story || stickers is! List || stickers.length > StorySticker.max) return false;
      for (final st in stickers) {
        if (StorySticker.fromJson(st) == null) return false;
      }
    }
    final story = body['story'];
    if (story != null) {
      if (kind != K.msg || story is! Map) return false;
      if (story['id'] is! String || story['a'] is! String) return false;
      final t = story['text'];
      if (t != null && (t is! String || t.length > 200)) return false;
      final q = story['prompt'];
      if (q != null && (q is! String || q.length > 200)) return false;
    }
    return true;
  }

  static bool _pollOk(Object? poll) {
    if (poll == null) return true;
    if (poll is! Map) return false;
    final q = poll['q'];
    if (q != null && (q is! String || q.length > 500)) return false;
    final options = poll['o'];
    if (options is! List || options.length < 2 || options.length > 16) return false;
    for (final option in options) {
      if (option is! String || option.isEmpty || option.length > 200) return false;
    }
    final closes = poll['c'];
    if (closes != null && closes is! num) return false;
    return true;
  }
}

/// An item as seen locally, with where it currently lives.
class Item {
  const Item(this.e, {required this.owned, required this.kept});
  final Envelope e;

  /// Created on this device.
  final bool owned;

  /// Someone else's item that this device has agreed to keep.
  final bool kept;

  /// Visible only while the author is reachable.
  bool get live => !owned && !kept;

  String get id => e.id;
  String get author => e.author;
  int get ts => e.ts;
  Map<String, dynamic> get body => e.body;
}

/// Reference to an encrypted blob. The key never leaves signed content.
class MediaRef {
  const MediaRef({
    required this.hash,
    required this.key,
    required this.name,
    required this.mime,
    required this.size,
    this.width,
    this.height,
    this.durationMs,
    this.wave,
  });

  final String hash;
  final String key;
  final String name;
  final String mime;
  final int size;
  final int? width;
  final int? height;
  final int? durationMs;
  final List<int>? wave;

  bool get isImage => mime.startsWith('image/');
  bool get isVideo => mime.startsWith('video/');
  bool get isAudio => mime.startsWith('audio/');
  bool get isVoice => wave != null;
  double? get aspect => (width != null && height != null && height! > 0) ? width! / height! : null;

  Map<String, dynamic> toJson() => {
        'h': hash,
        'key': key,
        'n': name,
        'm': mime,
        'sz': size,
        if (width != null) 'w': width,
        if (height != null) 'ht': height,
        if (durationMs != null) 'd': durationMs,
        if (wave != null) 'wv': wave,
      };

  static MediaRef? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final hash = j['h'];
      final key = j['key'];
      if (hash is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) return null;
      if (key is! String || key.isEmpty || key.length > 512) return null;
      final wave = j['wv'];
      List<int>? samples;
      if (wave != null) {
        if (wave is! List || wave.length > 256) return null;
        samples = [for (final e in wave) if (e is num) e.toInt()];
        if (samples.length != wave.length) return null;
      }
      final size = j['sz'];
      if (size != null && size is! num) return null;
      return MediaRef(
        hash: hash.toLowerCase(),
        key: key,
        name: j['n'] is String ? j['n'] as String : 'file',
        mime: j['m'] is String ? j['m'] as String : 'application/octet-stream',
        size: size is num ? size.toInt().clamp(0, 1 << 30) : 0,
        width: j['w'] is num ? (j['w'] as num).toInt() : null,
        height: j['ht'] is num ? (j['ht'] as num).toInt() : null,
        durationMs: j['d'] is num ? (j['d'] as num).toInt() : null,
        wave: samples,
      );
    } catch (_) {
      return null;
    }
  }

  static List<MediaRef> listFrom(Object? j) =>
      j is List ? j.map(MediaRef.fromJson).whereType<MediaRef>().toList() : const [];
}

class Profile {
  const Profile({
    required this.id,
    this.name = '',
    this.bio = '',
    this.avatar,
    this.keepPosts = false,
    this.discoverable = false,
    this.ts = 0,
  });

  final String id;
  final String name;
  final String bio;
  final MediaRef? avatar;

  /// Author allows followers to preserve their posts.
  final bool keepPosts;

  /// Strangers who connect may see this profile and its public posts.
  final bool discoverable;
  final int ts;

  String get displayName => name.isNotEmpty ? name : alias(id);

  static Profile fromEnvelope(Envelope e) => Profile(
        id: e.author,
        name: e.body['name'] is String ? e.body['name'] as String : '',
        bio: e.body['bio'] is String ? e.body['bio'] as String : '',
        avatar: MediaRef.fromJson(e.body['avatar']),
        keepPosts: e.body['keepPosts'] == true,
        discoverable: e.body['discoverable'] == true,
        ts: e.ts,
      );
}

class Peer {
  const Peer({
    required this.id,
    this.profile,
    this.nickname,
    this.lastSeen = 0,
    this.iFollow = false,
    this.followsMe = false,
    this.blocked = false,
    this.preserve = false,
    this.addr,
  });

  final String id;
  final Profile? profile;
  final String? nickname;
  final int lastSeen;
  final bool iFollow;
  final bool followsMe;
  final bool blocked;

  /// I agreed to keep this person's public posts.
  final bool preserve;
  final String? addr;

  String get name => (nickname?.isNotEmpty ?? false) ? nickname! : (profile?.displayName ?? alias(id));
}

enum Role { owner, mod, member, banned }

class Channel {
  const Channel(this.id, this.name, {this.about = ''});
  final String id;
  final String name;
  final String about;
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (about.isNotEmpty) 'about': about,
      };
}

List<Channel> _channelsOf(Object? j) {
  if (j is! List) return const [];
  final out = <Channel>[];
  for (final c in j) {
    if (c is! Map) continue;
    final id = c['id'];
    final name = c['name'];
    if (id is! String || id.isEmpty || id.length > 80) continue;
    if (name is! String || name.isEmpty || name.length > 80) continue;
    final about = c['about'] is String ? c['about'] as String : '';
    out.add(Channel(id, name, about: about.length > 240 ? about.substring(0, 240) : about));
  }
  return out;
}

Map<String, Role> _rolesOf(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, Role>{};
  for (final entry in raw.entries) {
    final name = entry.value;
    if (entry.key is! String || name is! String) continue;
    out[entry.key as String] = Role.values.firstWhere(
      (r) => r.name == name,
      orElse: () => Role.member,
    );
  }
  return out;
}

class SpaceInfo {
  const SpaceInfo({
    required this.id,
    required this.name,
    required this.owner,
    required this.key,
    this.about = '',
    this.channels = const [],
    this.forums = const [],
    this.roles = const {},
    this.archive = true,
    this.preserve = false,
    this.shareMine = true,
    this.muted = false,
    this.joined = 0,
    this.metaTs = 0,
  });

  final String id;
  final String name;
  final String about;
  final String owner;

  /// Shared symmetric key. Holding it is what makes someone a member.
  final String key;
  final List<Channel> channels;
  final List<Channel> forums;
  final Map<String, Role> roles;

  /// Owner allows members to keep history.
  final bool archive;

  /// I keep other members' history on this device.
  final bool preserve;

  /// Members may keep my messages in this space.
  final bool shareMine;
  final bool muted;
  final int joined;
  final int metaTs;

  Role roleOf(String id) => id == owner ? Role.owner : (roles[id] ?? Role.member);

  SpaceInfo copyWith({
    String? name,
    String? about,
    String? key,
    List<Channel>? channels,
    List<Channel>? forums,
    Map<String, Role>? roles,
    bool? archive,
    bool? preserve,
    bool? shareMine,
    bool? muted,
    int? metaTs,
  }) =>
      SpaceInfo(
        id: id,
        name: name ?? this.name,
        about: about ?? this.about,
        owner: owner,
        key: key ?? this.key,
        channels: channels ?? this.channels,
        forums: forums ?? this.forums,
        roles: roles ?? this.roles,
        archive: archive ?? this.archive,
        preserve: preserve ?? this.preserve,
        shareMine: shareMine ?? this.shareMine,
        muted: muted ?? this.muted,
        joined: joined,
        metaTs: metaTs ?? this.metaTs,
      );

  Map<String, dynamic> metaJson() => {
        'name': name,
        'about': about,
        'channels': channels.map((c) => c.toJson()).toList(),
        'forums': forums.map((c) => c.toJson()).toList(),
        'roles': roles.map((k, v) => MapEntry(k, v.name)),
        'archive': archive,
      };

  Map<String, dynamic> toJson() => {
        ...metaJson(),
        'id': id,
        'owner': owner,
        'key': key,
        'preserve': preserve,
        'shareMine': shareMine,
        'muted': muted,
        'joined': joined,
        'metaTs': metaTs,
      };

  static SpaceInfo? tryParse(Object? raw) {
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) return null;
      final j = decoded;
      final id = j['id'];
      final name = j['name'];
      final owner = j['owner'];
      final key = j['key'];
      if (id is! String || name is! String || owner is! String || key is! String) return null;
      if (id.isEmpty || owner.isEmpty || key.isEmpty) return null;
      return SpaceInfo(
        id: id,
        name: name,
        about: j['about'] is String ? j['about'] as String : '',
        owner: owner,
        key: key,
        channels: _channelsOf(j['channels']),
        forums: _channelsOf(j['forums']).isEmpty
            ? const [Channel('general', 'general')]
            : _channelsOf(j['forums']),
        roles: _rolesOf(j['roles']),
        archive: j['archive'] != false,
        preserve: j['preserve'] == true,
        shareMine: j['shareMine'] != false,
        muted: j['muted'] == true,
        joined: j['joined'] is num ? (j['joined'] as num).toInt() : 0,
        metaTs: j['metaTs'] is num ? (j['metaTs'] as num).toInt() : 0,
      );
    } catch (_) {
      return null;
    }
  }

  static SpaceInfo fromJson(Map<String, dynamic> j) =>
      tryParse(j) ?? (throw const FormatException('Space record is unreadable'));

  SpaceInfo withMeta(Envelope e) {
    final b = e.body;
    return SpaceInfo(
      id: id,
      name: b['name'] is String ? b['name'] as String : name,
      about: b['about'] is String ? b['about'] as String : about,
      owner: owner,
      key: key,
      channels: _channelsOf(b['channels']),
      forums: _channelsOf(b['forums']).isEmpty ? forums : _channelsOf(b['forums']),
      roles: _rolesOf(b['roles']),
      archive: b['archive'] != false,
      preserve: preserve,
      shareMine: shareMine,
      muted: muted,
      joined: joined,
      metaTs: e.ts,
    );
  }
}

/// Consent record for keeping someone's items in a scope.
/// `out`: I let [peer] keep mine. `in`: [peer] lets me keep theirs.
enum GrantDir { out, inbound }

enum GrantState { pending, active }

class Grant {
  const Grant(this.scope, this.peer, this.dir, this.state);
  final String scope;
  final String peer;
  final GrantDir dir;
  final GrantState state;
}

class Activity {
  const Activity({
    required this.id,
    required this.kind,
    required this.actor,
    required this.ts,
    this.ref,
    this.scope,
    this.text,
    this.seen = false,
  });
  final String id;
  final String kind;
  final String actor;
  final int ts;
  final String? ref;
  final String? scope;
  final String? text;
  final bool seen;
}

class StoredFile {
  const StoredFile({
    required this.hash,
    required this.name,
    required this.mime,
    required this.size,
    required this.key,
    required this.origin,
    required this.created,
    this.scope,
  });
  final String hash;
  final String name;
  final String mime;
  final int size;
  final String key;

  /// mine | kept | cache
  final String origin;
  final int created;
  final String? scope;

  MediaRef get ref => MediaRef(hash: hash, key: key, name: name, mime: mime, size: size);
}

class GroupInfo {
  const GroupInfo({
    required this.id,
    required this.name,
    required this.owner,
    required this.key,
    required this.members,
    this.roles = const {},
    this.preserve = false,
    this.shareMine = true,
    this.joined = 0,
    this.metaTs = 0,
  });

  final String id;
  final String name;
  final String owner;
  final String key;
  final List<String> members;
  final Map<String, Role> roles;
  final bool preserve;
  final bool shareMine;
  final int joined;
  final int metaTs;

  bool has(String id) => id == owner || members.contains(id);
  Role roleOf(String id) => id == owner ? Role.owner : (roles[id] ?? Role.member);

  GroupInfo copyWith({
    String? name,
    String? owner,
    String? key,
    List<String>? members,
    Map<String, Role>? roles,
    bool? preserve,
    bool? shareMine,
    int? metaTs,
  }) =>
      GroupInfo(
        id: id,
        name: name ?? this.name,
        owner: owner ?? this.owner,
        key: key ?? this.key,
        members: members ?? this.members,
        roles: roles ?? this.roles,
        preserve: preserve ?? this.preserve,
        shareMine: shareMine ?? this.shareMine,
        joined: joined,
        metaTs: metaTs ?? this.metaTs,
      );

  Map<String, dynamic> metaJson() => {
        'name': name,
        'members': members,
        'owner': owner,
        'roles': roles.map((k, v) => MapEntry(k, v.name)),
      };

  Map<String, dynamic> toJson() => {
        ...metaJson(),
        'id': id,
        'key': key,
        'preserve': preserve,
        'shareMine': shareMine,
        'joined': joined,
        'metaTs': metaTs,
      };

  static GroupInfo? tryParse(Object? raw) {
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) return null;
      final j = decoded;
      final id = j['id'];
      final owner = j['owner'];
      final key = j['key'];
      if (id is! String || owner is! String || key is! String) return null;
      if (id.isEmpty || owner.isEmpty || key.isEmpty) return null;
      return GroupInfo(
        id: id,
        name: j['name'] is String ? j['name'] as String : 'Group',
        owner: owner,
        key: key,
        members: [for (final x in (j['members'] as List?) ?? const []) if (x is String && x.isNotEmpty) x],
        roles: _rolesOf(j['roles']),
        preserve: j['preserve'] == true,
        shareMine: j['shareMine'] != false,
        joined: j['joined'] is num ? (j['joined'] as num).toInt() : 0,
        metaTs: j['metaTs'] is num ? (j['metaTs'] as num).toInt() : 0,
      );
    } catch (_) {
      return null;
    }
  }

  static GroupInfo fromJson(Map<String, dynamic> j) =>
      tryParse(j) ?? (throw const FormatException('Group record is unreadable'));

  GroupInfo withMeta(Envelope e) {
    final b = e.body;
    final fromOwner = e.author == owner;
    var nextMembers = members;
    if (b['members'] is List) {
      final claimed = [for (final x in b['members'] as List) if (x is String) x];
      if (fromOwner) {
        nextMembers = claimed;
      } else if (members.contains(e.author) && !claimed.contains(e.author)) {
        final rest = members.where((m) => m != e.author).toSet();
        if (rest.containsAll(claimed) && claimed.toSet().containsAll(rest)) nextMembers = claimed;
      }
    }
    return GroupInfo(
      id: id,
      name: fromOwner && b['name'] is String ? b['name'] as String : name,
      owner: owner,
      key: key,
      members: nextMembers,
      roles: fromOwner ? _rolesOf(b['roles']) : roles,
      preserve: preserve,
      shareMine: shareMine,
      joined: joined,
      metaTs: e.ts,
    );
  }
}

enum XferDir { out, inbound }

enum XferState { offer, active, done, failed, declined, cancelled }

class FileTransfer {
  FileTransfer({
    required this.id,
    required this.peer,
    required this.media,
    required this.dir,
    required this.state,
    required this.started,
    this.done = 0,
    this.error,
  });

  final String id;
  final String peer;
  final MediaRef media;
  final XferDir dir;
  XferState state;
  int done;
  final int started;
  String? error;
  int bps = 0;
  int _markAt = 0;
  int _markDone = 0;

  int get total => media.size;
  double get progress => total <= 0 ? 0 : (done / total).clamp(0, 1);
  bool get moving => state == XferState.offer || state == XferState.active;

  void bump(int n) {
    final now = nowMs();
    if (_markAt > 0 && now > _markAt) {
      bps = ((n - _markDone) * 1000 / (now - _markAt)).round().clamp(0, 1 << 30);
    }
    _markAt = now;
    _markDone = n;
    done = n;
  }
}

class Bcast {
  const Bcast({required this.id, required this.owner, required this.name, this.about = ''});
  final String id;
  final String owner;
  final String name;
  final String about;

  static Bcast? fromItem(Item i) {
    if (i.e.kind != K.chan) return null;
    return Bcast(
      id: i.id,
      owner: i.author,
      name: (i.body['name'] as String?) ?? 'Channel',
      about: (i.body['about'] as String?) ?? '',
    );
  }
}

class Job {
  Job({required this.id, required this.label, this.total = 0, this.done = 0, this.cancel});
  final String id;
  final String label;
  int total;
  int done;
  int bps = 0;
  void Function()? cancel;
  double get progress => total <= 0 ? 0 : (done / total).clamp(0, 1);
}

class Alert {
  const Alert({
    required this.id,
    required this.title,
    required this.body,
    this.kind = 'info',
    this.route,
    this.scope,
    this.progress,
    this.bps,
    this.cancelId,
  });
  final String id;
  final String title;
  final String body;
  final String kind;
  final String? route;
  final String? scope;
  final double? progress;
  final int? bps;
  final String? cancelId;
}

const _adjectives = [
  'quiet', 'amber', 'lucid', 'hollow', 'brisk', 'velvet', 'north', 'pale', 'swift', 'still',
  'lunar', 'woven', 'faint', 'ember', 'glass', 'mossy', 'stray', 'dusk', 'clear', 'iron',
  'sable', 'misty', 'polar', 'rapid', 'soft', 'cobalt', 'tidal', 'silent', 'opal', 'wild',
  'gentle', 'sunny'
];
const _nouns = [
  'heron', 'cedar', 'comet', 'otter', 'lantern', 'fjord', 'sparrow', 'quartz', 'harbor', 'thistle',
  'meadow', 'falcon', 'pebble', 'willow', 'ridge', 'kestrel', 'orbit', 'fern', 'delta', 'raven',
  'glacier', 'moth', 'reef', 'birch', 'signal', 'cinder', 'atlas', 'lynx', 'canyon', 'petal',
  'beacon', 'tern'
];

/// Deterministic, friendly alias derived from a key, e.g. "quiet heron".
String alias(String id) {
  if (id.length < 4) return 'unknown';
  final a = int.parse(id.substring(0, 2), radix: 16) % _adjectives.length;
  final n = int.parse(id.substring(2, 4), radix: 16) % _nouns.length;
  return '${_adjectives[a]} ${_nouns[n]}';
}

String shortId(String id) => id.length > 12 ? '${id.substring(0, 6)}…${id.substring(id.length - 4)}' : id;

/// Something that may become an operating-system notification.
class OsNote {
  const OsNote({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    required this.at,
    this.route,
    this.scope,
  });

  final String id;

  /// dm | group | mention | reply | like | follow | invite | xfer | story | channel | other
  final String category;
  final String title;
  final String body;

  /// When the underlying event happened, ms since epoch.
  final int at;
  final String? route;
  final String? scope;
}

enum StickerKind { emoji, text, link, mention, ask }

/// Something placed on a story. Position is a fraction of the story's width
/// and height so it lands in the same place on every screen.
class StorySticker {
  const StorySticker({
    required this.kind,
    required this.value,
    this.x = .5,
    this.y = .5,
    this.scale = 1,
    this.label,
  });

  static const max = 12;

  final StickerKind kind;

  /// Emoji, text, URL, mentioned node id, or the question asked.
  final String value;
  final double x;
  final double y;
  final double scale;

  /// Shown instead of the raw URL for links, or a name for mentions.
  final String? label;

  StorySticker copyWith({double? x, double? y, double? scale}) =>
      StorySticker(kind: kind, value: value, x: x ?? this.x, y: y ?? this.y, scale: scale ?? this.scale, label: label);

  Map<String, Object> toJson() => {
        't': kind.name,
        'v': value,
        'x': double.parse(x.toStringAsFixed(3)),
        'y': double.parse(y.toStringAsFixed(3)),
        if (scale != 1) 's': double.parse(scale.toStringAsFixed(2)),
        if (label != null && label!.isNotEmpty) 'l': label!,
      };

  /// Null for anything a renderer should not trust.
  static StorySticker? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = StickerKind.values.asNameMap()[j['t']];
    final v = j['v'];
    if (kind == null || v is! String || v.isEmpty || v.length > 300) return null;
    double frac(Object? n, double d) => n is num && n.isFinite ? n.toDouble().clamp(0.0, 1.0) : d;
    final s = j['s'];
    final label = j['l'];
    if (label != null && (label is! String || label.length > 80)) return null;
    switch (kind) {
      case StickerKind.emoji:
        if (v.length > 16) return null;
      case StickerKind.link:
        final u = Uri.tryParse(v);
        if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) return null;
      case StickerKind.mention:
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) return null;
      case StickerKind.text || StickerKind.ask:
        if (v.length > 200) return null;
    }
    return StorySticker(
      kind: kind,
      value: v,
      x: frac(j['x'], .5),
      y: frac(j['y'], .5),
      scale: s is num && s.isFinite ? s.toDouble().clamp(.5, 3.0) : 1,
      label: label as String?,
    );
  }

  static List<StorySticker> listFrom(Object? j) =>
      j is List ? j.map(fromJson).whereType<StorySticker>().take(max).toList() : const [];
}
