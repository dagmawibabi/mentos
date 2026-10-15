import 'dart:convert';

import '../data/models.dart';
import 'diagnostics.dart';
import 'engine.dart';
import 'transport.dart';

final _pings = Expando<Map<String, List<({int at, double? ms})>>>();

/// Diagnostics and node-exploration helpers. They only use the public
/// surface of [Engine] so this file can move into the core package as is.
extension EngineNet on Engine {
  NetTools? get _tools {
    final n = net;
    return n is NetTools ? n as NetTools : null;
  }

  bool get hasDiagnostics => _tools != null;

  Future<NetDiagnostics?> diagnostics() async {
    final t = _tools;
    if (t == null) return null;
    try {
      return NetDiagnostics.fromJson(await t.diagnostics());
    } catch (_) {
      return null;
    }
  }

  /// Pings [peer] and records the result for [pingHistory].
  Future<double?> ping(String peer) async {
    final t = _tools;
    if (t == null) return null;
    double? ms;
    try {
      ms = await t.ping(peer);
    } catch (_) {}
    final all = _pings[this] ??= {};
    final list = all.putIfAbsent(peer, () => []);
    list.add((at: nowMs(), ms: ms));
    if (list.length > 60) list.removeAt(0);
    return ms;
  }

  List<({int at, double? ms})> pingHistory(String peer) => List.unmodifiable(_pings[this]?[peer] ?? const []);

  void networkChanged() => _tools?.networkChange();

  /// A shareable report. Node ids of other people are shortened so a report
  /// pasted into a support chat does not hand out the whole contact list.
  Future<String> diagnosticsReport() async {
    final d = await diagnostics();
    final st = await netStatus();
    final raw = Map<String, dynamic>.from(d?.raw ?? const {});
    final conns = raw['connections'];
    if (conns is List) {
      raw['connections'] = [
        for (final c in conns)
          if (c is Map) {...c, 'peer': shortId('${c['peer']}')},
      ];
    }
    final out = {
      'app': 'mentos',
      'at': DateTime.now().toUtc().toIso8601String(),
      'engine': st.engine,
      'running': st.running,
      'held': held,
      'links': st.links.length,
      'onlinePeers': onlinePeers.length,
      'topics': topicCount,
      'privacyOptionsError': netOptionsError,
      'diagnostics': raw,
      'summary': d == null ? const [] : explain(d),
    };
    return const JsonEncoder.withIndent('  ').convert(out);
  }
}
