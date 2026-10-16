/// What the native node measured about the network. Everything here comes
/// from iroh itself (net report, relay client, QUIC stats); nothing is guessed.
class NetDiagnostics {
  const NetDiagnostics({
    required this.nodeId,
    required this.privacy,
    this.proxy,
    this.report,
    this.relays = const [],
    this.bound = const [],
    this.connections = const [],
    this.topics = 0,
    this.raw = const {},
  });

  final String nodeId;

  /// standard | relay | tor
  final String privacy;
  final String? proxy;
  final NetReport? report;
  final List<RelayState> relays;
  final List<String> bound;
  final List<ConnStats> connections;
  final int topics;

  /// The JSON exactly as native returned it, for export.
  final Map<String, dynamic> raw;

  ConnStats? connection(String peer) {
    for (final c in connections) {
      if (c.peer == peer) return c;
    }
    return null;
  }

  static NetDiagnostics? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = j.cast<String, dynamic>();
    final id = m['nodeId'];
    if (id is! String) return null;
    return NetDiagnostics(
      nodeId: id,
      privacy: m['privacy'] is String ? m['privacy'] as String : 'standard',
      proxy: m['proxy'] is String ? m['proxy'] as String : null,
      report: NetReport.fromJson(m['net']),
      relays: [for (final r in _list(m['relays'])) ?RelayState.fromJson(r)],
      bound: [for (final b in _list(m['bound'])) if (b is String) b],
      connections: [for (final c in _list(m['connections'])) ?ConnStats.fromJson(c)],
      topics: _int(m['topics']),
      raw: m,
    );
  }
}

class NetReport {
  const NetReport({
    required this.udpV4,
    required this.udpV6,
    this.mappingVariesV4,
    this.mappingVariesV6,
    this.preferredRelay,
    this.globalV4,
    this.globalV6,
    this.captivePortal,
    this.latencies = const [],
  });

  final bool udpV4;
  final bool udpV6;
  final bool? mappingVariesV4;
  final bool? mappingVariesV6;
  final String? preferredRelay;
  final String? globalV4;
  final String? globalV6;
  final bool? captivePortal;
  final List<RelayLatency> latencies;

  bool get hasUdp => udpV4 || udpV6;

  /// Endpoint-dependent mapping ("hard NAT") makes hole punching unlikely,
  /// so most links will stay on a relay.
  NatKind get nat {
    if (!hasUdp) return NatKind.blocked;
    final v = mappingVariesV4 ?? mappingVariesV6;
    if (v == null) return NatKind.unknown;
    return v ? NatKind.hard : NatKind.easy;
  }

  /// Best measured latency per relay, across probe kinds.
  Map<String, double> get bestLatency {
    final out = <String, double>{};
    for (final l in latencies) {
      final prev = out[l.relay];
      if (prev == null || l.ms < prev) out[l.relay] = l.ms;
    }
    return out;
  }

  static NetReport? fromJson(Object? j) {
    if (j is! Map) return null;
    return NetReport(
      udpV4: j['udpV4'] == true,
      udpV6: j['udpV6'] == true,
      mappingVariesV4: j['mappingVariesV4'] is bool ? j['mappingVariesV4'] as bool : null,
      mappingVariesV6: j['mappingVariesV6'] is bool ? j['mappingVariesV6'] as bool : null,
      preferredRelay: j['preferredRelay'] is String ? j['preferredRelay'] as String : null,
      globalV4: j['globalV4'] is String ? j['globalV4'] as String : null,
      globalV6: j['globalV6'] is String ? j['globalV6'] as String : null,
      captivePortal: j['captivePortal'] is bool ? j['captivePortal'] as bool : null,
      latencies: [for (final l in _list(j['latencies'])) ?RelayLatency.fromJson(l)],
    );
  }
}

enum NatKind { easy, hard, blocked, unknown }

class RelayLatency {
  const RelayLatency(this.relay, this.probe, this.ms);
  final String relay;

  /// https | udp4 | udp6
  final String probe;
  final double ms;

  static RelayLatency? fromJson(Object? j) {
    if (j is! Map || j['relay'] is! String || j['ms'] is! num) return null;
    return RelayLatency(j['relay'] as String, j['probe'] is String ? j['probe'] as String : '?', (j['ms'] as num).toDouble());
  }
}

class RelayState {
  const RelayState(this.url, this.connected, this.error);
  final String url;
  final bool connected;
  final String? error;

  static RelayState? fromJson(Object? j) {
    if (j is! Map || j['url'] is! String) return null;
    return RelayState(j['url'] as String, j['connected'] == true, j['error'] is String ? j['error'] as String : null);
  }
}

class ConnStats {
  const ConnStats({
    required this.peer,
    this.alpn = '',
    this.side = '',
    this.txBytes = 0,
    this.rxBytes = 0,
    this.txDatagrams = 0,
    this.rxDatagrams = 0,
    this.lostPackets = 0,
    this.lostBytes = 0,
    this.paths = const [],
    this.knownAddrs = const [],
  });

  final String peer;
  final String alpn;

  /// client (we dialed) or server (they dialed).
  final String side;
  final int txBytes;
  final int rxBytes;
  final int txDatagrams;
  final int rxDatagrams;
  final int lostPackets;
  final int lostBytes;
  final List<PathStats> paths;
  final List<({String kind, String address, bool active})> knownAddrs;

  PathStats? get selected {
    for (final p in paths) {
      if (p.selected) return p;
    }
    return null;
  }

  double get lossRate => txDatagrams <= 0 ? 0 : (lostPackets / txDatagrams).clamp(0, 1);

  static ConnStats? fromJson(Object? j) {
    if (j is! Map || j['peer'] is! String) return null;
    return ConnStats(
      peer: j['peer'] as String,
      alpn: j['alpn'] is String ? j['alpn'] as String : '',
      side: j['side'] is String ? j['side'] as String : '',
      txBytes: _int(j['txBytes']),
      rxBytes: _int(j['rxBytes']),
      txDatagrams: _int(j['txDatagrams']),
      rxDatagrams: _int(j['rxDatagrams']),
      lostPackets: _int(j['lostPackets']),
      lostBytes: _int(j['lostBytes']),
      paths: [for (final p in _list(j['paths'])) ?PathStats.fromJson(p)],
      knownAddrs: [
        for (final a in _list(j['knownAddrs']))
          if (a is Map && a['address'] is String)
            (kind: a['kind'] is String ? a['kind'] as String : '?', address: a['address'] as String, active: a['active'] == true),
      ],
    );
  }
}

class PathStats {
  const PathStats({
    required this.kind,
    required this.address,
    required this.selected,
    this.rttMs = 0,
    this.cwnd = 0,
    this.txBytes = 0,
    this.rxBytes = 0,
    this.lostPackets = 0,
    this.congestionEvents = 0,
  });

  /// direct | relay
  final String kind;
  final String address;
  final bool selected;
  final double rttMs;
  final int cwnd;
  final int txBytes;
  final int rxBytes;
  final int lostPackets;
  final int congestionEvents;

  static PathStats? fromJson(Object? j) {
    if (j is! Map || j['address'] is! String) return null;
    return PathStats(
      kind: j['kind'] is String ? j['kind'] as String : '?',
      address: j['address'] as String,
      selected: j['selected'] == true,
      rttMs: j['rttMs'] is num ? (j['rttMs'] as num).toDouble() : 0,
      cwnd: _int(j['cwnd']),
      txBytes: _int(j['txBytes']),
      rxBytes: _int(j['rxBytes']),
      lostPackets: _int(j['lostPackets']),
      congestionEvents: _int(j['congestionEvents']),
    );
  }
}

List<Object?> _list(Object? v) => v is List ? v : const [];
int _int(Object? v) => v is num ? v.toInt() : 0;

/// Plain-language reading of a report, for people who are not network nerds.
List<String> explain(NetDiagnostics d) {
  final out = <String>[];
  final r = d.report;
  switch (d.privacy) {
    case 'relay':
      out.add('Hide-my-IP is on: every link goes through a relay, so peers never see your address. Expect a little more latency.');
    case 'tor':
      out.add('Tor mode is on: links go through a relay, and the relay is reached through ${d.proxy ?? 'the proxy'}. Neither peers nor the relay see your IP.');
  }
  if (d.relays.isEmpty || d.relays.every((x) => !x.connected)) {
    out.add(d.privacy == 'tor'
        ? 'Not connected to a relay. Check that Orbot (or your proxy) is running.'
        : 'Not connected to a relay yet. Only direct links on this network will work.');
  }
  if (r == null) {
    if (d.privacy == 'standard') out.add('The network check has not finished yet.');
    return out;
  }
  if (d.privacy == 'standard') {
    switch (r.nat) {
      case NatKind.easy:
        out.add('Your NAT keeps the same public port for everyone, so direct connections should work for most peers.');
      case NatKind.hard:
        out.add('Your NAT changes ports per destination ("hard NAT"). Direct connections will often fail and fall back to a relay.');
      case NatKind.blocked:
        out.add('UDP looks blocked on this network. All links will use a relay over HTTPS.');
      case NatKind.unknown:
        out.add('Could not tell how your NAT behaves (needs two relay answers).');
    }
  }
  if (r.captivePortal == true && d.privacy == 'standard') {
    out.add('A captive portal may be intercepting traffic (hotel or airport Wi-Fi). Sign in to it if you have not.');
  }
  final best = r.bestLatency;
  if (best.isNotEmpty) {
    final fastest = best.entries.reduce((a, b) => a.value <= b.value ? a : b);
    out.add('Fastest relay: ${relayName(fastest.key)} at ${fastest.value.toStringAsFixed(0)} ms.');
  }
  return out;
}

/// "https://euc1-1.relay.n0.iroh.link./" -> "euc1-1"
String relayName(String url) {
  final host = Uri.tryParse(url)?.host ?? url;
  final first = host.split('.').first;
  return first.isEmpty ? url : first;
}
