import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/engine.dart';
import 'providers.dart';
import 'session.dart';

/// Text for the persistent notification. Pure, so it is unit tested.
String keepAliveText({required bool running, required int peers}) {
  if (!running) return 'Reconnecting to the mesh…';
  if (peers == 0) return 'Online · waiting for contacts';
  return 'Online · $peers ${peers == 1 ? 'peer' : 'peers'} connected';
}

/// Starts and stops the Android foreground service that keeps the node
/// alive while the app is in the background.
class NodeKeepAlive {
  NodeKeepAlive(this.engine);

  static const _channel = MethodChannel('mentos/background');
  static bool get supported => Platform.isAndroid;

  final Engine engine;
  Timer? _timer;
  String? _shown;

  Future<void> start() async {
    if (!supported) return;
    await _update();
    _timer ??= Timer.periodic(const Duration(seconds: 60), (_) => _update());
  }

  Future<void> _update() async {
    final st = await engine.netStatus();
    final text = keepAliveText(running: st.running && !engine.held, peers: engine.onlinePeers.length);
    if (text == _shown) return;
    _shown = text;
    try {
      await _channel.invokeMethod('start', {'text': text});
    } catch (_) {}
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _shown = null;
    if (!supported) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  /// Whether Android exempts Mentos from battery optimisation, which
  /// otherwise can still cut the network during deep sleep.
  static Future<bool> batteryExempt() async {
    if (!supported) return true;
    try {
      return await _channel.invokeMethod<bool>('batteryExempt') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> askBatteryExempt() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('askBatteryExempt');
    } catch (_) {}
  }
}

/// Runs the foreground service while a session is open and the setting is on.
final keepAliveProvider = Provider<NodeKeepAlive?>((ref) {
  final s = ref.watch(sessionProvider);
  final on = ref.watch(settingsProvider.select((x) => x.keepAlive));
  if (s is! SessionReady || !on) {
    if (NodeKeepAlive.supported) unawaited(const MethodChannel('mentos/background').invokeMethod('stop').catchError((_) => null));
    return null;
  }
  final k = NodeKeepAlive(s.engine);
  unawaited(k.start());
  // A rebuild either starts a fresh controller or stops the service above;
  // this one only needs its timer gone.
  ref.onDispose(() => k._timer?.cancel());
  return k;
});
