import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/features/settings/dev_api.dart';
import 'package:mentos/plugins/plugins.dart';

import 'support/fake_net.dart';

void main() {
  test('developer API: dashboard, access code, routes and plugin hot-install', () async {
    final root = await Directory.systemTemp.createTemp('mentos-dev-');
    final network = TestNetwork();
    final me = await openEngine(root, network);
    final ada = await openEngine(root, network);
    await me.updateProfile(name: 'Dev', bio: '');
    await me.follow(ada.me.id, true);
    await ada.follow(me.me.id, true);
    final host = PluginHost(me);
    final api = DevApi(preferredPort: 18787)..plugins = () => host;
    final token = DevApi.newToken();
    expect(token, matches(RegExp(r'^[a-z2-9]{4}(-[a-z2-9]{4}){3}$')));
    await api.start(me, token: token, lan: false);
    expect(api.running, isTrue);
    final base = 'http://127.0.0.1:${api.port}';
    final client = HttpClient();

    Future<(int, String)> call(String method, String path, {Object? body, String? code}) async {
      final req = await client.openUrl(method, Uri.parse('$base$path'));
      if (code != null) req.headers.set('authorization', 'Bearer $code');
      if (body != null) req.write(body is String ? body : jsonEncode(body));
      final res = await req.close();
      return (res.statusCode, await utf8.decodeStream(res));
    }

    // The dashboard is public; data is not.
    final (pageStatus, page) = await call('GET', '/');
    expect(pageStatus, 200);
    expect(page, contains('Mentos Console'));
    expect((await call('GET', '/v1/info')).$1, 401);
    expect((await call('GET', '/v1/info', code: 'wrong-code-xxxx-xxxx')).$1, 401);

    final (infoStatus, info) = await call('GET', '/v1/info', code: token);
    expect(infoStatus, 200);
    expect((jsonDecode(info) as Map)['me']['name'], 'Dev');
    expect((jsonDecode((await call('GET', '/v1/help')).$2) as Map)['routes'], isNotEmpty);

    // Chat through the API.
    final scope = Scope.dm(me.me.id, ada.me.id);
    final (sendStatus, _) = await call('POST', '/v1/message', body: {'scope': scope, 'text': 'from the browser'}, code: token);
    expect(sendStatus, 200);
    await eventually(() => ada.messages(scope).any((m) => m.text == 'from the browser'));
    final msgs = jsonDecode((await call('GET', '/v1/messages?scope=${Uri.encodeQueryComponent(scope)}', code: token)).$2) as Map;
    expect((msgs['messages'] as List).last['text'], 'from the browser');

    // Hot-install a single-file plugin, then use its command.
    const src = '/* @plugin {"id": "hello", "name": "Hello", "version": "0.1", "permissions": ["commands"]} */\n'
        'mentos.commands.add("hello", "Say hi", () => "hi from a plugin");';
    final (plStatus, pl) = await call('POST', '/v1/plugins', body: src, code: token);
    expect(plStatus, 200, reason: pl);
    expect(host.runCommand('/hello', scope), 'hi from a plugin');
    expect((await call('POST', '/v1/plugins/hello/disable', code: token)).$1, 200);
    expect(host.runCommand('/hello', scope), isNull);
    expect((await call('DELETE', '/v1/plugins/hello', code: token)).$1, 200);
    expect(host.plugin('hello'), isNull);

    // Feed, people and the live stream used by the dashboard.
    expect((await call('POST', '/v1/post', body: {'text': 'hello from the console'}, code: token)).$1, 200);
    final feed = jsonDecode((await call('GET', '/v1/feed', code: token)).$2) as Map;
    final post = (feed['posts'] as List).firstWhere((x) => x['text'] == 'hello from the console') as Map;
    expect((await call('POST', '/v1/like', body: {'id': post['id'], 'on': true}, code: token)).$1, 200);
    final people = jsonDecode((await call('GET', '/v1/people', code: token)).$2) as Map;
    expect((people['people'] as List).map((x) => x['id']), contains(ada.me.id));
    final streamReq = await client.getUrl(Uri.parse('$base/v1/stream'));
    streamReq.headers.set('authorization', 'Bearer $token');
    final streamRes = await streamReq.close();
    expect(streamRes.headers.contentType?.mimeType, 'text/event-stream');
    final first = await streamRes.transform(utf8.decoder).firstWhere((c) => c.contains('event: hello'));
    expect(first, contains('event: hello'));

    final logs = jsonDecode((await call('GET', '/v1/logs', code: token)).$2) as Map;
    expect(logs['requests'], isNotEmpty);

    // Repeated wrong codes lock that address out for a minute.
    for (var i = 0; i < 8; i++) {
      await call('GET', '/v1/me', code: 'nope');
    }
    expect((await call('GET', '/v1/me', code: token)).$1, 429);

    client.close(force: true);
    await api.stop();
    host.dispose();
    for (final e in [me, ada]) {
      await e.stop();
      e.db.close();
    }
    await root.delete(recursive: true);
  });
}
