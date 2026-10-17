part of 'market.dart';

/// One measured step of the device check, for a live progress screen.
class ProbeStep {
  const ProbeStep(this.id, this.label, {this.value, this.done = false, this.result});
  final String id;
  final String label;
  final String? value;
  final bool done;

  /// The finished benchmark, on the last step only.
  final Map<String, dynamic>? result;
}

/// Measures what this phone can offer: processor, memory, storage and the
/// network path. Every number is measured here, now; nothing is sent until
/// the person publishes an offer.
extension DeviceProbe on Market {
  Stream<ProbeStep> runDiagnostics() async* {
    final bench = <String, dynamic>{
      'platform': Platform.operatingSystem,
      'os': Platform.operatingSystemVersion.length > 80
          ? Platform.operatingSystemVersion.substring(0, 80)
          : Platform.operatingSystemVersion,
      'cores': Platform.numberOfProcessors,
    };
    yield ProbeStep('device', 'Device', value: '${_osName()} · ${bench['cores']} cores', done: true);

    yield const ProbeStep('cpu1', 'Single-core speed');
    final single = await _hashRateAsync(24);
    bench['cpu1'] = single.round();
    yield ProbeStep('cpu1', 'Single-core speed', value: '${single.toStringAsFixed(0)} MB/s hashing', done: true);

    final lanes = math.max(1, math.min(Platform.numberOfProcessors, 8));
    yield ProbeStep('cpuN', 'All cores ($lanes lanes)');
    final watch = Stopwatch()..start();
    await Future.wait([for (var i = 0; i < lanes; i++) _hashRateAsync(16)]);
    final multi = (16 * lanes) / (watch.elapsedMicroseconds / 1e6);
    bench['cpuN'] = multi.round();
    bench['score'] = (multi * 10).round();
    yield ProbeStep('cpuN', 'All cores ($lanes lanes)', value: '${multi.toStringAsFixed(0)} MB/s · score ${bench['score']}', done: true);

    yield const ProbeStep('ram', 'Memory');
    final ram = await _memory();
    if (ram != null) {
      bench['ramMb'] = ram.total;
      bench['ramFreeMb'] = ram.free;
    }
    yield ProbeStep('ram', 'Memory',
        value: ram == null ? 'Not reported by this system' : '${_gb(ram.total * 1024 * 1024)} total · ${_gb(ram.free * 1024 * 1024)} free',
        done: true);

    yield const ProbeStep('disk', 'Storage');
    final dir = engine.media.tmp;
    final free = await _freeBytes(dir.path);
    if (free != null) bench['freeGb'] = free ~/ (1024 * 1024 * 1024);
    final io = await _diskSpeed(dir);
    bench['diskW'] = io.write.round();
    bench['diskR'] = io.read.round();
    yield ProbeStep('disk', 'Storage',
        value: '${free == null ? '?' : _gb(free)} free · write ${io.write.toStringAsFixed(0)} MB/s · read ${io.read.toStringAsFixed(0)} MB/s',
        done: true);

    yield const ProbeStep('net', 'Network path');
    final net = await _network();
    bench['net'] = net;
    final relayMs = net['relayMs'];
    yield ProbeStep('net', 'Network path',
        value: [
          if (net['mode'] != null) '${net['mode']}',
          if (relayMs is int) 'relay $relayMs ms',
          if (net['udp'] == true) 'UDP open',
          '${net['links'] ?? 0} links',
        ].join(' · '),
        done: true);

    bench['ts'] = nowMs();
    engine.db.setKv('mk-bench', jsonEncode(bench));
    yield ProbeStep('done', 'Finished', done: true, result: bench);
  }

  /// The last measurement, if this phone ran one.
  Map<String, dynamic>? get lastBench {
    try {
      final raw = engine.db.getKv('mk-bench');
      return raw == null ? null : (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// A sensible first offer: a quarter of the free space, capped.
  ({int gb, int perGbDay, int perUnit}) suggestOffer(Map<String, dynamic> bench) {
    final free = bench['freeGb'] as int? ?? 4;
    final gb = (free ~/ 4).clamp(1, 200);
    final score = bench['score'] as int? ?? 1000;
    final perUnit = score > 20000 ? 2 : (score > 6000 ? 3 : 5);
    return (gb: gb, perGbDay: 2, perUnit: perUnit);
  }

  String _osName() => switch (Platform.operatingSystem) {
    'android' => 'Android',
    'ios' => 'iOS',
    'windows' => 'Windows',
    'macos' => 'macOS',
    'linux' => 'Linux',
    _ => Platform.operatingSystem,
  };

  Future<({int total, int free})?> _memory() async {
    try {
      if (Platform.isLinux || Platform.isAndroid) {
        final lines = await File('/proc/meminfo').readAsLines();
        int? read(String key) {
          final l = lines.where((x) => x.startsWith(key)).firstOrNull;
          final kb = l == null ? null : int.tryParse(l.replaceAll(RegExp(r'[^0-9]'), ''));
          return kb == null ? null : kb ~/ 1024;
        }

        final total = read('MemTotal'), free = read('MemAvailable') ?? read('MemFree');
        if (total != null && free != null) return (total: total, free: free);
      } else if (Platform.isWindows) {
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          r'$o = Get-CimInstance Win32_OperatingSystem; "$($o.TotalVisibleMemorySize) $($o.FreePhysicalMemory)"',
        ]);
        final parts = '${r.stdout}'.trim().split(RegExp(r'\s+'));
        if (parts.length == 2) {
          final total = int.tryParse(parts[0]), free = int.tryParse(parts[1]);
          if (total != null && free != null) return (total: total ~/ 1024, free: free ~/ 1024);
        }
      } else if (Platform.isMacOS) {
        final r = await Process.run('sysctl', ['-n', 'hw.memsize']);
        final bytes = int.tryParse('${r.stdout}'.trim());
        if (bytes != null) return (total: bytes ~/ (1024 * 1024), free: 0);
      }
    } catch (_) {}
    return null;
  }

  Future<({double write, double read})> _diskSpeed(Directory dir) async {
    final f = File('${dir.path}${Platform.pathSeparator}probe-${toHex(randomBytes(4))}.bin');
    const mb = 32;
    final chunk = Uint8List(1024 * 1024);
    for (var i = 0; i < chunk.length; i += 4096) {
      chunk[i] = i & 0xff;
    }
    try {
      final w = Stopwatch()..start();
      final sink = f.openSync(mode: FileMode.write);
      for (var i = 0; i < mb; i++) {
        sink.writeFromSync(chunk);
      }
      sink.flushSync();
      sink.closeSync();
      final write = mb / (w.elapsedMicroseconds / 1e6);
      final r = Stopwatch()..start();
      final reader = f.openSync();
      while (reader.readSync(1024 * 1024).isNotEmpty) {}
      reader.closeSync();
      final read = mb / (r.elapsedMicroseconds / 1e6);
      return (write: write, read: read);
    } catch (_) {
      return (write: 0.0, read: 0.0);
    } finally {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>> _network() async {
    final out = <String, dynamic>{};
    try {
      final st = await engine.netStatus();
      out['links'] = st.links.length;
      final direct = st.links.where((l) => l.kind == LinkKind.direct).length;
      out['mode'] = !st.running
          ? 'offline'
          : (st.links.isEmpty ? (st.reachable ? 'reachable' : 'offline') : (direct > 0 ? 'direct' : 'relayed'));
    } catch (_) {}
    final tools = engine.net;
    if (tools is NetTools) {
      try {
        final d = await (tools as NetTools).diagnostics();
        final report = d?['net'];
        if (report is Map) {
          out['udp'] = report['udpV4'] == true || report['udpV6'] == true;
          out['nat'] = report['mappingVariesV4'] == true ? 'strict' : 'easy';
          final lat = report['latencies'];
          if (lat is List) {
            final ms = [
              for (final x in lat)
                if (x is Map && x['ms'] is num) (x['ms'] as num).round(),
            ]..sort();
            if (ms.isNotEmpty) out['relayMs'] = ms.first;
          }
        }
      } catch (_) {}
    }
    return out;
  }
}

String _gb(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}

Future<double> _hashRateAsync(int mb) => Isolate.run(() => _hashRate(mb));

/// MB/s of SHA-256 over [mb] megabytes. Runs inside an isolate.
double _hashRate(int mb) {
  final block = Uint8List(1024 * 1024);
  for (var i = 0; i < block.length; i++) {
    block[i] = (i * 31) & 0xff;
  }
  final w = Stopwatch()..start();
  final out = _Sink();
  final input = hashes.sha256.startChunkedConversion(out);
  for (var i = 0; i < mb; i++) {
    input.add(block);
  }
  input.close();
  return mb / (w.elapsedMicroseconds / 1e6);
}

class _Sink implements Sink<hashes.Digest> {
  hashes.Digest? value;
  @override
  void add(hashes.Digest data) => value = data;
  @override
  void close() {}
}

Future<int?> _freeBytes(String path) async {
  try {
    if (Platform.isWindows) {
      final root = path.length > 1 && path[1] == ':' ? path[0] : null;
      if (root == null) return null;
      final r = await Process.run('powershell', ['-NoProfile', '-Command', "(Get-PSDrive -Name '$root').Free"]);
      return int.tryParse('${r.stdout}'.trim());
    }
    final r = await Process.run('df', ['-k', path]);
    final lines = '${r.stdout}'.trim().split('\n');
    if (lines.length < 2) return null;
    final parts = lines.last.trim().split(RegExp(r'\s+'));
    if (parts.length < 4) return null;
    final kb = int.tryParse(parts[3]);
    return kb == null ? null : kb * 1024;
  } catch (_) {
    return null;
  }
}
