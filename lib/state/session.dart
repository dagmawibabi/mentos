import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/crypto/crypto.dart';
import '../data/db.dart';
import '../data/keys.dart';
import '../data/media_store.dart';
import '../net/engine.dart';
import '../net/transport.dart';
import '../net/transport_factory.dart';
import 'settings.dart';

sealed class Session {
  const Session();
}

class SessionLoading extends Session {
  const SessionLoading();
}

class SessionSignedOut extends Session {
  const SessionSignedOut();
}

class SessionReady extends Session {
  const SessionReady(this.engine);
  final Engine engine;
}

class SessionError extends Session {
  const SessionError(this.message);
  final String message;
}

class SessionNotifier extends Notifier<Session> {
  Engine? _engine;
  KeyVault? _keys;

  @override
  Session build() {
    _boot();
    return const SessionLoading();
  }

  Future<void> _boot() async {
    await Future<void>.delayed(Duration.zero);
    try {
      final keys = await KeyVault.open(await _root());
      _keys = keys;
      final seedHex = await keys.read('seed');
      if (seedHex == null) {
        state = const SessionSignedOut();
        return;
      }
      await _open(await Identity.fromSeed(fromHex(seedHex)));
    } catch (e, st) {
      state = SessionError('$e');
      assert(() {
        debugPrint('session boot failed: $e\n$st');
        return true;
      }());
    }
  }

  Future<String> _root() async {
    final dest = await _dataDir();
    await dest.create(recursive: true);
    await _migrateFrom(await _legacyDir(), dest);
    return dest.path;
  }

  /// AppData on C: is often too small on this machine. Prefer MENTOS_HOME,
  /// then D:\mentos on Windows when that drive exists.
  Future<Directory> _dataDir() async {
    final override = Platform.environment['MENTOS_HOME']?.trim();
    if (override != null && override.isNotEmpty) return Directory(override);
    if (Platform.isWindows && Directory(r'D:\').existsSync()) {
      return Directory(r'D:\mentos');
    }
    return _legacyDir();
  }

  Future<Directory> _legacyDir() async {
    final dir = await getApplicationSupportDirectory();
    return Directory(p.join(dir.path, 'mentos'));
  }

  Future<void> _migrateFrom(Directory from, Directory to) async {
    if (!from.existsSync()) return;
    if (p.equals(p.normalize(from.absolute.path), p.normalize(to.absolute.path))) return;
    final marker = File(p.join(to.path, '.migrated'));
    if (marker.existsSync()) return;
    final srcKeys = File(p.join(from.path, 'keys.json'));
    final srcIdentity = File(p.join(from.path, 'identity.json'));
    if (!srcKeys.existsSync() && !srcIdentity.existsSync()) return;
    await to.create(recursive: true);
    final destBusy = File(p.join(to.path, 'identity.json')).existsSync() ||
        File(p.join(to.path, 'keys.json')).existsSync() ||
        File(p.join(to.path, 'mentos.db')).existsSync();
    if (destBusy) {
      await marker.writeAsString('skipped');
      return;
    }
    await for (final e in from.list(recursive: true, followLinks: false)) {
      final rel = p.relative(e.path, from: from.path);
      final dest = p.join(to.path, rel);
      if (e is Directory) {
        await Directory(dest).create(recursive: true);
      } else if (e is File) {
        await Directory(p.dirname(dest)).create(recursive: true);
        await e.copy(dest);
      }
    }
    await marker.writeAsString('ok');
    try {
      await from.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _open(Identity me) async {
    final root = await _root();
    final keys = _keys ?? await KeyVault.open(root);
    _keys = keys;
    final db = await _openDb(p.join(root, 'mentos.db'), me, keys);
    final Transport net = createTransport();
    final media = MediaStore(root, db, net);
    final engine = Engine(
      me: me,
      db: db,
      net: net,
      media: media,
      settings: Settings.decode(db.getKv('settings')),
    );
    try {
      await media.init();
    } catch (_) {}
    try {
      await engine.start(p.join(root, 'node'));
    } catch (e) {
      engine.noteStartError('$e');
    }
    _engine = engine;
    state = SessionReady(engine);
  }

  /// Creates or restores an identity and opens the app.
  Future<void> signIn(Identity me, {String? name}) async {
    try {
      final keys = _keys ?? await KeyVault.open(await _root());
      _keys = keys;
      await keys.write('seed', toHex(me.seed));
      state = const SessionLoading();
      await _open(me);
      if (name != null && name.trim().isNotEmpty) {
        await _engine!.updateProfile(name: name, bio: '');
      }
    } catch (e) {
      state = SessionError('$e');
    }
  }

  Future<Db> _openDb(String dbPath, Identity me, KeyVault keys) async {
    final derived = dbKeyFor(me.seed);
    final stored = await keys.read('dbkey');
    if (stored == null || stored == derived) {
      final db = Db.open(dbPath, derived);
      if (stored == null) await keys.write('dbkey', derived);
      return db;
    }
    Db? opened;
    try {
      opened = Db.open(dbPath, stored);
      opened.rekey(derived);
      await keys.write('dbkey', derived);
      return opened;
    } catch (e) {
      opened?.close();
      try {
        final db = Db.open(dbPath, derived);
        await keys.write('dbkey', derived);
        return db;
      } catch (_) {
        throw StateError('Could not open encrypted storage: $e');
      }
    }
  }

  /// Writes the encrypted database and blobs to [folder]. The recovery phrase
  /// is what opens them. The seed file is not copied.
  Future<void> exportVault(String folder) async {
    final engine = _engine;
    if (engine == null) throw StateError('Nothing to export yet.');
    final root = Directory(await _root());
    final dest = Directory(folder);
    await dest.create(recursive: true);
    final snap = p.join(dest.path, 'mentos.db');
    final partial = '$snap.partial';
    engine.db.snapshot(partial);
    final snapFile = File(snap);
    if (await snapFile.exists()) await snapFile.delete();
    await File(partial).rename(snap);
    final blobs = Directory(p.join(root.path, 'blobs'));
    if (await blobs.exists()) {
      final out = Directory(p.join(dest.path, 'blobs'));
      await out.create(recursive: true);
      await for (final e in blobs.list()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(name)) continue;
        await e.copy(p.join(out.path, name));
      }
    }
  }

  /// Copies a previously exported vault (database and blobs) into this
  /// device's store so the recovery phrase can open those chats and files.
  Future<void> importVault(String folder, Identity me) async {
    if (_engine != null) {
      throw StateError('Sign out before restoring a vault.');
    }
    final src = Directory(folder);
    final dbSrc = File(p.join(src.path, 'mentos.db'));
    if (!await dbSrc.exists()) throw StateError('That folder has no Mentos database.');
    final dest = Directory(await _root());
    await dest.create(recursive: true);
    final stage = p.join(dest.path, 'mentos.db.incoming');
    await _deleteDbFiles(stage);
    await dbSrc.copy(stage);
    for (final suffix in ['-wal', '-shm']) {
      final extra = File('${dbSrc.path}$suffix');
      if (await extra.exists()) await extra.copy('$stage$suffix');
    }
    final key = dbKeyFor(me.seed);
    Db? probe;
    try {
      probe = Db.open(stage, key);
    } catch (_) {
      probe?.close();
      await _deleteDbFiles(stage);
      throw StateError('That vault does not open with this recovery phrase.');
    }
    probe.close();
    final live = p.join(dest.path, 'mentos.db');
    await _deleteDbFiles(live);
    await File(stage).rename(live);
    for (final suffix in ['-wal', '-shm']) {
      final extra = File('$stage$suffix');
      if (await extra.exists()) await extra.rename('$live$suffix');
    }
    final blobs = Directory(p.join(src.path, 'blobs'));
    if (await blobs.exists()) {
      final out = Directory(p.join(dest.path, 'blobs'));
      await out.create(recursive: true);
      await for (final e in blobs.list()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(name)) continue;
        await e.copy(p.join(out.path, name));
      }
    }
  }

  /// Erases the identity and every byte this app stored.
  /// Refuses to delete a directory that does not look like this app's store.
  Future<void> wipe() async {
    final e = _engine;
    _engine = null;
    state = const SessionLoading();
    if (e != null) {
      await e.stop();
      e.db.close();
    }
    final root = Directory(await _root());
    final owned = root.existsSync() && _ownedStore(root);
    await _keys?.deleteAll();
    _keys = null;
    if (root.existsSync() && owned) {
      const names = [
        'mentos.db',
        'mentos.db-wal',
        'mentos.db-shm',
        'identity.json',
        'db.key',
        'keys.json',
        'identity.json.tmp',
        'db.key.tmp',
        'keys.json.tmp',
        '.migrated',
      ];
      for (final name in names) {
        final f = File(p.join(root.path, name));
        if (f.existsSync()) await f.delete();
      }
      for (final name in ['blobs', 'view', 'node', 'tmp']) {
        final d = Directory(p.join(root.path, name));
        if (d.existsSync()) await d.delete(recursive: true);
      }
    }
    state = const SessionSignedOut();
  }

  Future<void> _deleteDbFiles(String path) async {
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$path$suffix');
      if (await f.exists()) await f.delete();
    }
  }

  /// True when [root] is this app's store and not a drive root.
  bool _ownedStore(Directory root) {
    final norm = p.normalize(root.absolute.path);
    if (norm == p.separator || RegExp(r'^[A-Za-z]:\\?$').hasMatch(norm)) return false;
    return File(p.join(root.path, 'mentos.db')).existsSync() ||
        File(p.join(root.path, 'identity.json')).existsSync() ||
        File(p.join(root.path, 'keys.json')).existsSync() ||
        File(p.join(root.path, 'db.key')).existsSync();
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, Session>(SessionNotifier.new);
