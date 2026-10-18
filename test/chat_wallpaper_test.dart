import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/core/theme/app_theme.dart';
import 'package:mentos/core/theme/tokens.dart';
import 'package:mentos/data/db.dart';
import 'package:mentos/data/media_store.dart';
import 'package:mentos/features/chats/chat_wallpaper.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/state/settings.dart';

import 'support/fake_net.dart';

void main() {
  group('chat wallpaper', () {
    test('settings encode and decode chat wallpaper', () {
      const s = Settings();
      expect(s.chatWallpaper, 'default');

      final mesh = s.copyWith(chatWallpaper: 'mesh');
      expect(mesh.chatWallpaper, 'mesh');

      final decoded = Settings.decode(mesh.encode());
      expect(decoded.chatWallpaper, 'mesh');
    });

    test('wallpaperName resolves display titles correctly', () {
      expect(wallpaperName('default'), 'Default');
      expect(wallpaperName('mesh'), 'P2P Mesh');
      expect(wallpaperName('blueprint'), 'Cypher Grid');
      expect(wallpaperName('aurora'), 'Aurora');
      expect(wallpaperName('doodle'), 'Cypher Doodles');
      expect(wallpaperName('custom_image:/path/to/img.png'), 'Custom photo');
      expect(wallpaperName('custom_color:0xFF112233'), 'Custom color');
    });

    test('engine sets and clears per-chat wallpaper', () async {
      final root = await Directory.systemTemp.createTemp('mentos-wallpaper-test-');
      try {
        final me = await Identity.generate();
        final db = Db.open('${root.path}/test.db', toHex(sha256(me.seed)));
        final net = TestTransport(TestNetwork(), me.id);
        final engine = Engine(
          me: me,
          db: db,
          net: net,
          media: MediaStore(root.path, db, net),
          settings: const Settings(chatWallpaper: 'default'),
        );

        const scope = 'dm:alice:bob';
        // Defaults to global setting
        expect(engine.chatWallpaper(scope), 'default');

        // Sets custom wallpaper
        engine.setChatWallpaper(scope, 'aurora');
        expect(engine.chatWallpaper(scope), 'aurora');

        // Reverts when set to null or empty
        engine.setChatWallpaper(scope, null);
        expect(engine.chatWallpaper(scope), 'default');

        db.close();
      } finally {
        await root.delete(recursive: true);
      }
    });

    testWidgets('ChatWallpaperBackground renders presets without error', (tester) async {
      for (final preset in ['default', 'mesh', 'blueprint', 'aurora', 'doodle', 'midnight', 'sunset', 'solid_navy', 'custom_image:/nonexistent.jpg']) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Palette.dark),
            home: Scaffold(
              body: ChatWallpaperBackground(
                wallpaperId: preset,
                child: const Text('Hello world'),
              ),
            ),
          ),
        );
        expect(find.text('Hello world'), findsOneWidget);
      }
    });
  });
}
