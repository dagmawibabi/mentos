import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/calls/devices.dart';
import '../net/call/calls.dart';
import '../net/call/live.dart';
import '../net/pay/coin.dart';
import '../net/pay/payments.dart';
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

/// Live streams for the open account.
final liveManagerProvider = Provider<LiveManager?>((ref) {
  final s = ref.watch(sessionProvider);
  if (s is! SessionReady) return null;
  final Object net = s.engine.net;
  if (net is! MediaLink) return null;
  final phone = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  final m = LiveManager(s.engine, net, devices: phone ? PhoneDevices() : null);
  ref.onDispose(() => unawaited(m.dispose()));
  return m;
});

final liveStateProvider = StreamProvider<LiveState?>((ref) {
  final m = ref.watch(liveManagerProvider);
  if (m == null) return Stream.value(null);
  return Stream.multi((out) {
    out.add(m.current);
    final sub = m.changes.listen(out.add);
    out.onCancel = sub.cancel;
  });
});

/// Mutual-credit payments for the open account.
final paymentsProvider = Provider<Payments?>((ref) {
  final s = ref.watch(sessionProvider);
  if (s is! SessionReady) return null;
  final p = Payments(s.engine);
  ref.onDispose(() => unawaited(p.dispose()));
  return p;
});

/// The open account's Mentos ledger, or null before the node is up.
final coinProvider = Provider<CoinLedger?>((ref) {
  final s = ref.watch(sessionProvider);
  if (s is! SessionReady) return null;
  return s.engine.coin;
});

/// Ticks whenever a Mentos payment is stored or replaced.
final coinTickProvider = StreamProvider<int>((ref) {
  final c = ref.watch(coinProvider);
  if (c == null) return Stream.value(0);
  var n = 0;
  return Stream.multi((out) {
    out.add(n);
    final sub = c.changes.listen((_) => out.add(++n));
    out.onCancel = sub.cancel;
  });
});

/// Ticks whenever a balance, approval or request changes.
final paymentsTickProvider = StreamProvider<int>((ref) {
  final p = ref.watch(paymentsProvider);
  if (p == null) return Stream.value(0);
  var n = 0;
  return Stream.multi((out) {
    out.add(n);
    final sub = p.changes.listen((_) => out.add(++n));
    out.onCancel = sub.cancel;
  });
});
