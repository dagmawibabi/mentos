import 'dart:math' as math;

/// One GPS fix for a live-location message, plus the trail since sharing started.
class LiveFix {
  const LiveFix({
    required this.lat,
    required this.lng,
    required this.ts,
    required this.until,
    this.acc,
    this.heading,
    this.speed,
    this.path = const [],
  });

  final double lat;
  final double lng;
  final int ts;
  final int until;
  final double? acc;
  final double? heading;
  final double? speed;
  final List<(double, double)> path;

  bool get active => DateTime.now().millisecondsSinceEpoch < until;

  List<(double, double)> get trail {
    if (path.isEmpty) return [(lat, lng)];
    final last = path.last;
    if ((last.$1 - lat).abs() > 0.0000001 || (last.$2 - lng).abs() > 0.0000001) {
      return [...path, (lat, lng)];
    }
    return path;
  }

  LiveFix copyWith({int? until, int? ts}) => LiveFix(
        lat: lat,
        lng: lng,
        ts: ts ?? this.ts,
        until: until ?? this.until,
        acc: acc,
        heading: heading,
        speed: speed,
        path: path,
      );

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'ts': ts,
        'until': until,
        if (acc != null) 'acc': acc,
        if (heading != null) 'hdg': heading,
        if (speed != null) 'spd': speed,
        if (path.isNotEmpty) 'p': [for (final p in path) [p.$1, p.$2]],
      };

  static LiveFix? parse(Object? raw) {
    if (raw is! Map) return null;
    final lat = _num(raw['lat']);
    final lng = _num(raw['lng']);
    final ts = _int(raw['ts']);
    final until = _int(raw['until']);
    if (lat == null || lng == null || ts == null || until == null) return null;
    if (!_coord(lat, lng)) return null;
    final path = <(double, double)>[];
    final rawPath = raw['p'];
    if (rawPath is List) {
      for (final pt in rawPath) {
        if (path.length >= 80) break;
        if (pt is! List || pt.length < 2) continue;
        final plat = _num(pt[0]);
        final plng = _num(pt[1]);
        if (plat == null || plng == null || !_coord(plat, plng)) continue;
        path.add((plat, plng));
      }
    }
    if (path.isEmpty) path.add((lat, lng));
    return LiveFix(
      lat: lat,
      lng: lng,
      ts: ts,
      until: until,
      acc: _positive(_num(raw['acc'])),
      heading: _heading(_num(raw['hdg'])),
      speed: _positive(_num(raw['spd'])),
      path: path,
    );
  }

  /// The newer of the message's own fix and a later update.
  static LiveFix? latest(Object? base, Object? over) {
    final a = parse(base);
    final b = parse(over);
    if (a == null) return b;
    if (b == null) return a;
    return b.ts >= a.ts ? b : a;
  }
}

double? _num(Object? v) {
  if (v is! num) return null;
  final d = v.toDouble();
  if (d.isNaN || d.isInfinite) return null;
  return d;
}

int? _int(Object? v) => v is num ? v.toInt() : null;

bool _coord(double lat, double lng) => lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;

double? _positive(double? v) => v == null || v <= 0 || v > 100000 ? null : v;

double? _heading(double? v) => v == null || v < 0 || v > 360 ? null : v;

/// Great-circle distance in meters.
double metersBetween(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180;
  final p2 = lat2 * math.pi / 180;
  final dphi = (lat2 - lat1) * math.pi / 180;
  final dl = (lng2 - lng1) * math.pi / 180;
  final h = math.sin(dphi / 2) * math.sin(dphi / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(h)));
}

String liveLeft(LiveFix fix) {
  if (!fix.active) return 'Ended';
  final left = Duration(milliseconds: fix.until - DateTime.now().millisecondsSinceEpoch);
  if (left.inHours >= 1) {
    final m = left.inMinutes.remainder(60);
    return m == 0 ? 'Live · ${left.inHours}h left' : 'Live · ${left.inHours}h ${m}m left';
  }
  if (left.inMinutes >= 1) return 'Live · ${left.inMinutes}m left';
  return 'Live · ${left.inSeconds.clamp(0, 59)}s left';
}
