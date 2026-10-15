import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'models.dart';
import 'delivery.dart';

/// Encrypted local database (SQLite3 Multiple Ciphers, keyed per device).
/// Holds only: things this device created, and things others explicitly let
/// this device keep. Everything else lives in memory and vanishes with its author.
class Db {
  Db._(this._db, this.path);
  final Database _db;
  final String path;

  static Db open(String path, String hexKey) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hexKey)) {
      throw ArgumentError('Database key is not a 32-byte hex string');
    }
    final db = sqlite3.open(path);
    db.execute('PRAGMA busy_timeout = 8000;');
    db.execute("PRAGMA key = \"x'$hexKey'\";");
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA foreign_keys = ON;');
    db.select('SELECT count(*) FROM sqlite_master');
    final d = Db._(db, path).._migrate();
    return d;
  }

  int _userVersion() {
    final v = _db.select('PRAGMA user_version').first.values.first;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  void close() => _db.close();

  void _migrate() {
    final v = _userVersion();
    if (v < 1) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS items(
          id TEXT PRIMARY KEY, kind TEXT NOT NULL, author TEXT NOT NULL, scope TEXT NOT NULL,
          ts INTEGER NOT NULL, payload TEXT NOT NULL, sig TEXT NOT NULL,
          owned INTEGER NOT NULL DEFAULT 0, target TEXT, expires INTEGER);
        CREATE INDEX IF NOT EXISTS items_scope ON items(scope, ts);
        CREATE INDEX IF NOT EXISTS items_target ON items(target);
        CREATE INDEX IF NOT EXISTS items_author ON items(author, kind);
        CREATE INDEX IF NOT EXISTS items_kind ON items(kind, ts);
        CREATE TABLE IF NOT EXISTS peers(
          id TEXT PRIMARY KEY, nickname TEXT, last_seen INTEGER NOT NULL DEFAULT 0,
          i_follow INTEGER NOT NULL DEFAULT 0, follows_me INTEGER NOT NULL DEFAULT 0,
          blocked INTEGER NOT NULL DEFAULT 0, preserve INTEGER NOT NULL DEFAULT 0,
          addr TEXT, added INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS grants(
          scope TEXT NOT NULL, peer TEXT NOT NULL, dir TEXT NOT NULL, state TEXT NOT NULL, ts INTEGER NOT NULL,
          PRIMARY KEY(scope, peer, dir));
        CREATE TABLE IF NOT EXISTS spaces(id TEXT PRIMARY KEY, data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS files(
          hash TEXT PRIMARY KEY, name TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL,
          key TEXT NOT NULL, origin TEXT NOT NULL, scope TEXT, created INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS bookmarks(item_id TEXT PRIMARY KEY, author TEXT NOT NULL, scope TEXT NOT NULL, ts INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS receipts(
          scope TEXT NOT NULL, peer TEXT NOT NULL, delivered INTEGER NOT NULL DEFAULT 0, read INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(scope, peer));
        CREATE TABLE IF NOT EXISTS activity(
          id TEXT PRIMARY KEY, kind TEXT NOT NULL, actor TEXT NOT NULL, ref TEXT, scope TEXT, text TEXT,
          ts INTEGER NOT NULL, seen INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS chats(
          scope TEXT PRIMARY KEY, pinned INTEGER NOT NULL DEFAULT 0, muted INTEGER NOT NULL DEFAULT 0,
          archived INTEGER NOT NULL DEFAULT 0, last_read INTEGER NOT NULL DEFAULT 0, ttl INTEGER NOT NULL DEFAULT 0,
          created INTEGER NOT NULL);
        PRAGMA user_version = 1;
      ''');
    }
    if (v < 2) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS groups(id TEXT PRIMARY KEY, data TEXT NOT NULL);
        PRAGMA user_version = 2;
      ''');
    }
    if (v < 3) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS outbox(
          id TEXT PRIMARY KEY, peer TEXT NOT NULL, payload TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL);
        PRAGMA user_version = 3;
      ''');
    }
    if (v < 4) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS message_delivery(
          id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
          peer TEXT NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
          next_at INTEGER NOT NULL DEFAULT 0, error TEXT,
          PRIMARY KEY(id, peer));
        CREATE INDEX IF NOT EXISTS delivery_due ON message_delivery(state, next_at);
        CREATE TABLE IF NOT EXISTS message_read(
          id TEXT PRIMARY KEY, peer TEXT NOT NULL, scope TEXT NOT NULL, expires INTEGER);
        PRAGMA user_version = 4;
      ''');
    }
    if (v < 5) {
      _db.execute('''
        ALTER TABLE message_delivery ADD COLUMN delivered_at INTEGER;
        ALTER TABLE message_delivery ADD COLUMN read_at INTEGER;
        PRAGMA user_version = 5;
      ''');
    }
  }

  /// Copies every committed page into [destPath]. A plain file copy of a WAL
  /// database can miss the pages that still live in the `-wal` file.
  void snapshot(String destPath) {
    final dest = File(destPath);
    if (dest.existsSync()) dest.deleteSync();
    final escaped = destPath.replaceAll("'", "''");
    try {
      _db.execute("VACUUM INTO '$escaped'");
    } catch (_) {
      if (dest.existsSync()) dest.deleteSync();
      _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      File(path).copySync(destPath);
    }
  }

  void rekey(String hexKey) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hexKey)) {
      throw ArgumentError('Database key is not a 32-byte hex string');
    }
    _db.execute("PRAGMA rekey = \"x'$hexKey'\";");
  }

  // ---------- kv ----------
  String? getKv(String k) {
    final r = _db.select('SELECT v FROM kv WHERE k = ?', [k]);
    return r.isEmpty ? null : r.first['v'] as String;
  }

  void setKv(String k, String v) => _db.execute(
    'INSERT INTO kv(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v',
    [k, v],
  );

  // ---------- items ----------
  bool hasItem(String id) =>
      _db.select('SELECT 1 FROM items WHERE id = ?', [id]).isNotEmpty;

  void putItem(Envelope e, {required bool owned}) {
    _db.execute(
      'INSERT OR IGNORE INTO items(id, kind, author, scope, ts, payload, sig, owned, target, expires) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        e.id,
        e.kind,
        e.author,
        e.scope,
        e.ts,
        e.payload,
        e.sig,
        owned ? 1 : 0,
        e.target,
        e.expires,
      ],
    );
  }

  Item? _row(Row r) {
    final e = Envelope.fromParts(
      r['payload'] as String? ?? '',
      r['sig'] as String? ?? '',
    );
    if (e == null) return null;
    final owned = (r['owned'] as int? ?? 0) == 1;
    return Item(e, owned: owned, kept: !owned);
  }

  /// Newest [limit] items at or after [since], oldest of that window first.
  /// A long chat used to return the oldest rows and hide everything newer.
  List<Item> itemsInScope(String scope, {int since = 0, int limit = 2000}) =>
      _db
          .select(
            'SELECT * FROM (SELECT * FROM items WHERE scope = ? AND ts >= ? ORDER BY ts DESC LIMIT ?) ORDER BY ts ASC',
            [scope, since, limit],
          )
          .map(_row)
          .whereType<Item>()
          .toList();

  List<Item> itemsInScopes(List<String> scopes, {int limit = 2000}) {
    if (scopes.isEmpty) return [];
    final q = List.filled(scopes.length, '?').join(',');
    return _db
        .select(
          'SELECT * FROM items WHERE scope IN ($q) ORDER BY ts DESC LIMIT ?',
          [...scopes, limit],
        )
        .map(_row)
        .whereType<Item>()
        .toList();
  }

  List<Item> itemsByKind(String kind, {String? author, int limit = 500}) => _db
      .select(
        author == null
            ? 'SELECT * FROM items WHERE kind = ? ORDER BY ts DESC LIMIT ?'
            : 'SELECT * FROM items WHERE kind = ? AND author = ? ORDER BY ts DESC LIMIT ?',
        author == null ? [kind, limit] : [kind, author, limit],
      )
      .map(_row)
      .whereType<Item>()
      .toList();

  List<Item> itemsByScopePrefix(String prefix, {int limit = 5000}) => _db
      .select(
        'SELECT * FROM items WHERE scope LIKE ? ORDER BY ts ASC LIMIT ?',
        ['$prefix%', limit],
      )
      .map(_row)
      .whereType<Item>()
      .toList();

  Item? item(String id) {
    final r = _db.select('SELECT * FROM items WHERE id = ?', [id]);
    return r.isEmpty ? null : _row(r.first);
  }

  List<Item> mutationsFor(List<String> targets) {
    if (targets.isEmpty) return [];
    final q = List.filled(targets.length, '?').join(',');
    return _db
        .select(
          'SELECT * FROM items WHERE target IN ($q) ORDER BY ts ASC',
          targets,
        )
        .map(_row)
        .whereType<Item>()
        .toList();
  }

  void deleteItem(String id) => transaction(() {
    deleteOutbox(id);
    _db.execute('DELETE FROM message_read WHERE id = ?', [id]);
    _db.execute('DELETE FROM items WHERE id = ?', [id]);
  });

  /// Removes kept (not owned) items by [author] in scopes matching [scopeLike].
  int dropKept(String author, String scopeLike) {
    _db.execute(
      'DELETE FROM items WHERE owned = 0 AND author = ? AND scope LIKE ?',
      [author, scopeLike],
    );
    return _db.updatedRows;
  }

  List<String> expiredIds(int now) => _db
      .select(
        'SELECT id FROM items WHERE expires IS NOT NULL AND expires <= ?',
        [now],
      )
      .map((r) => r['id'] as String)
      .toList();

  void deleteExpired(int now) => transaction(() {
    _db.execute(
      'DELETE FROM message_read WHERE expires IS NOT NULL AND expires <= ?',
      [now],
    );
    _db.execute(
      'DELETE FROM outbox WHERE id IN (SELECT id FROM items WHERE expires IS NOT NULL AND expires <= ?)',
      [now],
    );
    _db.execute(
      'DELETE FROM items WHERE expires IS NOT NULL AND expires <= ?',
      [now],
    );
  });

  List<String> dmScopes() => _db
      .select(
        "SELECT DISTINCT scope FROM items WHERE scope LIKE 'dm:%' UNION SELECT scope FROM chats",
      )
      .map((r) => r['scope'] as String)
      .toList();

  Map<String, int> storageCounts() {
    final r = _db.select('SELECT owned, COUNT(*) c FROM items GROUP BY owned');
    final out = {'owned': 0, 'kept': 0};
    for (final row in r) {
      out[(row['owned'] as int) == 1 ? 'owned' : 'kept'] = row['c'] as int;
    }
    return out;
  }

  /// Authors whose items this device currently keeps, with counts.
  Map<String, int> keptByAuthor() => {
    for (final r in _db.select(
      'SELECT author, COUNT(*) c FROM items WHERE owned = 0 GROUP BY author',
    ))
      r['author'] as String: r['c'] as int,
  };

  // ---------- peers ----------
  Peer _peer(Row r, Profile? profile) => Peer(
    id: r['id'] as String,
    profile: profile,
    nickname: r['nickname'] as String?,
    lastSeen: r['last_seen'] as int,
    iFollow: (r['i_follow'] as int) == 1,
    followsMe: (r['follows_me'] as int) == 1,
    blocked: (r['blocked'] as int) == 1,
    preserve: (r['preserve'] as int) == 1,
    addr: r['addr'] as String?,
  );

  Profile? keptProfile(String id) {
    final r = _db.select(
      "SELECT payload, sig FROM items WHERE kind = 'profile' AND author = ? ORDER BY ts DESC LIMIT 1",
      [id],
    );
    if (r.isEmpty) return null;
    final e = Envelope.fromParts(
      r.first['payload'] as String,
      r.first['sig'] as String,
    );
    return e == null ? null : Profile.fromEnvelope(e);
  }

  Peer? peer(String id) {
    final r = _db.select('SELECT * FROM peers WHERE id = ?', [id]);
    return r.isEmpty ? null : _peer(r.first, keptProfile(id));
  }

  List<Peer> peers() =>
      _db.select('SELECT * FROM peers ORDER BY last_seen DESC').map((r) {
        return _peer(r, keptProfile(r['id'] as String));
      }).toList();

  void ensurePeer(String id) => _db.execute(
    'INSERT OR IGNORE INTO peers(id, added) VALUES(?, ?)',
    [id, nowMs()],
  );

  static const _peerCols = {
    'nickname',
    'last_seen',
    'i_follow',
    'follows_me',
    'blocked',
    'preserve',
    'addr',
    'added',
  };

  void updatePeer(String id, Map<String, Object?> fields) {
    ensurePeer(id);
    if (fields.isEmpty) return;
    for (final k in fields.keys) {
      if (!_peerCols.contains(k)) throw ArgumentError('Unknown peer column');
    }
    final sets = fields.keys.map((k) => '$k = ?').join(', ');
    _db.execute('UPDATE peers SET $sets WHERE id = ?', [...fields.values, id]);
  }

  void deletePeerProfile(String id) => _db.execute(
    "DELETE FROM items WHERE owned = 0 AND kind = 'profile' AND author = ?",
    [id],
  );

  // ---------- grants ----------
  void setGrant(String scope, String peer, GrantDir dir, GrantState? state) {
    final d = dir == GrantDir.out ? 'out' : 'in';
    if (state == null) {
      _db.execute(
        'DELETE FROM grants WHERE scope = ? AND peer = ? AND dir = ?',
        [scope, peer, d],
      );
    } else {
      _db.execute(
        'INSERT INTO grants(scope, peer, dir, state, ts) VALUES(?, ?, ?, ?, ?) '
        'ON CONFLICT(scope, peer, dir) DO UPDATE SET state = excluded.state, ts = excluded.ts',
        [scope, peer, d, state.name, nowMs()],
      );
    }
  }

  static GrantState? _grantState(String name) {
    for (final v in GrantState.values) {
      if (v.name == name) return v;
    }
    return null;
  }

  GrantState? grant(String scope, String peer, GrantDir dir) {
    final r = _db.select(
      'SELECT state FROM grants WHERE scope = ? AND peer = ? AND dir = ?',
      [scope, peer, dir == GrantDir.out ? 'out' : 'in'],
    );
    if (r.isEmpty) return null;
    return _grantState(r.first['state'] as String);
  }

  List<Grant> grants() => _db
      .select('SELECT * FROM grants ORDER BY ts DESC')
      .map(
        (r) => Grant(
          r['scope'] as String,
          r['peer'] as String,
          r['dir'] == 'out' ? GrantDir.out : GrantDir.inbound,
          _grantState(r['state'] as String) ?? GrantState.pending,
        ),
      )
      .toList();

  // ---------- spaces ----------
  List<SpaceInfo> spaces() {
    final out = <SpaceInfo>[];
    for (final r in _db.select('SELECT data FROM spaces')) {
      final s = SpaceInfo.tryParse(r['data']);
      if (s != null) out.add(s);
    }
    return out;
  }

  SpaceInfo? space(String id) {
    final r = _db.select('SELECT data FROM spaces WHERE id = ?', [id]);
    return r.isEmpty ? null : SpaceInfo.tryParse(r.first['data']);
  }

  void putSpace(SpaceInfo s) => _db.execute(
    'INSERT INTO spaces(id, data) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data',
    [s.id, jsonEncode(s.toJson())],
  );

  void deleteSpace(String id) {
    _db.execute('DELETE FROM spaces WHERE id = ?', [id]);
    _db.execute(
      "DELETE FROM items WHERE owned = 0 AND (scope LIKE ? OR scope LIKE ? OR scope LIKE ? OR scope = ?)",
      ['chan:$id:%', 'sfeed:$id%', 'forum:$id:%', 'space:$id'],
    );
  }

  // ---------- groups ----------
  List<GroupInfo> groups() {
    final out = <GroupInfo>[];
    for (final r in _db.select('SELECT data FROM groups')) {
      final g = GroupInfo.tryParse(r['data']);
      if (g != null) out.add(g);
    }
    return out;
  }

  GroupInfo? group(String id) {
    final r = _db.select('SELECT data FROM groups WHERE id = ?', [id]);
    return r.isEmpty ? null : GroupInfo.tryParse(r.first['data']);
  }

  void putGroup(GroupInfo g) => _db.execute(
    'INSERT INTO groups(id, data) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data',
    [g.id, jsonEncode(g.toJson())],
  );

  void deleteGroup(String id) {
    _db.execute('DELETE FROM groups WHERE id = ?', [id]);
    _db.execute(
      "DELETE FROM items WHERE owned = 0 AND (scope = ? OR scope = ?)",
      ['gdm:$id', 'gmeta:$id'],
    );
  }

  // ---------- files ----------
  void putFile(StoredFile f) => _db.execute(
    'INSERT INTO files(hash, name, mime, size, key, origin, scope, created) VALUES(?, ?, ?, ?, ?, ?, ?, ?) '
    "ON CONFLICT(hash) DO UPDATE SET origin = CASE WHEN files.origin = 'mine' THEN 'mine' ELSE excluded.origin END",
    [f.hash, f.name, f.mime, f.size, f.key, f.origin, f.scope, f.created],
  );

  StoredFile _file(Row r) => StoredFile(
    hash: r['hash'] as String,
    name: r['name'] as String,
    mime: r['mime'] as String,
    size: r['size'] as int,
    key: r['key'] as String,
    origin: r['origin'] as String,
    scope: r['scope'] as String?,
    created: r['created'] as int,
  );

  List<StoredFile> files() => _db
      .select('SELECT * FROM files ORDER BY created DESC')
      .map(_file)
      .toList();

  StoredFile? file(String hash) {
    final r = _db.select('SELECT * FROM files WHERE hash = ?', [hash]);
    return r.isEmpty ? null : _file(r.first);
  }

  void deleteFile(String hash) =>
      _db.execute('DELETE FROM files WHERE hash = ?', [hash]);

  /// Every blob hash still referenced by stored items.
  Set<String> referencedHashes() {
    final out = <String>{};
    for (final r in _db.select(
      "SELECT payload FROM items WHERE payload LIKE '%\"h\":%'",
    )) {
      final m = RegExp(r'"h":"([0-9a-f]{64})"')
          .allMatches(r['payload'] as String);
      out.addAll(m.map((x) => x.group(1)!));
    }
    return out;
  }

  // ---------- bookmarks ----------
  void setBookmark(Envelope e, bool on) => on
      ? _db.execute(
          'INSERT OR REPLACE INTO bookmarks(item_id, author, scope, ts) VALUES(?, ?, ?, ?)',
          [e.id, e.author, e.scope, nowMs()],
        )
      : _db.execute('DELETE FROM bookmarks WHERE item_id = ?', [e.id]);

  Set<String> bookmarkIds() => _db
      .select('SELECT item_id FROM bookmarks')
      .map((r) => r['item_id'] as String)
      .toSet();

  List<({String id, String author, String scope})> bookmarks() => _db
      .select('SELECT * FROM bookmarks ORDER BY ts DESC')
      .map(
        (r) => (
          id: r['item_id'] as String,
          author: r['author'] as String,
          scope: r['scope'] as String,
        ),
      )
      .toList();

  // ---------- receipts ----------
  void setReceipt(String scope, String peer, {int? delivered, int? read}) {
    _db.execute('INSERT OR IGNORE INTO receipts(scope, peer) VALUES(?, ?)', [
      scope,
      peer,
    ]);
    if (delivered != null) {
      _db.execute(
        'UPDATE receipts SET delivered = MAX(delivered, ?) WHERE scope = ? AND peer = ?',
        [delivered, scope, peer],
      );
    }
    if (read != null) {
      _db.execute(
        'UPDATE receipts SET read = MAX(read, ?), delivered = MAX(delivered, ?) WHERE scope = ? AND peer = ?',
        [read, read, scope, peer],
      );
    }
  }

  ({int delivered, int read}) receipt(String scope, String peer) {
    final r = _db.select(
      'SELECT delivered, read FROM receipts WHERE scope = ? AND peer = ?',
      [scope, peer],
    );
    if (r.isEmpty) return (delivered: 0, read: 0);
    return (
      delivered: r.first['delivered'] as int,
      read: r.first['read'] as int,
    );
  }

  // ---------- activity ----------
  void addActivity(Activity a) => _db.execute(
    'INSERT OR IGNORE INTO activity(id, kind, actor, ref, scope, text, ts) VALUES(?, ?, ?, ?, ?, ?, ?)',
    [a.id, a.kind, a.actor, a.ref, a.scope, a.text, a.ts],
  );

  List<Activity> activity({int limit = 200}) => _db
      .select('SELECT * FROM activity ORDER BY ts DESC LIMIT ?', [limit])
      .map(
        (r) => Activity(
          id: r['id'] as String,
          kind: r['kind'] as String,
          actor: r['actor'] as String,
          ref: r['ref'] as String?,
          scope: r['scope'] as String?,
          text: r['text'] as String?,
          ts: r['ts'] as int,
          seen: (r['seen'] as int) == 1,
        ),
      )
      .toList();

  int unseenActivity() =>
      _db.select('SELECT COUNT(*) c FROM activity WHERE seen = 0').first['c']
          as int;
  void markActivitySeen() =>
      _db.execute('UPDATE activity SET seen = 1 WHERE seen = 0');
  void clearActivity() => _db.execute('DELETE FROM activity');

  // ---------- chats ----------
  void ensureChat(String scope, {int defaultTtl = 0}) {
    final exists = _db.select('SELECT 1 FROM chats WHERE scope = ?', [
      scope,
    ]).isNotEmpty;
    _db.execute('INSERT OR IGNORE INTO chats(scope, created) VALUES(?, ?)', [
      scope,
      nowMs(),
    ]);
    if (!exists && defaultTtl > 0) {
      _db.execute('UPDATE chats SET ttl = ? WHERE scope = ?', [
        defaultTtl,
        scope,
      ]);
    }
  }

  Map<String, Object?> chat(String scope) {
    final r = _db.select('SELECT * FROM chats WHERE scope = ?', [scope]);
    if (r.isEmpty) {
      return {'pinned': 0, 'muted': 0, 'archived': 0, 'last_read': 0, 'ttl': 0};
    }
    return Map.of(r.first);
  }

  static const _chatCols = {'pinned', 'muted', 'archived', 'last_read', 'ttl'};

  void updateChat(String scope, Map<String, Object?> fields) {
    ensureChat(scope);
    if (fields.isEmpty) return;
    for (final k in fields.keys) {
      if (!_chatCols.contains(k)) throw ArgumentError('Unknown chat column');
    }
    final sets = fields.keys.map((k) => '$k = ?').join(', ');
    _db.execute('UPDATE chats SET $sets WHERE scope = ?', [
      ...fields.values,
      scope,
    ]);
  }

  void deleteChat(String scope) {
    _db.execute('DELETE FROM message_read WHERE scope = ?', [scope]);
    _db.execute(
      'DELETE FROM outbox WHERE id IN (SELECT id FROM items WHERE scope = ?)',
      [scope],
    );
    _db.execute('DELETE FROM items WHERE scope = ?', [scope]);
    _db.execute('DELETE FROM chats WHERE scope = ?', [scope]);
    _db.execute('DELETE FROM receipts WHERE scope = ?', [scope]);
  }

  void wipe() {
    for (final t in [
      'message_delivery',
      'message_read',
      'kv',
      'items',
      'peers',
      'grants',
      'spaces',
      'groups',
      'files',
      'bookmarks',
      'receipts',
      'activity',
      'chats',
      'outbox',
    ]) {
      _db.execute('DELETE FROM $t');
    }
  }

  void enqueueOutbox(String id, String peer, String payload) => _db.execute(
    'INSERT INTO outbox(id, peer, payload, attempts, failed, next_at) VALUES(?, ?, ?, 0, 0, ?) '
    'ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, failed = 0, next_at = excluded.next_at',
    [id, peer, payload, nowMs()],
  );

  List<({String id, String peer, String payload, int attempts, bool failed})>
  dueOutbox(int now) => _db
      .select(
        'SELECT * FROM outbox WHERE failed = 0 AND next_at <= ? ORDER BY next_at ASC LIMIT 40',
        [now],
      )
      .map(
        (r) => (
          id: r['id'] as String,
          peer: r['peer'] as String,
          payload: r['payload'] as String,
          attempts: r['attempts'] as int,
          failed: r['failed'] == 1,
        ),
      )
      .toList();

  Set<String> outboxIds() => _db
      .select('SELECT id, failed FROM outbox')
      .map((r) => r['id'] as String)
      .toSet();

  Set<String> failedOutbox() => _db
      .select('SELECT id FROM outbox WHERE failed = 1')
      .map((r) => r['id'] as String)
      .toSet();

  void bumpOutbox(String id, {required bool failed}) => _db.execute(
    'UPDATE outbox SET attempts = attempts + 1, failed = ?, next_at = ? WHERE id = ?',
    [failed ? 1 : 0, nowMs() + (failed ? 3600000 : 15000), id],
  );

  void deleteOutbox(String id) =>
      _db.execute('DELETE FROM outbox WHERE id = ?', [id]);

  void retryOutbox(String id) => _db.execute(
    'UPDATE outbox SET failed = 0, attempts = 0, next_at = ? WHERE id = ?',
    [nowMs(), id],
  );

  void reviveOutbox(String peer) => _db.execute(
    'UPDATE outbox SET failed = 0, next_at = ? WHERE peer = ?',
    [nowMs(), peer],
  );

  // A message and its recipient snapshot are committed together. A crash can
  // never leave a visible new message with no durable send job.
  void transaction(void Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      action();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void queueMessage(Envelope e, Iterable<String> recipients) => transaction(() {
    putItem(e, owned: true);
    final peers = recipients.toSet();
    for (final peer in peers.isEmpty ? [e.author] : peers) {
      _db.execute(
        'INSERT OR IGNORE INTO message_delivery(id, peer, state, next_at) VALUES(?, ?, ?, ?)',
        [e.id, peer, peers.isEmpty ? 'saved' : 'queued', nowMs()],
      );
    }
    deleteOutbox(e.id);
  });

  RecipientDelivery? _delivery(Row r) {
    try {
      final name = r['state'];
      if (name is! String) return null;
      final state = Delivery.values.asNameMap()[name];
      if (state == null) return null;
      final id = r['id'];
      final peer = r['peer'];
      if (id is! String || peer is! String) return null;
      return RecipientDelivery(
        id: id,
        peer: peer,
        state: state,
        attempts: r['attempts'] is num ? (r['attempts'] as num).toInt() : 0,
        nextAt: r['next_at'] is num ? (r['next_at'] as num).toInt() : 0,
        error: r['error'] is String ? r['error'] as String : null,
        deliveredAt: r['delivered_at'] is num ? (r['delivered_at'] as num).toInt() : null,
        readAt: r['read_at'] is num ? (r['read_at'] as num).toInt() : null,
      );
    } catch (_) {
      return null;
    }
  }

  List<RecipientDelivery> deliveries(String id) => _db
      .select('SELECT * FROM message_delivery WHERE id = ? ORDER BY peer', [id])
      .map(_delivery)
      .whereType<RecipientDelivery>()
      .toList();

  Map<String, List<RecipientDelivery>> deliveriesInScope(String scope) {
    final result = <String, List<RecipientDelivery>>{};
    for (final row in _db.select(
      'SELECT d.* FROM message_delivery d JOIN items i ON i.id = d.id WHERE i.scope = ?',
      [scope],
    )) {
      final d = _delivery(row);
      if (d == null) continue;
      result.putIfAbsent(d.id, () => []).add(d);
    }
    return result;
  }

  List<RecipientDelivery> dueDeliveries(int now) => _db
      .select(
        "SELECT d.* FROM message_delivery d JOIN items i ON i.id = d.id "
        "WHERE d.state IN ('queued', 'sent') AND d.next_at <= ? AND (i.expires IS NULL OR i.expires > ?) "
        'ORDER BY d.next_at, i.ts, d.id, d.peer LIMIT 32',
        [now, now],
      )
      .map(_delivery)
      .whereType<RecipientDelivery>()
      .toList();

  bool beginDelivery(RecipientDelivery job) {
    _db.execute(
      "UPDATE message_delivery SET state = 'sending', attempts = attempts + 1 "
      "WHERE id = ? AND peer = ? AND state IN ('queued', 'sent') AND attempts = ?",
      [job.id, job.peer, job.attempts],
    );
    return _db.updatedRows == 1;
  }

  void finishDelivery(RecipientDelivery job, {required bool sent}) {
    final attempts = job.attempts + 1;
    final failed = attempts >= 6;
    final delay = (5 * (1 << attempts.clamp(0, 6))).clamp(10, 300);
    _db.execute(
      "UPDATE message_delivery SET state = ?, next_at = ?, error = ? "
      "WHERE id = ? AND peer = ? AND state = 'sending' AND attempts = ?",
      [
        failed ? 'failed' : (sent ? 'sent' : 'queued'),
        nowMs() + delay * 1000,
        sent
            ? 'Waiting for the recipient to confirm receipt.'
            : 'Could not reach the recipient. Check your connection.',
        job.id,
        job.peer,
        attempts,
      ],
    );
  }

  void acknowledgeMessage(
    String id,
    String peer,
    String scope, {
    bool read = false,
  }) {
    // Peer comes from the authenticated direct transport, never from the body.
    // Late receipts may upgrade cancelled jobs: cancellation cannot unsend bytes.
    final now = nowMs();
    _db.execute(
      "UPDATE message_delivery SET state = ?, error = NULL, "
      'delivered_at = COALESCE(delivered_at, ?), read_at = CASE WHEN ? THEN COALESCE(read_at, ?) ELSE read_at END '
      "WHERE id = ? AND peer = ? AND state != 'saved' AND state != 'read' "
      'AND EXISTS(SELECT 1 FROM items WHERE id = ? AND scope = ? AND owned = 1)',
      [read ? 'read' : 'delivered', now, read ? 1 : 0, now, id, peer, id, scope],
    );
  }

  void recoverDeliveries() => _db.execute(
    "UPDATE message_delivery SET state = CASE WHEN state = 'sending' THEN 'queued' ELSE state END, next_at = 0 "
    "WHERE state IN ('queued', 'sending', 'sent')",
  );

  void reviveDeliveries(String peer) => _db.execute(
    "UPDATE message_delivery SET state = 'queued', attempts = 0, next_at = 0, error = NULL "
    "WHERE peer = ? AND state IN ('queued', 'sent', 'failed')",
    [peer],
  );

  void retryDeliveries(String id) => _db.execute(
    "UPDATE message_delivery SET state = 'queued', attempts = 0, next_at = 0, error = NULL "
    "WHERE id = ? AND state IN ('failed', 'cancelled')",
    [id],
  );

  void cancelDeliveries(String id) => _db.execute(
    "UPDATE message_delivery SET state = 'cancelled', error = NULL "
    "WHERE id = ? AND state IN ('queued', 'sending', 'sent', 'failed')",
    [id],
  );

  void failDelivery(String id, String peer, String reason) => _db.execute(
    "UPDATE message_delivery SET state = 'cancelled', error = ? "
    "WHERE id = ? AND peer = ? AND state IN ('queued', 'sent')",
    [reason, id, peer],
  );

  List<Item> legacyQueuedMessages() => _db
      .select(
        "SELECT i.* FROM items i JOIN outbox o ON o.id = i.id WHERE i.kind = 'msg' AND i.owned = 1",
      )
      .map(_row)
      .whereType<Item>()
      .toList();

  bool wasMessageRead(String id) =>
      _db.select('SELECT 1 FROM message_read WHERE id = ?', [id]).isNotEmpty;

  void recordMessageRead(Envelope e) => _db.execute(
    'INSERT OR IGNORE INTO message_read(id, peer, scope, expires) VALUES(?, ?, ?, ?)',
    [e.id, e.author, e.scope, e.expires],
  );

  // ---------- explorer ----------

  /// Tables the data explorer may list. Fixed so a table name never comes
  /// from user input.
  static const explorable = [
    'items', 'peers', 'grants', 'spaces', 'groups', 'files', 'bookmarks', 'receipts',
    'activity', 'chats', 'outbox', 'message_delivery', 'message_read', 'kv',
  ];

  Map<String, int> tableCounts() => {
    for (final t in explorable)
      t: _db.select('SELECT COUNT(*) c FROM $t').first['c'] as int,
  };

  /// Per kind: how many items, how many created here, and their signed size.
  List<({String kind, int count, int owned, int bytes})> kindStats() => _db
      .select(
        'SELECT kind, COUNT(*) c, SUM(owned) o, SUM(LENGTH(payload) + LENGTH(sig)) b '
        'FROM items GROUP BY kind ORDER BY c DESC',
      )
      .map((r) => (
            kind: r['kind'] as String,
            count: r['c'] as int,
            owned: (r['o'] as int?) ?? 0,
            bytes: (r['b'] as int?) ?? 0,
          ))
      .toList();

  List<({String scope, int count, int bytes, int last})> scopeStats({String? kind, int limit = 300}) => _db
      .select(
        'SELECT scope, COUNT(*) c, SUM(LENGTH(payload) + LENGTH(sig)) b, MAX(ts) t FROM items '
        '${kind == null ? '' : 'WHERE kind = ? '}GROUP BY scope ORDER BY t DESC LIMIT ?',
        [?kind, limit],
      )
      .map((r) => (
            scope: r['scope'] as String,
            count: r['c'] as int,
            bytes: (r['b'] as int?) ?? 0,
            last: (r['t'] as int?) ?? 0,
          ))
      .toList();

  /// Newest-first page of stored items. [before] is the previous page's last
  /// (ts, id) so pages stay stable while new items arrive.
  List<Item> browseItems({
    String? kind,
    String? scope,
    String? author,
    bool? owned,
    String? query,
    ({int ts, String id})? before,
    int limit = 100,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    if (kind != null) {
      where.add('kind = ?');
      args.add(kind);
    }
    if (scope != null) {
      where.add('scope = ?');
      args.add(scope);
    }
    if (author != null) {
      where.add('author = ?');
      args.add(author);
    }
    if (owned != null) {
      where.add('owned = ?');
      args.add(owned ? 1 : 0);
    }
    final q = query?.trim() ?? '';
    if (q.isNotEmpty) {
      where.add("(payload LIKE ? ESCAPE '\\' OR id = ?)");
      args.add('%${q.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%');
      args.add(q);
    }
    if (before != null) {
      where.add('(ts < ? OR (ts = ? AND id < ?))');
      args.addAll([before.ts, before.ts, before.id]);
    }
    args.add(limit.clamp(1, 1000));
    return _db
        .select(
          'SELECT * FROM items ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
          'ORDER BY ts DESC, id DESC LIMIT ?',
          args,
        )
        .map(_row)
        .whereType<Item>()
        .toList();
  }

  /// Raw rows of an explorable table, newest rowid first.
  List<Map<String, Object?>> tableRows(String table, {int limit = 200, int offset = 0}) {
    if (!explorable.contains(table)) throw ArgumentError.value(table, 'table');
    return _db
        .select('SELECT * FROM $table ORDER BY rowid DESC LIMIT ? OFFSET ?', [limit, offset])
        .map((r) => {for (final c in r.keys) c: r[c]})
        .toList();
  }

  /// Bytes used by the database file and its write-ahead log.
  int fileBytes() {
    var n = 0;
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$path$suffix');
      if (f.existsSync()) n += f.lengthSync();
    }
    return n;
  }
}
