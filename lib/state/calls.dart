import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/calls/devices.dart';
import '../net/call/calls.dart';
import '../net/transport.dart';
import 'session.dart';

/// Calls for the open account, or null when the network library has no
/// call support (offline builds, tests without media).
final callManagerProvider = Provider<CallManager?>((ref) {
  final s = ref.watch(sessionProvider);
  if (s is! SessionReady) return null;
  final Object net = s.engine.net;
  if (net is! MediaLink) return null;
  final phone = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  final m = CallManager(s.engine, net, devices: phone ? PhoneDevices() : null);
  ref.onDispose(() => unawaited(m.dispose()));
  return m;
});

final callStateProvider = StreamProvider<CallState?>((ref) {
  final m = ref.watch(callManagerProvider);
  if (m == null) return Stream.value(null);
  return Stream.multi((out) {
    out.add(m.current);
    final sub = m.changes.listen(out.add);
    out.onCancel = sub.cancel;
  });
});
