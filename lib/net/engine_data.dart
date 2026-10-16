import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/db.dart';
import '../data/models.dart';
import 'engine.dart';

/// Turns one stored row into something safe to show or export. Secrets are
/// the app PIN hash and symmetric keys for spaces, groups and files; signed
/// items are never altered so their signatures still verify.
Map<String, Object?> redactRow(String table, Map<String, Object?> row, {bool secrets = false}) {
  if (secrets) return row;
  final out = Map<String, Object?>.from(row);
  switch (table) {
    case 'kv':
      if (out['k'] == 'settings' && out['v'] is String) {
        try {
          final m = (jsonDecode(out['v'] as String) as Map).cast<String, Object?>();
          if ((m['pin'] as String?)?.isNotEmpty ?? false) m['pin'] = '<redacted>';
          out['v'] = jsonEncode(m);
        } catch (_) {}
      }
    case 'spaces' || 'groups':
      if (out['data'] is String) {
        try {
          final m = (jsonDecode(out['data'] as String) as Map).cast<String, Object?>();
          if (m.containsKey('key')) m['key'] = '<redacted>';
          out['data'] = jsonEncode(m);
        } catch (_) {}
      }
    case 'files':
      if (out.containsKey('key')) out['key'] = '<redacted>';
  }
  return out;
}

Map<String, Object?> itemJson(Item i, {bool live = false}) {
  Object? payload;
  try {
    payload = jsonDecode(i.e.payload);
  } catch (_) {
    payload = i.e.payload;
  }
  return {
    'id': i.id,
    'where': live ? 'live' : (i.owned ? 'yours' : 'kept'),
    'payload': payload,
    'signedPayload': i.e.payload,
    'sig': i.e.sig,
  };
}

extension EngineData on Engine {
  /// Everything on this device as one JSON document. [kind] and [scope]
  /// narrow the items; tables are included only for a full export.
  Map<String, Object?> exportData({String? kind, String? scope, bool secrets = false, bool live = true}) {
    final full = kind == null && scope == null;
    final items = <Item>[];
    ({int ts, String id})? before;
    while (true) {
      final page = db.browseItems(kind: kind, scope: scope, before: before, limit: 1000);
      items.addAll(page);
      if (page.length < 1000) break;
      before = (ts: page.last.ts, id: page.last.id);
    }
    final inMemory = live
        ? this.liveItems().where((i) => (kind == null || i.e.kind == kind) && (scope == null || i.e.scope == scope)).toList()
        : const <Item>[];
    return {
      'format': 'mentos-export',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'identity': me.id,
      'filter': {'kind': ?kind, 'scope': ?scope},
      'secretsIncluded': secrets,
      'counts': {'stored': items.length, 'live': inMemory.length},
      'items': [for (final i in items) itemJson(i)],
      'live': [for (final i in inMemory) itemJson(i, live: true)],
      if (full)
        'tables': {
          for (final t in Db.explorable)
            if (t != 'items')
              t: [
                for (final r in _allRows(t)) redactRow(t, r, secrets: secrets),
              ],
        },
    };
  }

  List<Map<String, Object?>> _allRows(String table) {
    final out = <Map<String, Object?>>[];
    for (var offset = 0;; offset += 1000) {
      final page = db.tableRows(table, limit: 1000, offset: offset);
      out.addAll(page);
      if (page.length < 1000) return out;
    }
  }

  /// Writes [exportData] to a file in [dir] and returns it. The caller shares
  /// it and deletes it afterwards; the file is plaintext.
  Future<File> writeExport(Directory dir, {String? kind, String? scope, bool secrets = false}) async {
    await dir.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final f = File(p.join(dir.path, 'mentos-export-$stamp.json'));
    final data = exportData(kind: kind, scope: scope, secrets: secrets);
    await f.writeAsString(const JsonEncoder.withIndent(' ').convert(data), flush: true);
    return f;
  }
}
