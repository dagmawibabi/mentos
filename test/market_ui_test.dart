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
import 'package:mentos/features/market/cart_screen.dart';
import 'package:mentos/features/market/deal_screens.dart';
import 'package:mentos/features/market/hub_screen.dart';
import 'package:mentos/features/market/listing_screen.dart';
import 'package:mentos/features/market/market_screen.dart';
import 'package:mentos/features/market/sell_screen.dart';
import 'package:mentos/features/wallet/coin_wallet_screen.dart';
import 'package:mentos/features/wallet/ledger_screen.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/market/market.dart';
import 'package:mentos/state/session.dart';

import 'support/fake_net.dart';

// Renders the marketplace at phone size against real engines. With
// MENTOS_CAPTURE_UI=1 each screen is also saved as a PNG under
// build/market-previews for a visual check.
final _capture = Platform.environment['MENTOS_CAPTURE_UI'] == '1';

class _Ready extends SessionNotifier {
  _Ready(this.engine);
  final Engine engine;
  @override
  Session build() => SessionReady(engine);
}

Future<void> _fonts() async {
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

Future<MediaRef> _photo(Engine e, Directory root, int seed) async {
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

void main() {
  testWidgets('market screens render at phone size with real data', (tester) async {
    late Directory root;
    late Engine seller, buyer;
    late Listing mug, task;
    late String order;
    await tester.runAsync(() async {
      await _fonts();
      root = await Directory.systemTemp.createTemp('mentos-market-ui-');
      final network = TestNetwork()..blobs = true;
      seller = await openEngine(root, network);
      buyer = await openEngine(root, network);
      await eventually(() => seller.coin!.accounts == 2 && buyer.coin!.accounts == 2);
      final titles = ['Hand-glazed coffee mug', 'Woven basket, large', 'Ethiopian coffee 1 kg', 'Leather notebook', 'Vintage film camera', 'Digital poster pack'];
      final prices = [120, 260, 340, 180, 1250, 45];
      final listings = <Listing>[];
      for (var i = 0; i < titles.length; i++) {
        final photo = await _photo(seller, root, i);
        listings.add(await seller.market!.publish(Kinds.item, {
          'title': titles[i],
          'about': 'Made in Addis with care. Ships within two days.',
          'price': prices[i],
          'stock': i == 1 ? 2 : 8,
          'category': i == 5 ? 'digital' : 'art',
          'condition': i == 5 ? 'digital' : (i == 4 ? 'used' : 'handmade'),
          'holdDays': 7,
          'delivery': [
            {'id': 'pick', 'label': 'Pickup in Bole', 'kind': 'pickup', 'price': 0, 'days': 0},
            {'id': 'ship', 'label': 'Courier in Addis', 'kind': 'ship', 'price': 30, 'days': 2},
          ],
          'media': [photo.toJson()],
          'location': 'Bole',
          'options': i == 0 ? [{'name': 'Colour', 'values': ['Sand', 'Ink', 'Moss']}] : null,
        }..removeWhere((_, v) => v == null)));
      }
      mug = listings.first;
      task = await seller.market!.publish(Kinds.task, {
        'title': 'Photograph three cafés in Piazza',
        'about': 'Daylight shots of the storefronts for a city guide.',
        'reward': 250,
        'deadline': DateTime.now().add(const Duration(days: 2)).millisecondsSinceEpoch,
        'category': 'photo',
        'criteria': ['Three different cafés', 'Shot in daylight', 'Storefront visible'],
        'evidence': ['photo', 'text'],
        'reviewDays': 3,
      });
      await seller.market!.publish(Kinds.exchange, {
        'title': 'Mentos for Telebirr',
        'side': 'sell',
        'rate': 1250,
        'min': 100,
        'max': 2000,
        'methods': ['Telebirr', 'CBE Birr'],
        'windowMins': 30,
      });
      await seller.market!.publish(Kinds.resource, {
        'title': 'Spare desktop in Kazanchis',
        'storage': {'gb': 40, 'perGbDay': 2},
        'compute': {'jobs': ['gzip', 'image', 'pow'], 'perUnit': 3, 'maxMb': 64},
        'bench': {'platform': 'windows', 'cores': 12, 'score': 18400, 'cpu1': 620, 'cpuN': 1840, 'freeGb': 210, 'diskW': 900, 'diskR': 1800, 'ramMb': 16384, 'net': {'mode': 'direct', 'relayMs': 42}, 'ts': nowMs()},
      });
      await eventually(() => buyer.market!.listings().length >= 9);
      for (var i = 0; i < 6; i++) {
        await buyer.market!.listing(listings[i].id)!.cover.let((c) async => buyer.media.open(c!, sources: [seller.me.id]));
      }
      final placed = await buyer.market!.placeOrder(
        lines: [(listing: buyer.market!.listing(mug.id)!, qty: 1, options: const {'Colour': 'Moss'})],
        deliveryId: 'ship',
        address: {'name': 'Abebe', 'line': 'Bole road', 'city': 'Addis Ababa', 'phone': ''},
      );
      order = placed['id'] as String;
      await eventually(() => seller.market!.order(order) != null);
      await seller.market!.acceptOrder(order);
      await seller.market!.shipOrder(order, 'Courier, arriving tomorrow');
      await eventually(() => buyer.market!.orderStage(buyer.market!.order(order)!) == 'shipped');
      buyer.market!.addToCart(buyer.market!.listing(listings[2].id)!, qty: 2);
    });

    Future<void> show(Widget screen, String name, {bool dark = false}) async {
      final key = GlobalKey();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWith(() => _Ready(buyer))],
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
      expect(tester.takeException(), isNull, reason: name);
      if (!_capture) return;
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final out = File('build/market-previews/$name.png')..createSync(recursive: true);
        out.writeAsBytesSync(data!.buffer.asUint8List());
      });
    }

    await show(const MarketScreen(), '01-shop');
    expect(find.text('Hand-glazed coffee mug'), findsWidgets);
    expect(find.text('Fresh on the network'), findsOneWidget);
    await show(const MarketScreen(), '01-shop-dark', dark: true);
    await show(const MarketScreen(initial: MarketTab.tasks), '02-tasks');
    expect(find.text('Photograph three cafés in Piazza'), findsOneWidget);
    await show(const MarketScreen(initial: MarketTab.exchange), '03-exchange');
    await show(const MarketScreen(initial: MarketTab.resources), '04-resources');
    await show(const MarketScreen(initial: MarketTab.ads), '05-ads');
    await show(ListingScreen(id: mug.id), '06-item');
    expect(find.text('Choose colour to buy'), findsOneWidget, reason: 'options must be picked first');
    await show(ListingScreen(id: task.id), '07-task');
    await show(DealScreen(kind: 'order', id: order), '08-order');
    expect(find.text('I received it, release payment'), findsOneWidget);
    await show(CheckoutScreen(seller: seller.me.id), '09-checkout');
    await show(const MarketHubScreen(), '10-hub');
    await show(const SellScreen(kind: Kinds.item), '11-sell');
    await show(const CoinWalletScreen(), '13-wallet-hidden');
    expect(find.text('In escrow'.toUpperCase()), findsOneWidget);
    await tester.tap(find.byTooltip('Show balance'));
    await tester.pump();
    await show(const CoinWalletScreen(), '12-wallet');
    expect(find.text('3.50'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide balance'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('3.50'), findsNothing);
    expect(find.text('hidden'), findsOneWidget);
    await show(const CoinWalletScreen(), '14-wallet-dark', dark: true);
    await show(const LedgerScreen(), '15-ledger');
    expect(find.text('NETWORK TREASURY'), findsOneWidget);
    await show(const LedgerScreen(), '16-ledger-dark', dark: true);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final e in [seller, buyer]) {
        await e.stop();
        e.db.close();
      }
      await root.delete(recursive: true);
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
