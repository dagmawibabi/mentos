import 'dart:io';

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
import 'package:mentos/features/chats/new_group_screen.dart';
import 'package:mentos/features/profile/profile_screen.dart';
import 'package:mentos/features/profile/edit_profile_screen.dart';
import 'package:mentos/features/ai/ai_chat_screen.dart';
import 'package:mentos/features/ai/ai_sheets.dart';
import 'package:mentos/features/feed/feed_screen.dart';
import 'package:mentos/ai/ai.dart';
import 'package:flutter/material.dart';
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
      await me.createStory(text: 'Sunrise run');
      final ai = AiStore(me.db)..setKey(AiGateway.openrouter, 'sk-or-preview');
      await ai.models(AiGateway.openrouter, fetch: (_) async => File('test/support/models_dev_sample.json').readAsStringSync());
      ai.model = ai.cachedModels(AiGateway.openrouter).firstWhere((m) => m.id.startsWith('anthropic/')).id;
      ai.save(AiConversation(id: 'demo', messages: [
        AiMessage(role: 'user', text: 'How do I keep a sourdough starter alive while travelling?'),
        AiMessage(
          role: 'assistant',
          model: ai.model,
          reasoning: 'They want practical steps.',
          text: '''Good news: starters are **hardy**. A few options:

1. **Fridge it** – feed it, then refrigerate. It keeps 2–3 weeks.
2. **Dry it** – spread thin, dry, and crumble. Lasts months.

| Method | Lasts |
|---|---|
| Fridge | 3 weeks |
| Dried | 6+ months |

> Revive with two feeds 12 hours apart.

```
flour 50g + water 50g + starter 10g
```''',
        ),
      ]));
      await me.updateProfile(name: 'Dagmawi', bio: 'Building a phone-to-phone social network. Coffee first.');
    });

    await previewScreen(tester, me, const SettingsScreen(), 's01-settings');
    expect(find.text('Appearance'), findsOneWidget);
    await previewScreen(tester, me, const PrivacySettings(), 's02-settings-privacy');
    await previewScreen(tester, me, const ActivityScreen(), 's03-activity');
    expect(find.textContaining('Beautiful view'), findsOneWidget);
    await previewScreen(tester, me, const TransfersScreen(), 's04-transfers');
    await previewScreen(tester, me, PeerTransferScreen(peer: ada.me.id), 's05-transfer-peer');
    await previewScreen(tester, me, const NetworkScreen(), 's06-network');
    expect(find.text('Active connections'.toUpperCase()), findsOneWidget);
    await previewScreen(tester, me, const AtlasScreen(), 's07-atlas');
    expect(find.text('Network atlas'), findsOneWidget);
    await previewScreen(tester, me, const CustodyScreen(), 's08-custody');
    await previewScreen(tester, me, const PrivacyScreen(), 's09-privacy');
    await previewScreen(tester, me, const ChatsScreen(), 's10-chats');
    // The composer's voice recorder is a platform plugin tests do not have.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async => null,
    );
    await previewScreen(tester, me, ChatScreen(peer: ada.me.id), 's11-chat');
    expect(find.text('Received'), findsNothing, reason: 'delivery shows bars only');
    await previewScreen(tester, me, const SettingsScreen(), 's12-settings-dark', dark: true);
    await previewScreen(tester, me, const PluginsScreen(), 's13-plugins');
    expect(find.text('Make Mentos yours'), findsOneWidget);
    await previewScreen(tester, me, const PluginDetailScreen(id: 'dice'), 's14-plugin-detail');
    await previewScreen(tester, me, const PluginPageScreen(plugin: 'notes', page: 'main'), 's15-plugin-page');
    expect(find.text('call the relay host back'), findsOneWidget);
    await previewScreen(tester, me, const PluginPageScreen(plugin: 'midnight', page: 'main'), 's16-midnight', dark: true);
    await previewScreen(tester, me, const DevScreen(), 's17-dev');
    await previewScreen(tester, me, const MyProfileScreen(), 's18-profile');
    expect(find.text('Keep you'), findsOneWidget);
    await previewScreen(tester, me, const MyProfileScreen(), 's19-profile-dark', dark: true);
    await previewScreen(tester, me, const EditProfileScreen(), 's22-edit-profile');
    expect(find.text('Add a header image'), findsOneWidget);
    await previewScreen(tester, me, const AiChatScreen(), 's23-ai-empty', dark: true);
    expect(find.text('Prompt suggestions…'), findsOneWidget);
    await previewScreen(tester, me, const AiChatScreen(conversation: 'demo'), 's24-ai-chat');
    expect(find.textContaining('hardy'), findsWidgets);
    await previewScreen(tester, me, const AiChatScreen(conversation: 'demo'), 's25-ai-chat-dark', dark: true);
    await previewScreen(tester, me, Builder(builder: (ctx) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ModalRoute.of(ctx)?.isCurrent ?? false) showModelPicker(ctx, AiStore(me.db));
      });
      return const Scaffold();
    }), 's26-ai-models', dark: true);
    expect(find.text('Models'), findsOneWidget);
    await previewScreen(tester, me, const FeedScreen(), 's27-feed');
    await previewScreen(tester, me, const MoneySettings(), 's20-money-settings');
    expect(find.text('See ads and earn'), findsOneWidget);
    await previewScreen(tester, me, const NewGroupScreen(), 's21-new-group');
    expect(find.text('Invite (optional)'.toUpperCase()), findsOneWidget);

    await tester.runAsync(() async {
      for (final e in [me, ada, bo]) {
        await e.stop();
        e.db.close();
      }
      await root.delete(recursive: true);
    });
  });
}
