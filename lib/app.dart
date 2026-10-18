import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/tokens.dart';
import 'features/calls/call_screen.dart';
import 'state/background.dart';
import 'state/calls.dart';
import 'state/live_share.dart';
import 'state/notifications.dart';
import 'state/providers.dart';
import 'state/session.dart';
import 'features/settings/dev_api.dart';
import 'features/settings/lock_gate.dart';
import 'plugins/plugin_providers.dart';
import 'widgets/xfer.dart';

class MentosApp extends ConsumerWidget {
  const MentosApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final accent = ref.watch(settingsProvider).accent;
    final session = ref.watch(sessionProvider);
    final router = ref.watch(routerProvider);
    ref.watch(notificationServiceProvider);
    ref.watch(keepAliveProvider);
    ref.watch(devApiProvider);
    ref.watch(liveManagerProvider);
    ref.watch(callManagerProvider);
    ref.watch(liveShareProvider);
    final pluginTheme = ref.watch(pluginThemeProvider);
    final density = switch (ref.watch(pluginLayoutProvider).density) {
      'compact' => VisualDensity.compact,
      'comfortable' => VisualDensity.comfortable,
      _ => null,
    };
    ThemeData dense(ThemeData t) => density == null ? t : t.copyWith(visualDensity: density);
    final light = dense(buildTheme(Palette.light.withAccent(accent).withOverrides(pluginTheme.light)));
    final dark = dense(buildTheme(Palette.dark.withAccent(accent).withOverrides(pluginTheme.dark)));
    // Keep the navigator out of the tree until the node is open so Feed/You
    // never call engineProvider during splash (that crashed mobile).
    if (session is SessionLoading) {
      return MaterialApp(
        title: 'Mentos',
        debugShowCheckedModeBanner: false,
        theme: light,
        darkTheme: dark,
        themeMode: mode,
        home: const _Splash(),
      );
    }
    if (session is SessionError) {
      return MaterialApp(
        title: 'Mentos',
        debugShowCheckedModeBanner: false,
        theme: light,
        darkTheme: dark,
        themeMode: mode,
        home: _Failure(message: session.message),
      );
    }
    return MaterialApp.router(
      title: 'Mentos',
      scaffoldMessengerKey: pluginMessengerKey,
      debugShowCheckedModeBanner: false,
      theme: light,
      darkTheme: dark,
      themeMode: mode,
      routerConfig: router,
      builder: (context, child) {
        final reduce = ref.watch(settingsProvider).reduceMotion;
        final media = MediaQuery.of(context);
        final body = session is SessionReady
            ? LockGate(
                child: CallHost(
                  router: router,
                  child: AlertHost(router: router, child: child ?? const SizedBox.shrink()),
                ),
              )
            : (child ?? const SizedBox.shrink());
        final scale = pluginTheme.textScale;
        return MediaQuery(
          data: media.copyWith(
            disableAnimations: media.disableAnimations || reduce,
            textScaler: scale == null ? media.textScaler : TextScaler.linear(media.textScaler.scale(1) * scale),
          ),
          child: body,
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MentosMark(size: 44),
            const SizedBox(height: 20),
            Text('opening your node', style: Txt.mono(p.muted)),
            const SizedBox(height: 16),
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: p.ink),
            ),
          ],
        ),
      ),
    );
  }
}

class _Failure extends ConsumerWidget {
  const _Failure({required this.message});
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Mentos could not open your data', style: Txt.title(p.ink)),
              const SizedBox(height: 12),
              Text(message, style: Txt.mono(p.muted)),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => ref.invalidate(sessionProvider),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mark: three nodes, one of them live.
class MentosMark extends StatelessWidget {
  const MentosMark({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return CustomPaint(size: Size.square(size), painter: _MarkPainter(p));
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.p);
  final Palette p;

  @override
  void paint(Canvas canvas, Size s) {
    final r = s.width * .17;
    final a = Offset(r, s.height - r);
    final b = Offset(s.width / 2, r);
    final c = Offset(s.width - r, s.height - r);
    final line = Paint()
      ..color = p.ink
      ..strokeWidth = s.width * .07
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(a, b, line);
    canvas.drawLine(b, c, line);
    canvas.drawCircle(a, r, Paint()..color = p.ink);
    canvas.drawCircle(c, r, Paint()..color = p.ink);

    // Glowing aura for the live node
    final glow = Paint()
      ..color = p.accent.withValues(alpha: .32)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * .75);
    canvas.drawCircle(b, r * 1.6, glow);
    canvas.drawCircle(b, r, Paint()..color = p.accent);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.p != p;
}
