import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../data/models.dart';
import '../net/engine.dart';
import '../net/live_loc.dart';
import 'providers.dart';

/// Keeps GPS fixes flowing for live locations this device is sharing.
class LiveShareController {
  LiveShareController(this.engine) {
    if (engine != null) resume();
  }

  final Engine? engine;
  final _active = <String, _Share>{};
  StreamSubscription<Position>? _sub;
  var _starting = false;

  bool isSharing(String messageId) => _active.containsKey(messageId);

  /// Asks for location access, sends the first fix, and keeps streaming until
  /// [for_] ends or [end] is called. Returns an error string, or null.
  Future<String?> start(String scope, Duration for_, {String text = ''}) async {
    final engine = this.engine;
    if (engine == null) return 'Mentos is not ready yet.';
    final perm = await _permission();
    if (perm == null) return 'Location permission is needed to share where you are.';
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Turn on location services to share where you are.';
    }
    final Position pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
      );
    } catch (_) {
      return 'Could not read a GPS fix.';
    }
    final until = DateTime.now().add(for_).millisecondsSinceEpoch;
    final fix = _fix(pos, until, [(pos.latitude, pos.longitude)]);
    final sent = await engine.sendMessage(scope, text: text, loc: fix.toJson());
    final share = _Share(scope, sent.id, until, pos.latitude, pos.longitude, [(pos.latitude, pos.longitude)]);
    share.sentAt = nowMs();
    _active[sent.id] = share;
    _save();
    await _ensure(perm);
    return null;
  }

  Future<void> end(String messageId, {String? scope, LiveFix? current}) async {
    final share = _active.remove(messageId);
    _save();
    final engine = this.engine;
    final useScope = share?.scope ?? scope;
    final lat = share?.lat ?? current?.lat;
    final lng = share?.lng ?? current?.lng;
    if (engine != null && useScope != null && lat != null && lng != null) {
      final ended = LiveFix(
        lat: lat,
        lng: lng,
        ts: nowMs(),
        until: nowMs(),
        path: share?.path ?? current?.path ?? [(lat, lng)],
      );
      await engine.publishLiveFix(useScope, messageId, ended.toJson());
    }
    if (_active.isEmpty) await _stop();
  }

  void resume() {
    final engine = this.engine;
    if (engine == null) return;
    final raw = engine.db.getKv('locshares');
    if (raw == null || raw.isEmpty) return;
    final now = nowMs();
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final row in list) {
        if (row is! Map) continue;
        final id = row['id'];
        final scope = row['scope'];
        final until = row['until'];
        final lat = row['lat'];
        final lng = row['lng'];
        if (id is! String || scope is! String || until is! num || lat is! num || lng is! num) continue;
        if (until <= now) continue;
        final path = <(double, double)>[];
        final rawPath = row['p'];
        if (rawPath is List) {
          for (final pt in rawPath) {
            if (pt is List && pt.length >= 2 && pt[0] is num && pt[1] is num) {
              path.add(((pt[0] as num).toDouble(), (pt[1] as num).toDouble()));
            }
          }
        }
        if (path.isEmpty) path.add((lat.toDouble(), lng.toDouble()));
        _active[id] = _Share(scope, id, until.toInt(), lat.toDouble(), lng.toDouble(), path);
      }
    } catch (_) {
      return;
    }
    if (_active.isNotEmpty) unawaited(_ensure(LocationPermission.whileInUse));
  }

  Future<void> dispose() async {
    await _stop();
    _active.clear();
  }

  Future<LocationPermission?> _permission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      try {
        perm = await Geolocator.requestPermission();
      } catch (_) {
        return null;
      }
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    return perm;
  }

  Future<void> _ensure(LocationPermission perm) async {
    if (_sub != null || _starting || _active.isEmpty) return;
    _starting = true;
    try {
      _sub = Geolocator.getPositionStream(locationSettings: _settings(perm)).listen(
        _onPos,
        onError: (_) {},
      );
    } catch (_) {
      _sub = null;
    } finally {
      _starting = false;
    }
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  void _onPos(Position pos) {
    final engine = this.engine;
    if (engine == null) return;
    final now = nowMs();
    final done = <String>[];
    for (final share in _active.values) {
      if (share.until <= now) {
        done.add(share.id);
        continue;
      }
      final moved = metersBetween(share.lat, share.lng, pos.latitude, pos.longitude);
      final waited = now - share.sentAt;
      if (waited < 4000) continue;
      if (moved < 12 && waited < 15000) continue;
      share.lat = pos.latitude;
      share.lng = pos.longitude;
      share.sentAt = now;
      final last = share.path.isEmpty ? null : share.path.last;
      if (last == null || metersBetween(last.$1, last.$2, pos.latitude, pos.longitude) >= 8) {
        share.path.add((pos.latitude, pos.longitude));
        if (share.path.length > 80 && share.path.length > 2) share.path.removeAt(1);
      }
      final fix = _fix(pos, share.until, share.path);
      unawaited(engine.publishLiveFix(share.scope, share.id, fix.toJson()));
    }
    _save();
    for (final id in done) {
      unawaited(end(id));
    }
  }

  void _save() {
    final engine = this.engine;
    if (engine == null) return;
    if (_active.isEmpty) {
      engine.db.setKv('locshares', '[]');
      return;
    }
    engine.db.setKv('locshares', jsonEncode([
      for (final s in _active.values)
        {
          'id': s.id,
          'scope': s.scope,
          'until': s.until,
          'lat': s.lat,
          'lng': s.lng,
          'p': [for (final pt in s.path) [pt.$1, pt.$2]],
        },
    ]));
  }

  LocationSettings _settings(LocationPermission perm) {
    if (!kIsWeb && Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 8,
        intervalDuration: const Duration(seconds: 4),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Sharing live location',
          notificationText: 'Mentos is sending your location to this chat.',
          notificationChannelName: 'Live location',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
      final always = perm == LocationPermission.always;
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.otherNavigation,
        distanceFilter: 8,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: always,
        allowBackgroundLocationUpdates: always,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 8);
  }
}

LiveFix _fix(Position pos, int until, List<(double, double)> path) => LiveFix(
      lat: pos.latitude,
      lng: pos.longitude,
      ts: pos.timestamp.millisecondsSinceEpoch,
      until: until,
      acc: pos.accuracy > 0 ? pos.accuracy : null,
      heading: pos.heading >= 0 ? pos.heading : null,
      speed: pos.speed >= 0 ? pos.speed : null,
      path: path,
    );

class _Share {
  _Share(this.scope, this.id, this.until, this.lat, this.lng, this.path);
  final String scope;
  final String id;
  final int until;
  double lat;
  double lng;
  int sentAt = 0;
  final List<(double, double)> path;
}

final liveShareProvider = Provider<LiveShareController>((ref) {
  final engine = ref.watch(maybeEngineProvider);
  final controller = LiveShareController(engine);
  ref.onDispose(() { controller.dispose(); });
  return controller;
});
