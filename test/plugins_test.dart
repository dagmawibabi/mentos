import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/plugins/plugins.dart';

import 'support/fake_net.dart';

/// Serves the repo's plugins/ folder as if it were the GitHub registry.
Future<String> repoFetch(Uri u) async {
  final i = u.path.indexOf('/plugins/');
  if (i < 0) throw const HttpException('not found');
  final f = File(u.path.substring(i + 1));
  if (!f.existsSync()) throw HttpException('404 ${u.path}');
  return f.readAsString();
}

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('mentos-plugins-'));
  tearDown(() async => root.delete(recursive: true));

  test('the bundled registry installs and every plugin starts', () async {
    final network = TestNetwork();
    final me = await openEngine(root, network);
    final host = PluginHost(me, fetch: repoFetch);
    final listing = await host.browse();
    expect(listing.entries.map((e) => e.manifest.id), containsAll(['dice', 'text-tools', 'midnight', 'away', 'notes', 'weather', 'focus', 'nudge']));
    for (final en in listing.entries) {
      await host.installFrom(en.manifestUrl, pinnedSha: en.manifest.sha256);
      expect(host.errorOf(en.manifest.id), isNull, reason: en.manifest.id);
      expect(host.isRunning(en.manifest.id), isTrue);
    }

    // Commands and compose hooks.
    expect(host.runCommand('/roll 3d6', 'dm:x'), startsWith('🎲 3d6:'));
    expect(host.runCommand('/flip', 'dm:x'), contains('🪙'));
    expect(host.runCommand('/shrug ok', 'dm:x'), r'ok ¯\_(ツ)_/¯');
    expect(host.runCommand('/mock hello', 'dm:x'), 'hElLo');
    expect(host.runCommand('/nope', 'dm:x'), isNull);
    expect(host.transformOutgoing('nice :fire: :+1:', 'dm:x'), 'nice 🔥 👍');

    // Theme and pages.
    expect(host.theme.dark['accent'], isNotNull);
    expect(host.pages.map((p) => p.title), containsAll(['Midnight', 'Away message', 'Quick notes']));
    final notes = host.page('notes', 'main')!;
    expect(host.runCommand('/note buy milk', 'dm:x'), '');
    final tree = host.render(notes) as List;
    final list = tree.whereType<Map>().firstWhere((n) => n['type'] == 'list');
    expect((list['items'] as List).first['title'], 'buy milk');

    // Settings survive a restart; disabling stops a plugin.
    host.dispose();
    final again = PluginHost(me, fetch: repoFetch);
    expect(again.installed.length, 8);
    expect(again.runCommand('/flip', 'dm:x'), isNotNull);
    again.setEnabled('dice', false);
    expect(again.runCommand('/flip', 'dm:x'), isNull);
    again.uninstall('notes');
    expect(again.plugin('notes'), isNull);
    expect(me.db.kvKeys('pls:notes:'), isEmpty);
    again.dispose();
    await me.stop();
    me.db.close();
  });

  test('away replies once to people who message', () async {
    final network = TestNetwork();
    final me = await openEngine(root, network);
    final ada = await openEngine(root, network);
    await me.follow(ada.me.id, true);
    await ada.follow(me.me.id, true);
    final host = PluginHost(me, fetch: repoFetch);
    await host.installFrom(Uri.parse('https://example.test/plugins/away/plugin.json'));
    final page = host.page('away', 'main')!;
    final sw = (host.render(page) as List).first as Map;
    expect(host.callback('away', sw['onChange'], [true]), isTrue);
    final scope = Scope.dm(me.me.id, ada.me.id);
    await ada.sendMessage(scope, text: 'you there?');
    await ada.sendMessage(scope, text: 'hello?');
    await eventually(() => ada.messages(scope).any((m) => m.text.startsWith('🌙')));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ada.messages(scope).where((m) => m.text.startsWith('🌙')).length, 1);
    host.dispose();
    for (final e in [me, ada]) {
      await e.stop();
      e.db.close();
    }
  });

  test('permissions, checksums and bad scripts are enforced', () async {
    final network = TestNetwork();
    final me = await openEngine(root, network);
    final host = PluginHost(me, fetch: repoFetch);
    final m = PluginManifest.parse({'id': 'sneaky', 'name': 'Sneaky', 'version': '1', 'permissions': <String>[]});
    host.install(m, 'mentos.chats.send("dm:x", "hi")', origin: 'dev');
    expect(host.errorOf('sneaky'), contains('needs the "messages.send" permission'));
    host.install(m, 'mentos.storage.get("k")', origin: 'dev');
    expect(host.errorOf('sneaky'), contains('"storage"'));
    host.install(m, 'while (true) {}', origin: 'dev');
    expect(host.errorOf('sneaky'), contains('too long'));
    expect(() => host.install(m, 'let = ;', origin: 'dev'), throwsFormatException);
    expect(() => PluginManifest.parse({'id': 'x', 'name': 'X', 'version': '1'}), throwsFormatException);
    expect(() => PluginManifest.parse({'id': 'ok-id', 'name': 'X', 'version': '1', 'permissions': ['root']}), throwsFormatException);
    await expectLater(
      host.fetchPackage(Uri.parse('https://example.test/plugins/dice/plugin.json'), pinnedSha: '0' * 64),
      throwsFormatException,
    );
    final single = PluginManifest.fromHeader('/* @plugin {"id": "hello", "name": "Hello", "version": "0.1"} */\nmentos.log("hi")');
    expect(single?.id, 'hello');
    host.dispose();
    await me.stop();
    me.db.close();
  });

  test('layout, slots, tabs, peer messages and full http requests', () async {
    final network = TestNetwork();
    final me = await openEngine(root, network);
    final ada = await openEngine(root, network);
    await me.follow(ada.me.id, true);
    await ada.follow(me.me.id, true);
    final host = PluginHost(me, fetch: repoFetch);
    final theirs = PluginHost(ada, fetch: repoFetch);
    for (final id in ['focus', 'nudge', 'weather']) {
      await host.installFrom(Uri.parse('https://example.test/plugins/$id/plugin.json'));
    }
    await theirs.installFrom(Uri.parse('https://example.test/plugins/nudge/plugin.json'));

    // Focus mode: flipping a switch on its page changes the layout.
    final focus = host.page('focus', 'main')!;
    final wallet = (host.render(focus) as List).whereType<Map>().firstWhere((n) => n['label'] == 'Hide the Wallet tab');
    host.callback('focus', wallet['onChange'], [true]);
    final icons = (host.render(focus) as List).whereType<Map>().firstWhere((n) => n['label'] == 'Icons only in the tab bar');
    host.callback('focus', icons['onChange'], [true]);
    expect(host.layout.hideTabs, {'wallet'});
    expect(host.layout.navLabels, isFalse);
    host.setEnabled('focus', false);
    expect(host.layout.isEmpty, isTrue, reason: 'disabling a layout plugin undoes it');

    // Weather adds a feed card; Nudge pins a tab.
    expect(host.slots('feed.top').map((s) => s.plugin), ['weather']);
    expect(host.renderSlot(host.slots('feed.top').single), isNotNull);
    expect(host.tabs.single.title, 'Nudge');

    // Nudge talks to the same plugin on a contact's device.
    final page = host.page('nudge', 'main')!;
    Map? findButton(Object? n) {
      if (n is List) {
        for (final c in n) {
          final f = findButton(c);
          if (f != null) return f;
        }
      } else if (n is Map) {
        if (n['type'] == 'button' && '${n['label']}'.contains('Coffee')) return n;
        return findButton(n['children']);
      }
      return null;
    }
    host.callback('nudge', findButton(host.render(page))!['onTap']);
    await eventually(() => (ada.db.getKv('pls:nudge:inbox') ?? '').contains('Coffee'));

    // http.request: any method, headers in and out.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.set('x-echo', req.headers.value('x-token') ?? '');
      req.response.write('{"method": "${req.method}"}');
      await req.response.close();
    });
    final m = PluginManifest.parse({'id': 'net-test', 'name': 'Net', 'version': '1', 'permissions': ['net', 'storage']});
    host.install(m, '''
      mentos.http.request({url: "http://127.0.0.1:${server.port}/x", method: "PUT", headers: {"x-token": "abc"}, body: {a: 1}}, (res) => {
        mentos.storage.set("res", {ok: res.ok, method: res.json.method, echo: res.headers["x-echo"]});
      });
    ''', origin: 'dev');
    await eventually(() => me.db.getKv('pls:net-test:res') != null);
    expect(me.db.getKv('pls:net-test:res'), '{"ok":true,"method":"PUT","echo":"abc"}');
    await server.close(force: true);

    host.dispose();
    theirs.dispose();
    for (final e in [me, ada]) {
      await e.stop();
      e.db.close();
    }
  });
}
