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
import 'accounts.dart';
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

  /// The store root shared by every account on this device.
  Future<String> _base() async {
    final dest = await _dataDir();
    await dest.create(recursive: true);
    await _migrateFrom(await _legacyDir(), dest);
    return dest.path;
  }

  Future<AccountRegistry> _registry() async => AccountRegistry(await _base());

  /// The folder of the account that is open (or being created).
  Future<String> _root() async {
    final dir = (await _registry()).activeDir();
    await Directory(dir).create(recursive: true);
    return dir;
  }

  /// Accounts on this device, with the open one's name kept current.
  Future<({List<AccountEntry> accounts, String active})> accounts() async {
    final reg = await _registry();
    final e = _engine;
    if (e != null) reg.update(reg.load().active, id: e.me.id, name: e.myProfile.displayName);
    return reg.load();
  }

  Future<void> _close() async {
    final e = _engine;
    _engine = null;
    _keys = null;
    if (e == null) return;
    try {
      final reg = await _registry();
      reg.update(reg.load().active, id: e.me.id, name: e.myProfile.displayName);
    } catch (_) {}
    await e.stop();
    e.db.close();
  }

  /// Closes this account and opens another one on this device.
  Future<void> switchAccount(String dir) async {
    state = const SessionLoading();
    await _close();
    (await _registry()).setActive(dir);
    await _boot();
  }

  /// Closes this account and starts onboarding in a fresh, separate folder.
  Future<void> addAccount() async {
    state = const SessionLoading();
    await _close();
    (await _registry()).addNew();
    state = const SessionSignedOut();
  }

  /// The account the onboarding screen can go back to instead of creating
  /// one, when this is an added account that never got an identity.
  Future<AccountEntry?> returnTarget() async {
    final reg = await _registry();
    final s = reg.load();
    final active = s.accounts.firstWhere((a) => a.dir == s.active, orElse: () => AccountEntry(dir: s.active));
    if (active.id.isNotEmpty || _engine != null) return null;
    return reg.previousOf(s.active);
  }

  /// Abandons an unfinished new account and reopens [to].
  Future<void> cancelAddAccount(AccountEntry to) async {
    final reg = await _registry();
    final abandoned = reg.load().active;
    state = const SessionLoading();
    reg.setActive(to.dir);
    if (abandoned != '.') reg.remove(abandoned);
    await _boot();
  }

  /// Erases another account on this device. The open one is erased with [wipe].
  Future<void> removeAccount(String dir) async {
    final reg = await _registry();
    if (reg.load().active == dir) throw StateError('Switch away before removing this account.');
    if (dir == '.') {
      await _wipeFolder(Directory(reg.dirOf('.')), primary: true);
    }
    reg.remove(dir);
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
    try {
      final reg = await _registry();
      reg.update(reg.load().active, id: me.id, name: engine.myProfile.displayName);
    } catch (_) {}
    state = SessionReady(engine);
  }

  /// Creates or restores an identity and opens the app.
  Future<void> signIn(Identity me, {String? name}) async {
    try {
      // The same recovery phrase twice on one device would run two copies of
      // one node; open the existing account instead.
      final reg = await _registry();
      final current = reg.load();
      final existing = current.accounts.where((a) => a.id == me.id && a.dir != current.active).firstOrNull;
      if (existing != null) {
        await cancelAddAccount(existing);
        return;
      }
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

  /// Erases the open identity and every byte stored for it. Other accounts
  /// on this device are left alone, and the most recent one opens next.
  /// Refuses to delete a directory that does not look like this app's store.
  Future<void> wipe() async {
    state = const SessionLoading();
    final keys = _keys;
    final e = _engine;
    _engine = null;
    _keys = null;
    if (e != null) {
      await e.stop();
      e.db.close();
    }
    await keys?.deleteAll();
    final reg = await _registry();
    final active = reg.load().active;
    final root = Directory(reg.dirOf(active));
    await _wipeFolder(root, primary: active == '.');
    final next = reg.previousOf(active);
    reg.remove(active);
    if (next != null) {
      reg.setActive(next.dir);
      await _boot();
      return;
    }
    state = const SessionSignedOut();
  }

  /// Deletes one account's files. For the primary account only the known
  /// file names are removed, since other accounts live inside its folder.
  Future<void> _wipeFolder(Directory root, {required bool primary}) async {
    final owned = root.existsSync() && _ownedStore(root);
    if (primary && root.existsSync()) {
      try {
        await (await KeyVault.open(root.path)).deleteAll();
      } catch (_) {}
    }
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
