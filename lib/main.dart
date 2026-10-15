import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  ErrorWidget.builder = (details) {
    return const Material(
      color: Color(0xFF111111),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'This screen hit a problem. Go back or reopen Mentos.',
            style: TextStyle(
              color: Color(0xFFEEEEEE),
              fontSize: 15,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) => true;
  try {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } catch (_) {}
  // ensureInitialized and runApp must share a zone. Wrapping only runApp
  // makes Flutter report "Zone mismatch" on every launch.
  runApp(const ProviderScope(child: MentosApp()));
}
