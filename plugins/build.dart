// Regenerates plugins/index.json from every plugins/<id>/plugin.json and
// pins each script's sha256. Run from the repo root:
//   dart run plugins/build.dart
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

void main() {
  final out = <Map<String, Object?>>[];
  final dirs = Directory('plugins').listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
  for (final dir in dirs) {
    final mf = File('${dir.path}/plugin.json');
    if (!mf.existsSync()) continue;
    final m = jsonDecode(mf.readAsStringSync()) as Map<String, dynamic>;
    final id = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (m['id'] != id) throw StateError('${mf.path}: id must match its folder ($id)');
    final main = File('${dir.path}/${m['main'] ?? 'main.js'}');
    out.add({...m, 'sha256': sha256.convert(main.readAsBytesSync()).toString(), 'manifest': '$id/plugin.json'});
  }
  const enc = JsonEncoder.withIndent('  ');
  File('plugins/index.json').writeAsStringSync('${enc.convert({'name': 'Mentos plugins', 'version': 1, 'plugins': out})}\n');
  stdout.writeln('indexed ${out.length} plugins');
}
