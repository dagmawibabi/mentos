import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mentos/features/shell/home_shell.dart';
import 'package:mentos/features/feed/feed_screen.dart';
import 'package:mentos/features/wallet/coin_wallet_screen.dart';
import 'package:mentos/features/profile/profile_screen.dart';


import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/features/activity/activity_screen.dart';
import 'package:mentos/features/chats/chat_screen.dart';
import 'package:mentos/features/chats/chats_screen.dart';
import 'package:mentos/features/files/transfer_screen.dart';
import 'package:mentos/features/network/atlas_screen.dart';
import 'package:mentos/features/network/custody_screen.dart';
import 'package:mentos/features/network/network_screen.dart';
import 'package:mentos/features/network/privacy_screen.dart';
import 'package:mentos/features/plugins/plugins_screen.dart';
import 'package:mentos/features/settings/dev_screen.dart';
import 'package:mentos/plugins/plugins.dart';
import 'package:mentos/features/settings/settings_screen.dart';
import 'package:mentos/net/engine.dart';

import 'plugins_test.dart' show repoFetch;
import 'support/fake_net.dart';
import 'support/preview.dart';

// Renders the reorganised screens at phone size against real engines, and
// (with MENTOS_CAPTURE_UI=1) saves each as a PNG for a visual check.
void main() {
  testWidgets('settings, activity, transfers, network and chats render', (tester) async {
    late Directory root;
    late Engine me, ada, bo;
    late String scope;
    await tester.runAsync(() async {
      await loadPreviewFonts();
      root = await Directory.systemTemp.createTemp('mentos-screens-');
      final network = TestNetwork()..blobs = true;
      me = await openEngine(root, network);
      ada = await openEngine(root, network);
      bo = await openEngine(root, network);
      await me.updateProfile(name: 'Dagmawi', bio: '');
      await ada.updateProfile(name: 'Ada Lovelace with a rather long display name', bio: '');
      await bo.updateProfile(name: 'Bo', bio: '');
      for (final e in [me, ada, bo]) {
        for (final o in [me, ada, bo]) {
          if (o != e) await e.follow(o.me.id, true);
        }
      }
      for (final e in [me, ada, bo]) {
        await e.atlas!.announce(force: true);
      }
      scope = Scope.dm(me.me.id, ada.me.id);
      final msg = await ada.sendMessage(scope, text: 'Did the photos come through?');
      await me.sendMessage(scope, text: 'Yes! Sending the full set now.');
      await eventually(() => me.messages(scope).length >= 2);
      await me.react(scope, msg.id, '❤️');
      await me.react(scope, msg.id, '🔥');
      await bo.sendMessage(Scope.dm(me.me.id, bo.me.id), text: 'See you at 6');
      final photo = await previewPhoto(ada, root, 2);
      await ada.offerTransfer(me.me.id, photo);
      final file = File('${root.path}/notes.txt')..writeAsStringSync('meeting notes ' * 100);
      final notes = await me.media.import(file, name: 'meeting-notes.txt');
      await me.offerTransfer(bo.me.id, notes);
      await eventually(() => me.transfers().length >= 2);
      final post = await me.createPost(text: 'Morning run along Entoto #running', media: [await previewPhoto(me, root, 1)]);
      await ada.like(post.scope, post.id, true);
      me.db.addActivity(Activity(id: 'demo-follow', kind: 'follow', actor: bo.me.id, ts: nowMs() - 3600000));
      me.db.addActivity(Activity(id: 'demo-comment', kind: 'comment', actor: ada.me.id, ref: post.id, text: 'Beautiful view, which trail is this?', ts: nowMs() - 60000));
      me.db.addActivity(Activity(id: 'demo-market', kind: 'market', actor: bo.me.id, ref: '/market/hub', scope: 'placed', text: 'placed an order', ts: nowMs() - 90000000));
      await eventually(() => me.db.activity().length >= 3);
      final plugins = PluginHost(me, fetch: repoFetch);
      for (final en in (await plugins.browse()).entries) {
        await plugins.installFrom(en.manifestUrl);
      }
      plugins.runCommand('/note call the relay host back', 'dm:x');
      plugins.dispose();
    });

    for (final dark in [false, true]) {
      for (final entry in <String, Widget>{'Feed': const FeedScreen(), 'Wallet': const CoinWalletScreen(), 'Spaces': const ChatsScreen(), 'Network': const NetworkScreen(), 'You': const MyProfileScreen()}.entries) {
        final names = ['Feed', 'Wallet', 'Spaces', 'Network', 'You'];
        final router = GoRouter(initialLocation: '/${entry.key}', routes: [
          StatefulShellRoute.indexedStack(builder: (_, _, shell) => HomeShell(shell: shell), branches: [
            for (final name in names) StatefulShellBranch(routes: [GoRoute(path: '/$name', builder: (_, _) => name == entry.key ? entry.value : const SizedBox.shrink())])
          ])
        ]);
        await previewScreen(tester, me, Router.withConfig(config: router), '${entry.key.toLowerCase()}-${dark ? "dark" : "light"}', dark: dark);
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
      }
      await previewScreen(tester, me, const PluginsScreen(), 'plugins-${dark ? "dark" : "light"}', dark: dark);
      await previewScreen(tester, me, const PluginPageScreen(plugin: 'notes', page: 'main'), 'notes-${dark ? "dark" : "light"}', dark: dark);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      for (final e in [me, ada, bo]) {
        await e.stop();
        e.db.close();
      }
      await root.delete(recursive: true);
    });
  });
}
