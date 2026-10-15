import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/crypto/crypto.dart';

/// Restrict a secret file to the current user. Fails soft if the OS refuses.
Future<void> lockDown(File file) async {
  try {
    if (!await file.exists()) return;
    if (Platform.isWindows) {
      final user = Platform.environment['USERNAME'];
      if (user == null || user.isEmpty) return;
      await Process.run('icacls', [file.path, '/inheritance:r', '/grant:r', '$user:F']);
    } else {
      await Process.run('chmod', ['600', file.path]);
    }
  } catch (_) {}
}

/// Identity and the database key live in separate files. Each write lands in
/// a temp file and is renamed, so a crash mid-write cannot blank both secrets.
class KeyVault {
  KeyVault(this._root);

  final String _root;
  Map<String, String> _mem = {};
  bool _loaded = false;

  File get _legacy => File(p.join(_root, 'keys.json'));
  File get _identity => File(p.join(_root, 'identity.json'));
  File get _dbKey => File(p.join(_root, 'db.key'));

  static Future<KeyVault> open(String root) async {
    final v = KeyVault(root);
    await v._load();
    return v;
  }

  Future<File?> _recover(File dest) async {
    if (await dest.exists()) return dest;
    final bak = File('${dest.path}.bak');
    final tmp = File('${dest.path}.tmp');
    if (await bak.exists()) {
      await bak.rename(dest.path);
      return dest;
    }
    if (await tmp.exists()) {
      await tmp.rename(dest.path);
      return dest;
    }
    return null;
  }

  Future<void> _load() async {
    if (_loaded) return;
    await _recover(_identity);
    await _recover(_dbKey);
    if (await _identity.exists()) {
      final m = jsonDecode(await _identity.readAsString());
      if (m is! Map || m['seed'] is! String) {
        throw StateError('Identity file is unreadable. Refusing to continue so a new identity is not created over the old one.');
      }
      _mem['seed'] = m['seed'] as String;
    } else if (await _legacy.exists()) {
      try {
        final m = jsonDecode(await _legacy.readAsString());
        if (m is! Map) throw StateError('bad keys');
        _mem = {for (final e in m.entries) e.key.toString(): e.value.toString()};
      } catch (_) {
        throw StateError('Key file is unreadable. Refusing to continue so a new identity is not created over the old one.');
      }
      if (_mem['seed'] != null) await _writeIdentity(_mem['seed']!);
    }
    if (await _dbKey.exists()) {
      _mem['dbkey'] = (await _dbKey.readAsString()).trim();
    }
    _loaded = true;
  }

  Future<void> _atomic(File dest, String contents) async {
    final tmp = File('${dest.path}.tmp');
    final bak = File('${dest.path}.bak');
    await dest.parent.create(recursive: true);
    await tmp.writeAsString(contents, flush: true);
    await lockDown(tmp);
    if (await bak.exists()) await bak.delete();
    if (await dest.exists()) await dest.rename(bak.path);
    try {
      await tmp.rename(dest.path);
    } catch (e) {
      if (!await dest.exists() && await bak.exists()) {
        await bak.rename(dest.path);
      }
      rethrow;
    }
    if (await bak.exists()) await bak.delete();
    await lockDown(dest);
  }

  Future<void> _writeIdentity(String seed) => _atomic(_identity, jsonEncode({'seed': seed}));

  Future<String?> read(String key) async {
    await _load();
    return _mem[key];
  }

  Future<void> write(String key, String value) async {
    await _load();
    _mem[key] = value;
    if (key == 'seed') {
      await _writeIdentity(value);
    } else if (key == 'dbkey') {
      await _atomic(_dbKey, value);
    } else {
      await _atomic(_legacy, jsonEncode(_mem));
    }
  }

  Future<void> deleteAll() async {
    _mem = {};
    for (final f in [
      _legacy,
      _identity,
      _dbKey,
      File('${_identity.path}.tmp'),
      File('${_dbKey.path}.tmp'),
      File('${_identity.path}.bak'),
      File('${_dbKey.path}.bak'),
    ]) {
      if (await f.exists()) await f.delete();
    }
  }
}

/// Database key derived from the identity seed, so the recovery phrase opens
/// the same chats and files.
String dbKeyFor(Uint8List seed) => toHex(sha256([...seed, ...'mentos-db-v1'.codeUnits]));
