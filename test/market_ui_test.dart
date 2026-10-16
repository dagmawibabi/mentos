import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/theme/app_theme.dart';
import 'package:mentos/core/theme/tokens.dart';
import 'package:mentos/features/market/market_screen.dart';
import 'package:mentos/features/market/task_screen.dart';
import 'package:mentos/features/wallet/ledger_screen.dart';
import 'package:mentos/features/wallet/coin_wallet_screen.dart';
import 'package:mentos/net/engine.dart';

import 'support/fake_net.dart';

void main() {
  testWidgets('market, tasks and ledger fit small screens in both themes', (
    tester,
  ) async {
    for (final family in {'Geist': 'assets/fonts/geist-400.ttf', 'GeistMono': 'assets/fonts/geist-mono-400.ttf', 'MaterialIcons': 'fonts/MaterialIcons-Regular.otf'}.entries) {
      final loader = FontLoader(family.key)..addFont(rootBundle.load(family.value));
      await loader.load();
    }
    late Directory root;
    late Engine e;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('mentos-ui-');
      e = await openEngine(root, TestNetwork());
      await e.postMarket({
        'kind': 'task',
        'title': 'Help translate the welcome guide',
        'about': 'Translate the introduction and attach a document for review.',
        'minor': 200,
        'status': 'open',
      });
    });
    final task = e.marketBoard().first['id'] as String;
    final boundary = GlobalKey();
    for (final palette in [Palette.light, Palette.dark]) {
      for (final entry in <String, Widget>{
        'market': const MarketScreen(),
        'wallet': const CoinWalletScreen(),
        'ledger': const LedgerScreen(),
        'task': TaskScreen(id: task),
      }.entries) {
        await pumpScreen(
          tester,
          e,
          Theme(
            data: buildTheme(palette),
            child: RepaintBoundary(key: boundary, child: entry.value),
          ),
          size: const Size(390, 844),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.takeException(),
          isNull,
          reason: '${entry.key}, dark=${palette.isDark}',
        );
        if (entry.key == 'market') {
          final chip = tester.widget<ChoiceChip>(
            find.widgetWithText(ChoiceChip, 'All'),
          );
          expect(chip.selected, isTrue);
          expect(
            Theme.of(tester.element(find.byType(ChoiceChip).first))
                .chipTheme
                .secondaryLabelStyle
                ?.color,
            palette.bg,
          );
        }
        if (Platform.environment['MENTOS_CAPTURE_UI'] == '1') {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final dir = Directory('build/market-previews');
            await dir.create(recursive: true);
            await File(
              '${dir.path}/${entry.key}-${palette.isDark ? 'dark' : 'light'}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await e.stop();
      e.db.close();
      await root.delete(recursive: true);
    });
  });
}
