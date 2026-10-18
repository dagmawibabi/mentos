import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mentos/core/theme/app_theme.dart';
import 'package:mentos/core/theme/tokens.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/state/session.dart';

/// Set MENTOS_CAPTURE_UI=1 to save each rendered screen as a PNG under
/// build/market-previews for a visual check.
final capturing = Platform.environment['MENTOS_CAPTURE_UI'] == '1';

/// MENTOS_CAPTURE_SCALE=3 saves captures at 3x for crisp marketing stills.
final captureScale = double.tryParse(Platform.environment['MENTOS_CAPTURE_SCALE'] ?? '') ?? 1;

class ReadySession extends SessionNotifier {
  ReadySession(this.engine);
  final Engine engine;
  @override
  Session build() => SessionReady(engine);
}

/// Real fonts and icons, so captures look like the app.
Future<void> loadPreviewFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(rootBundle.load(f));
    }
    await loader.load();
  }

  await family('Geist', ['assets/fonts/geist-400.ttf', 'assets/fonts/geist-500.ttf', 'assets/fonts/geist-600.ttf']);
  await family('GeistMono', ['assets/fonts/geist-mono-400.ttf', 'assets/fonts/geist-mono-500.ttf']);
  final flutterRoot = File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
}

/// A simple generated photo imported into [e]'s media store.
Future<MediaRef> previewPhoto(Engine e, Directory root, int seed) async {
  final pic = img.Image(width: 480, height: 480);
  final colors = [
    [0xE8, 0x7D, 0x4F], [0x3A, 0x7C, 0xA5], [0x6A, 0x9F, 0x58], [0xC9, 0xA2, 0x27], [0x8E, 0x5B, 0xA8], [0x2F, 0x2F, 0x2F],
  ][seed % 6];
  for (var y = 0; y < 480; y++) {
    for (var x = 0; x < 480; x++) {
      final shade = ((x + y) / 960 * 60).round();
      pic.setPixelRgb(x, y, (colors[0] + shade).clamp(0, 255), (colors[1] + shade).clamp(0, 255), (colors[2] + shade).clamp(0, 255));
    }
  }
  img.fillCircle(pic, x: 240, y: 260, radius: 120, color: img.ColorRgb8(250, 248, 240));
  final f = File('${root.path}/p$seed.png')..writeAsBytesSync(img.encodePng(pic));
  return e.media.import(f, name: 'photo$seed.png', width: 480, height: 480);
}

/// Pumps [screen] at phone size as [engine]'s session, lets async work land,
/// checks nothing threw, and saves a PNG when capturing.
Future<void> previewScreen(WidgetTester tester, Engine engine, Widget screen, String name, {bool dark = false}) async {
  final key = GlobalKey();
  final previous = FlutterError.onError;
  FlutterError.onError = (d) {
    if (Platform.environment['MENTOS_UI_DEBUG'] == '1') debugPrint(d.toString());
    previous?.call(d);
  };
  addTearDown(() => FlutterError.onError = previous);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionProvider.overrideWith(() => ReadySession(engine))],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(dark ? Palette.dark : Palette.light),
          home: screen,
        ),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  final error = tester.takeException();
  if (capturing) await _capture(tester, key, name);
  expect(error, isNull, reason: '$name: $error');
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: captureScale);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/market-previews/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(data!.buffer.asUint8List());
  });
}
