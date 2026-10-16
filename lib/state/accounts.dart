import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/crypto/crypto.dart';

/// One identity on this device. The first account lives at the store root
/// (`dir == '.'`) so installs from before multi-account keep working; later
/// ones get their own folder under `accounts/`, each with its own keys,
/// encrypted database and blobs.
class AccountEntry {
  const AccountEntry({required this.dir, this.id = '', this.name = '', this.added = 0, this.lastUsed = 0});

  final String dir;

  /// Node id once known; empty for an account still being created.
  final String id;
  final String name;
  final int added;
  final int lastUsed;

  bool get primary => dir == '.';

  AccountEntry copyWith({String? id, String? name, int? lastUsed}) =>
      AccountEntry(dir: dir, id: id ?? this.id, name: name ?? this.name, added: added, lastUsed: lastUsed ?? this.lastUsed);

  Map<String, Object> toJson() => {'dir': dir, 'id': id, 'name': name, 'added': added, 'used': lastUsed};

  static AccountEntry? fromJson(Object? j) {
    if (j is! Map || j['dir'] is! String) return null;
    final dir = j['dir'] as String;
    if (!AccountRegistry.validDir(dir)) return null;
    int n(Object? v) => v is num ? v.toInt() : 0;
    return AccountEntry(
      dir: dir,
      id: j['id'] is String ? j['id'] as String : '',
      name: j['name'] is String ? j['name'] as String : '',
      added: n(j['added']),
      lastUsed: n(j['used']),
    );
  }
}

/// The list of accounts and which one is open, in `accounts.json` at the
/// store root. Never holds secrets.
class AccountRegistry {
  AccountRegistry(this.base);

  final String base;

  File get _file => File(p.join(base, 'accounts.json'));

  static bool validDir(String dir) => dir == '.' || RegExp(r'^accounts/[0-9a-f]{16}$').hasMatch(dir);

  ({List<AccountEntry> accounts, String active}) load() {
    try {
      if (_file.existsSync()) {
        final m = jsonDecode(_file.readAsStringSync()) as Map;
        final list = [for (final a in (m['accounts'] as List? ?? const [])) ?AccountEntry.fromJson(a)];
        final seen = <String>{};
        final unique = [for (final a in list) if (seen.add(a.dir)) a];
        if (unique.isNotEmpty) {
          final active = m['active'] is String && unique.any((a) => a.dir == m['active']) ? m['active'] as String : unique.first.dir;
          return (accounts: unique, active: active);
        }
      }
    } catch (_) {}
    return (accounts: const [AccountEntry(dir: '.')], active: '.');
  }

  void _save(List<AccountEntry> accounts, String active) {
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({'active': active, 'accounts': [for (final a in accounts) a.toJson()]}), flush: true);
    tmp.renameSync(_file.path);
  }

  String dirOf(String dir) {
    if (!validDir(dir)) throw ArgumentError.value(dir, 'dir');
    return dir == '.' ? base : p.join(base, dir);
  }

  String activeDir() => dirOf(load().active);

  /// Adds an empty account folder and makes it active.
  AccountEntry addNew() {
    final s = load();
    final entry = AccountEntry(dir: 'accounts/${toHex(randomBytes(8))}', added: DateTime.now().millisecondsSinceEpoch);
    Directory(dirOf(entry.dir)).createSync(recursive: true);
    _save([...s.accounts, entry], entry.dir);
    return entry;
  }

  void setActive(String dir) {
    final s = load();
    if (!s.accounts.any((a) => a.dir == dir)) throw ArgumentError.value(dir, 'dir', 'unknown account');
    final now = DateTime.now().millisecondsSinceEpoch;
    _save([for (final a in s.accounts) a.dir == dir ? a.copyWith(lastUsed: now) : a], dir);
  }

  void update(String dir, {String? id, String? name}) {
    final s = load();
    _save([for (final a in s.accounts) a.dir == dir ? a.copyWith(id: id, name: name) : a], s.active);
  }

  /// Forgets an account and deletes its folder. The primary account's
  /// files are erased by the session's wipe instead.
  void remove(String dir) {
    final s = load();
    final rest = s.accounts.where((a) => a.dir != dir).toList();
    if (rest.isEmpty) {
      if (_file.existsSync()) _file.deleteSync();
    } else {
      final active = s.active == dir ? (rest.toList()..sort((a, b) => b.lastUsed.compareTo(a.lastUsed))).first.dir : s.active;
      _save(rest, active);
    }
    if (dir != '.') {
      final d = Directory(dirOf(dir));
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  }

  /// The most recently used account other than [dir], if any.
  AccountEntry? previousOf(String dir) {
    final others = load().accounts.where((a) => a.dir != dir && a.id.isNotEmpty).toList()
      ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return others.firstOrNull;
  }
}
