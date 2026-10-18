import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/ai/ai.dart';

import 'support/fake_net.dart';

void main() {
  final sample = File('test/support/models_dev_sample.json').readAsStringSync();

  test('models.dev entries become chat models, rerankers are dropped', () {
    final all = jsonDecode(sample) as Map<String, dynamic>;
    final vercel = AiModel.fromCatalog(all['vercel'] as Map<String, dynamic>);
    expect(vercel, isNotEmpty);
    expect(vercel.any((m) => m.id.contains('rerank')), isFalse);
    final router = AiModel.fromCatalog(all['openrouter'] as Map<String, dynamic>);
    final claude = router.firstWhere((m) => m.id.startsWith('anthropic/'));
    expect(claude.lab, 'Anthropic');
    expect(claude.context, greaterThan(0));
    expect(AiModel.fromJson(claude.toJson()).id, claude.id);
  });

  test('the store keeps keys, the chosen model and chats per identity', () async {
    final root = await Directory.systemTemp.createTemp('mentos-ai-');
    final me = await openEngine(root, TestNetwork());
    final store = AiStore(me.db);
    expect(store.ready, isFalse);
    store.setKey(AiGateway.openrouter, ' sk-or-test ');
    expect(store.ready, isTrue);
    expect(store.keyFor(AiGateway.openrouter), 'sk-or-test');
    store.model = 'anthropic/claude-sonnet-4';
    store.gateway = AiGateway.vercel;
    expect(store.model, isNull, reason: 'each gateway remembers its own model');
    store.gateway = AiGateway.openrouter;
    expect(store.model, 'anthropic/claude-sonnet-4');

    final models = await store.models(AiGateway.openrouter, fetch: (_) async => sample);
    expect(models, isNotEmpty);
    expect(store.cachedModels(AiGateway.openrouter).length, models.length);
    expect(store.find(models.first.id)?.name, models.first.name);

    final c = AiConversation(id: 'c1', messages: [AiMessage(role: 'user', text: 'Hello there'), AiMessage(role: 'assistant', text: 'Hi!')]);
    store.save(c);
    expect(store.conversations().single.title, 'Hello there');
    store.delete('c1');
    expect(store.conversations(), isEmpty);
    await me.stop();
    me.db.close();
    await root.delete(recursive: true);
  });

  test('streams tokens and reasoning over SSE, and explains errors', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late Map<String, dynamic> sent;
    String? auth;
    server.listen((req) async {
      auth = req.headers.value('authorization');
      sent = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      if (sent['model'] == 'bad/model') {
        req.response.statusCode = 404;
        req.response.write(jsonEncode({'error': {'message': 'No such model'}}));
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType('text', 'event-stream');
      for (final chunk in [
        {'choices': [{'delta': {'reasoning': 'Thinking about it. '}}]},
        {'model': 'test/model', 'choices': [{'delta': {'content': '**Hello**'}}]},
        {'choices': [{'delta': {'content': ', world'}}]},
      ]) {
        req.response.write('data: ${jsonEncode(chunk)}\n\n');
        await req.response.flush();
      }
      req.response.write(': keep-alive\n\ndata: [DONE]\n\n');
      await req.response.close();
    });
    final url = Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions');

    final dir = await Directory.systemTemp.createTemp('mentos-ai-files-');
    final note = File('${dir.path}/note.md')..writeAsStringSync('# Plan\n- ship it');
    final pic = File('${dir.path}/p.png')..writeAsBytesSync([137, 80, 78, 71, 1, 2, 3]);
    final messages = await AiClient.buildMessages([
      AiMessage(role: 'user', text: 'Read these', attachments: [
        AiAttachment(path: note.path, name: 'note.md', mime: AiAttachment.mimeOf('note.md'), size: note.lengthSync()),
        AiAttachment(path: pic.path, name: 'p.png', mime: AiAttachment.mimeOf('p.png'), size: 7),
      ]),
    ], system: 'Be brief.');
    expect(messages.first, {'role': 'system', 'content': 'Be brief.'});
    final parts = messages[1]['content'] as List;
    expect((parts[0] as Map)['text'], contains('# Plan'));
    expect(((parts[1] as Map)['image_url'] as Map)['url'], startsWith('data:image/png;base64,'));
    expect((parts.last as Map)['text'], 'Read these');

    final client = AiClient(gateway: AiGateway.openrouter, apiKey: 'sk-or-x', endpoint: url);
    final deltas = await client.stream(model: 'test/model', messages: messages).toList();
    expect(auth, 'Bearer sk-or-x');
    expect(sent['stream'], isTrue);
    expect(deltas.map((d) => d.text).join(), '**Hello**, world');
    expect(deltas.map((d) => d.reasoning).join(), 'Thinking about it. ');

    await expectLater(
      client.stream(model: 'bad/model', messages: messages).toList(),
      throwsA(isA<AiError>().having((e) => e.message, 'message', allOf(contains('isn\'t available'), contains('No such model')))),
    );
    await server.close(force: true);
    await dir.delete(recursive: true);
  });
}
