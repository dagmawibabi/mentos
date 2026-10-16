import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../net/engine.dart';
import '../../net/pay/coin.dart';
import '../../state/providers.dart';

/// Localhost API started only while Developer Mode is on.
/// Other programs on this computer can call it. Nothing listens on the network.
class DevApi {
  HttpServer? _server;
  Engine? _engine;

  int get port => _server?.port ?? 8787;
  bool get running => _server != null;

  Future<void> start(Engine engine) async {
    if (_server != null) {
      _engine = engine;
      return;
    }
    _engine = engine;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8787);
      _server = server;
      server.listen(_handle, onError: (_) {});
    } catch (_) {
      _server = null;
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _engine = null;
    await s?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final e = _engine;
    req.response.headers
      ..set('Access-Control-Allow-Origin', 'http://127.0.0.1')
      ..set('Access-Control-Allow-Headers', 'content-type')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }
    if (e == null) {
      await _json(req, 503, {'error': 'node is not open'});
      return;
    }
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/v1/me') {
        await _json(req, 200, {'id': e.me.id, 'name': e.myProfile.name});
      } else if (req.method == 'GET' && path == '/v1/balance') {
        final coin = e.coin;
        await _json(req, 200, {
          'minor': coin?.balance() ?? 0,
          'mentos': Coin.format(coin?.balance() ?? 0),
        });
      } else if (req.method == 'GET' && path == '/v1/status') {
        final st = await e.netStatus();
        await _json(req, 200, {
          'running': st.running,
          'relay': st.relayUrl,
          'relays': st.relays,
          'peers': st.links.length,
          'preferredRelay': e.preferredRelay,
        });
      } else if (req.method == 'GET' && path == '/v1/chats') {
        await _json(req, 200, {
          'chats': [
            for (final c in e.chats())
              {'scope': c.scope, 'peer': c.peer, 'title': c.title, 'group': c.group, 'unread': c.unread},
          ],
        });
      } else if (req.method == 'POST' && path == '/v1/message') {
        final body = await _body(req);
        final scope = body['scope'];
        final text = body['text'];
        if (scope is! String || text is! String || text.trim().isEmpty) {
          await _json(req, 400, {'error': 'scope and text are required'});
          return;
        }
        final sent = await e.sendMessage(scope, text: text.trim());
        await _json(req, 200, {'id': sent.id});
      } else if (req.method == 'POST' && path == '/v1/pay') {
        final body = await _body(req);
        final to = body['to'];
        final amount = body['amount'];
        final memo = body['memo'] is String ? body['memo'] as String : '';
        final minor = amount is num ? amount.toInt() : Coin.parse('$amount');
        if (to is! String || minor == null) {
          await _json(req, 400, {'error': 'to and amount are required'});
          return;
        }
        final tx = await e.coin?.pay(to, minor, memo: memo);
        await _json(req, 200, {'hash': tx?.hash});
      } else {
        await _json(req, 404, {
          'error': 'unknown',
          'routes': ['GET /v1/me', 'GET /v1/balance', 'GET /v1/status', 'GET /v1/chats', 'POST /v1/message', 'POST /v1/pay'],
        });
      }
    } catch (err) {
      await _json(req, 400, {'error': '$err'});
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    if (raw.trim().isEmpty) return const {};
    final j = jsonDecode(raw);
    return j is Map ? j.cast<String, dynamic>() : const {};
  }

  Future<void> _json(HttpRequest req, int code, Map<String, Object?> body) async {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}

final devApiProvider = Provider<DevApi>((ref) {
  final api = DevApi();
  ref.onDispose(api.stop);
  ref.listen(settingsProvider, (_, settings) {
    final engine = ref.read(maybeEngineProvider);
    if (settings.devMode && engine != null) {
      unawaited(api.start(engine));
    } else {
      unawaited(api.stop());
    }
  }, fireImmediately: true);
  ref.listen(maybeEngineProvider, (_, engine) {
    final on = ref.read(settingsProvider).devMode;
    if (on && engine != null) unawaited(api.start(engine));
  });
  return api;
});
