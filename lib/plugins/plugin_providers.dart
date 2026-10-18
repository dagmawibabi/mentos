import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'plugins.dart';

/// Lets plugins show a notice without a BuildContext.
final pluginMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// The open identity's plugins, or null before a node is open.
final pluginHostProvider = Provider<PluginHost?>((ref) {
  final e = ref.watch(maybeEngineProvider);
  if (e == null) return null;
  final host = PluginHost(
    e,
    toast: (name, text) => pluginMessengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$name: $text'), behavior: SnackBarBehavior.floating)),
  );
  ref.onDispose(host.dispose);
  return host;
});

/// Ticks whenever a plugin changes something worth rebuilding for.
final pluginTickProvider = StreamProvider<int>((ref) {
  final host = ref.watch(pluginHostProvider);
  if (host == null) return Stream.value(0);
  var n = 0;
  return Stream.multi((out) {
    out.add(n);
    final sub = host.changes.listen((_) => out.add(++n));
    out.onCancel = sub.cancel;
  });
});

/// Layout changes requested by running layout plugins.
final pluginLayoutProvider = Provider<PluginLayout>((ref) {
  ref.watch(pluginTickProvider);
  return ref.watch(pluginHostProvider)?.layout ?? const PluginLayout();
});

/// Colors and text size requested by running theme plugins.
final pluginThemeProvider = Provider<PluginTheme>((ref) {
  ref.watch(pluginTickProvider);
  return ref.watch(pluginHostProvider)?.theme ?? const PluginTheme();
});
