import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../net/engine.dart';
import '../../net/market/market.dart';
import '../../net/pay/coin.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/plugins.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import 'dev_dashboard.dart';

class DevRequest {
  const DevRequest(this.ts, this.ip, this.method, this.path, this.status, this.ms);
  final int ts;
  final String ip;
  final String method;
  final String path;
  final int status;
  final int ms;
  Map<String, Object> toJson() => {'ts': ts, 'ip': ip, 'method': method, 'path': path, 'status': status, 'ms': ms};
}

class DevClient {
  DevClient(this.ip);
  final String ip;
  int requests = 0;
  int lastSeen = 0;
  bool authed = false;
}

/// The developer API, started only while Developer mode is on.
///
/// By default it listens on 127.0.0.1, so only programs on this device can
/// reach it. With "Allow other devices" it also listens on the local network.
/// Either way every /v1 call must carry the access code, so a web page open
/// in some browser can't drive it. Opening the root URL in a browser shows a
/// dashboard that signs in with that code.
class DevApi {
  DevApi({this.preferredPort = 8787});

  final int preferredPort;
  HttpServer? _server;
  Engine? _engine;
  PluginHost? Function()? plugins;
  String _token = '';
  bool _lan = false;
  final _started = DateTime.now().millisecondsSinceEpoch;

  final requests = <DevRequest>[];
  final clients = <String, DevClient>{};
  final events = <Map<String, Object?>>[];
  final _fails = <String, (int, int)>{};
  StreamSubscription<OsNote>? _notesSub;
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;
  int get port => _server?.port ?? preferredPort;
  bool get running => _server != null;
  bool get lan => _lan && _server != null;

  /// Random access code, in groups so it can be typed from a phone.
  static String newToken() {
    const abc = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    return List.generate(4, (_) => List.generate(4, (_) => abc[r.nextInt(abc.length)]).join()).join('-');
  }

  /// This device's local network addresses, for the LAN link.
  static Future<List<String>> lanAddresses() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final i in list)
          for (final a in i.addresses)
            if (!a.isLoopback && !a.isLinkLocal) a.address,
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> start(Engine engine, {required String token, required bool lan}) async {
    _engine = engine;
    _token = token;
    _notesSub ??= engine.notes.listen((n) => _event('note', '${n.title}: ${n.body}', {'category': n.category}));
    if (_server != null && _lan == lan) return;
    await _close();
    _lan = lan;
    final addr = lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
    for (final p in [preferredPort, preferredPort + 1, preferredPort + 2, 0]) {
      try {
        final server = await HttpServer.bind(addr, p);
        _server = server;
        server.listen(_handle, onError: (_) {});
        _event('api', 'listening on ${lan ? 'all interfaces' : '127.0.0.1'}:${server.port}');
        break;
      } catch (_) {}
    }
    _changed();
  }

  Future<void> _close() async {
    final s = _server;
    _server = null;
    for (final r in _streams.toList()) {
      try {
        await r.close();
      } catch (_) {}
    }
    await s?.close(force: true);
  }

  Future<void> stop() async {
    await _close();
    await _notesSub?.cancel();
    _notesSub = null;
    _engine = null;
    _changed();
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _event(String kind, String text, [Map<String, Object?> extra = const {}]) {
    events.add({'ts': DateTime.now().millisecondsSinceEpoch, 'kind': kind, 'text': text, ...extra});
    if (events.length > 400) events.removeRange(0, events.length - 400);
  }

  bool _authed(HttpRequest req) {
    final h = req.headers.value('authorization') ?? '';
    final given = h.startsWith('Bearer ') ? h.substring(7).trim() : (req.headers.value('x-mentos-token') ?? '');
    if (_token.isEmpty || given.length != _token.length) return false;
    var diff = 0;
    for (var i = 0; i < given.length; i++) {
      diff |= given.codeUnitAt(i) ^ _token.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> _handle(HttpRequest req) async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    final ip = req.connectionInfo?.remoteAddress.address ?? '?';
    final client = clients.putIfAbsent(ip, () => DevClient(ip))
      ..requests += 1
      ..lastSeen = t0;
    final path = req.uri.path;
    req.response.headers
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer');
    var status = 200;
    var streamed = false;
    try {
      // A second guard on top of the bind address.
      final remote = req.connectionInfo?.remoteAddress;
      if (!_lan && remote != null && !remote.isLoopback) {
        status = await _json(req, 403, {'error': 'only this device may connect'});
        return;
      }
      if (req.method == 'OPTIONS') {
        req.response.statusCode = status = 204;
        await req.response.close();
        return;
      }
      if (req.method == 'GET' && (path == '/' || path == '/index.html')) {
        req.response.headers
          ..contentType = ContentType.html
          ..set('Content-Security-Policy', "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data: blob:; frame-ancestors 'none'");
        req.response.write(devDashboardHtml);
        await req.response.close();
        return;
      }
      if (path == '/favicon.ico') {
        req.response.statusCode = status = 204;
        await req.response.close();
        return;
      }
      if (!path.startsWith('/v1/')) {
        status = await _json(req, 404, {'error': 'not found', 'try': '/ in a browser, or /v1/help'});
        return;
      }
      if (path == '/v1/help') {
        status = await _json(req, 200, {'routes': routes});
        return;
      }
      final (fails, until) = _fails[ip] ?? (0, 0);
      if (until > t0) {
        status = await _json(req, 429, {'error': 'too many wrong codes, wait a minute'});
        return;
      }
      if (!_authed(req)) {
        final n = fails + 1;
        _fails[ip] = (n, n >= 8 ? t0 + 60000 : 0);
        if (n >= 8) _event('api', 'blocked $ip for a minute after wrong access codes');
        status = await _json(req, 401, {'error': 'access code required: send "Authorization: Bearer <code>"'});
        return;
      }
      _fails.remove(ip);
      if (!client.authed) {
        client.authed = true;
        _event('api', 'signed in from $ip');
      }
      final e = _engine;
      if (e == null) {
        status = await _json(req, 503, {'error': 'node is not open'});
        return;
      }
      if (req.method == 'GET' && path == '/v1/stream') {
        streamed = true;
        await _stream(req, e);
        return;
      }
      if (req.method == 'GET' && path.startsWith('/v1/media/')) {
        status = await _media(req, e, path);
        return;
      }
      status = await _route(req, e, path);
    } catch (err) {
      try {
        status = await _json(req, 400, {'error': '$err'});
      } catch (_) {}
    } finally {
      if (!streamed && path != '/v1/logs' && path != '/v1/info' && !path.startsWith('/v1/media/')) {
        requests.add(DevRequest(t0, ip, req.method, path, status, DateTime.now().millisecondsSinceEpoch - t0));
        if (requests.length > 300) requests.removeRange(0, requests.length - 300);
      }
      _changed();
    }
  }

  static const routes = [
    'GET  /v1/info',
    'GET  /v1/me',
    'GET  /v1/status',
    'POST /v1/node            {action: "connect" | "disconnect"}',
    'GET  /v1/peers',
    'POST /v1/relay           {url} or {url: null} for automatic',
    'GET  /v1/chats',
    'GET  /v1/messages?scope=…&limit=50',
    'POST /v1/message         {scope, text}',
    'POST /v1/react           {scope, id, emoji, on}',
    'GET  /v1/activity',
    'GET  /v1/wallet',
    'POST /v1/pay             {to, amount, memo}',
    'GET  /v1/transfers',
    'GET  /v1/plugins',
    'POST /v1/plugins         single-file script, {manifest, source}, or {url}',
    'POST /v1/plugins/<id>/enable | disable | reload',
    'DELETE /v1/plugins/<id>',
    'GET  /v1/logs?since=<ms>',
    'GET  /v1/stream          live events (text/event-stream)',
    'GET  /v1/feed?limit=50',
    'POST /v1/post            {text}',
    'POST /v1/like            {id, on}',
    'GET  /v1/people',
    'POST /v1/follow          {id, on}',
    'GET  /v1/market?kind=item',
    'GET  /v1/plugins/registry',
    'GET  /v1/media/avatar/<id>',
    'GET  /v1/media/post/<postId>/<index>',
  ];

  final _streams = <HttpResponse>{};

  /// Server-sent events: engine changes, notes and API activity, as they happen.
  Future<void> _stream(HttpRequest req, Engine e) async {
    final res = req.response;
    res.headers
      ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..set('Cache-Control', 'no-store')
      ..set('X-Accel-Buffering', 'no');
    res.bufferOutput = false;
    void send(String event, Object data) {
      try {
        res.write('event: $event\ndata: ${jsonEncode(data)}\n\n');
      } catch (_) {}
    }

    _streams.add(res);
    send('hello', {'ts': DateTime.now().millisecondsSinceEpoch});
    final subs = <StreamSubscription<Object?>>[
      e.changes.listen((ch) => send('change', {'channels': ch.toList()})),
      e.notes.listen((n) => send('note', {'title': n.title, 'body': n.body, 'category': n.category, 'ts': n.at})),
      e.incoming.listen((m) => send('message', {'scope': m.scope, 'from': m.author, 'name': e.nameOf(m.author), 'text': m.text})),
      ?e.coin?.changes.listen((_) => send('change', {'channels': ['#coin']})),
    ];
    final ping = Timer.periodic(const Duration(seconds: 15), (_) {
      try {
        res.write(': ping\n\n');
      } catch (_) {}
    });
    final done = Completer<void>();
    unawaited(res.done.then((_) => done.complete(), onError: (_) => done.complete()));
    // Ends when the browser goes away or the API stops.
    final closer = _changes.stream.listen((_) {
      if (_server == null && !done.isCompleted) done.complete();
    });
    await done.future;
    ping.cancel();
    await closer.cancel();
    for (final s in subs) {
      await s.cancel();
    }
    _streams.remove(res);
    try {
      await res.close();
    } catch (_) {}
  }

  /// Decrypted images for the dashboard: avatars and post photos.
  Future<int> _media(HttpRequest req, Engine e, String path) async {
    final parts = path.split('/'); // '', v1, media, kind, ...
    MediaRef? ref;
    String owner = '';
    if (parts.length == 5 && parts[3] == 'avatar') {
      owner = parts[4];
      ref = owner == e.me.id ? e.myProfile.avatar : e.peerOf(owner).profile?.avatar;
    } else if (parts.length == 6 && parts[3] == 'post') {
      final post = e.feed().where((x) => x.id == parts[4]).firstOrNull;
      final i = int.tryParse(parts[5]) ?? -1;
      if (post != null && i >= 0 && i < post.media.length) {
        ref = post.media[i];
        owner = post.author;
      }
    }
    if (ref == null || !(ref.isImage)) return _json(req, 404, {'error': 'no such image'});
    final f = await e.media.open(ref, sources: [owner]).timeout(const Duration(seconds: 20), onTimeout: () => null);
    if (f == null) return _json(req, 404, {'error': 'image is not on this device yet'});
    req.response.headers
      ..set('content-type', ref.mime)
      ..set('cache-control', 'private, max-age=3600');
    await req.response.addStream(f.openRead());
    await req.response.close();
    return 200;
  }

  Future<int> _route(HttpRequest req, Engine e, String path) async {
    final m = req.method;
    final q = req.uri.queryParameters;
    final host = plugins?.call();

    if (m == 'GET' && path == '/v1/info') {
      final st = await e.netStatus();
      final balance = e.coin?.balance() ?? 0;
      return _json(req, 200, {
        'me': {'id': e.me.id, 'name': e.myProfile.name},
        'node': {'status': e.status, 'running': st.running, 'relay': st.relayUrl, 'links': st.links.length, 'topics': st.topics},
        'counts': {
          'chats': e.chats().length,
          'peers': e.onlinePeers.length,
          'unreadActivity': e.db.activity(limit: 200).where((a) => !a.seen).length,
          'transfers': e.transfers().where((t) => t.moving).length,
          'plugins': host?.installed.length ?? 0,
        },
        'wallet': {'minor': balance, 'mentos': Coin.format(balance)},
        'privacy': e.settings.privacy,
        'api': {'lan': lan, 'port': port, 'clients': clients.length, 'uptimeMs': DateTime.now().millisecondsSinceEpoch - _started},
      });
    }
    if (m == 'GET' && path == '/v1/me') return _json(req, 200, {'id': e.me.id, 'name': e.myProfile.name});
    if (m == 'GET' && path == '/v1/balance') {
      return _json(req, 200, {'minor': e.coin?.balance() ?? 0, 'mentos': Coin.format(e.coin?.balance() ?? 0)});
    }
    if (m == 'GET' && path == '/v1/status') {
      final st = await e.netStatus();
      return _json(req, 200, {
        'running': st.running,
        'status': e.status,
        'relay': st.relayUrl,
        'relays': st.relays,
        'directAddrs': st.directAddrs.length,
        'peers': st.links.length,
        'preferredRelay': e.preferredRelay,
        'engine': st.engine,
      });
    }
    if (m == 'POST' && path == '/v1/node') {
      final action = (await _body(req))['action'];
      if (action == 'connect') {
        await e.connectNode();
      } else if (action == 'disconnect') {
        await e.disconnectNode();
      } else {
        return _json(req, 400, {'error': 'action is connect or disconnect'});
      }
      _event('node', action as String);
      return _json(req, 200, {'status': e.status});
    }
    if (m == 'GET' && path == '/v1/peers') {
      final st = await e.netStatus();
      final links = {for (final l in st.links) l.peer: l};
      return _json(req, 200, {
        'peers': [
          for (final id in e.onlinePeers)
            {
              'id': id,
              'name': e.nameOf(id),
              'link': links[id]?.kind.name,
              'latencyMs': links[id]?.latencyMs,
              'bps': e.peerBps(id),
            },
        ],
        'atlas': e.atlas?.nodes().length ?? 0,
        'relays': [
          for (final r in e.atlas?.relays() ?? const <dynamic>[]) {'url': r.url, 'nodes': r.nodes.length},
        ],
      });
    }
    if (m == 'POST' && path == '/v1/relay') {
      final url = (await _body(req))['url'];
      if (url != null && (url is! String || Uri.tryParse(url)?.host.isEmpty != false)) {
        return _json(req, 400, {'error': 'url must be an http(s) relay address or null'});
      }
      e.preferRelay(url as String?);
      _event('node', url == null ? 'relay: automatic' : 'relay: $url');
      return _json(req, 200, {'preferredRelay': e.preferredRelay});
    }
    if (m == 'GET' && path == '/v1/chats') {
      return _json(req, 200, {
        'chats': [
          for (final c in e.chats())
            {
              'scope': c.scope,
              'peer': c.peer,
              'title': c.group ? c.title : e.nameOf(c.peer),
              'group': c.group,
              'unread': c.unread,
              'online': c.online,
              'last': c.last?.text ?? '',
              'ts': c.sortTs,
            },
        ],
      });
    }
    if (m == 'GET' && path == '/v1/messages') {
      final scope = q['scope'] ?? '';
      if (!scope.startsWith('dm:') && !scope.startsWith('gdm:')) return _json(req, 400, {'error': 'scope is required'});
      final limit = (int.tryParse(q['limit'] ?? '') ?? 50).clamp(1, 500);
      final all = e.messages(scope);
      return _json(req, 200, {
        'messages': [
          for (final msg in all.skip(max(0, all.length - limit)))
            {
              'id': msg.item.id,
              'author': msg.item.e.author,
              'name': e.nameOf(msg.item.e.author),
              'mine': msg.mine,
              'text': msg.text,
              'ts': msg.item.e.ts,
              'edited': msg.edited,
              'media': msg.media.length,
              'reactions': msg.reactions,
            },
        ],
      });
    }
    if (m == 'POST' && path == '/v1/message') {
      final body = await _body(req);
      final scope = body['scope'], text = body['text'];
      if (scope is! String || text is! String || text.trim().isEmpty) return _json(req, 400, {'error': 'scope and text are required'});
      final sent = await e.sendMessage(scope, text: text.trim());
      _event('chat', 'sent a message in $scope');
      return _json(req, 200, {'id': sent.id});
    }
    if (m == 'POST' && path == '/v1/react') {
      final body = await _body(req);
      final scope = body['scope'], id = body['id'], emoji = body['emoji'];
      if (scope is! String || id is! String || emoji is! String) return _json(req, 400, {'error': 'scope, id and emoji are required'});
      await e.react(scope, id, emoji, on: body['on'] != false);
      return _json(req, 200, {'ok': true});
    }
    if (m == 'GET' && path == '/v1/activity') {
      return _json(req, 200, {
        'activity': [
          for (final a in e.db.activity(limit: 100))
            {'id': a.id, 'kind': a.kind, 'actor': a.actor, 'name': e.nameOf(a.actor), 'text': a.text, 'ts': a.ts, 'seen': a.seen},
        ],
      });
    }
    if (m == 'GET' && path == '/v1/wallet') {
      final coin = e.coin;
      final b = coin?.balance() ?? 0;
      return _json(req, 200, {
        'minor': b,
        'mentos': Coin.format(b),
        'txs': [
          for (final tx in (coin?.history() ?? const <CoinTx>[]).take(50))
            {
              'hash': tx.hash,
              'kind': tx.kind,
              'from': tx.from,
              'to': tx.to,
              'fromName': e.nameOf(tx.from),
              'toName': e.nameOf(tx.to),
              'amount': tx.amount,
              'mentos': Coin.format(tx.amount),
              'memo': tx.memo,
              'ts': tx.ts,
            },
        ],
      });
    }
    if (m == 'POST' && path == '/v1/pay') {
      final body = await _body(req);
      final to = body['to'], amount = body['amount'];
      final memo = body['memo'] is String ? body['memo'] as String : '';
      final minor = amount is num ? amount.toInt() : Coin.parse('$amount');
      if (to is! String || minor == null || minor <= 0) return _json(req, 400, {'error': 'to and a positive amount are required'});
      final tx = await e.coin?.pay(to, minor, memo: memo);
      _event('wallet', 'paid ${Coin.format(minor)} to ${e.nameOf(to)}');
      return _json(req, 200, {'hash': tx?.hash});
    }
    if (m == 'GET' && path == '/v1/transfers') {
      return _json(req, 200, {
        'transfers': [
          for (final t in e.transfers())
            {
              'id': t.id,
              'peer': t.peer,
              'name': e.nameOf(t.peer),
              'file': t.media.name,
              'size': t.total,
              'done': t.done,
              'dir': t.dir.name,
              'state': t.state.name,
              'bps': t.bps,
            },
        ],
      });
    }
    if (m == 'GET' && path == '/v1/feed') {
      final limit = (int.tryParse(q['limit'] ?? '') ?? 50).clamp(1, 200);
      return _json(req, 200, {
        'posts': [
          for (final post in e.feed().take(limit))
            {
              'id': post.id,
              'author': post.author,
              'name': e.nameOf(post.author),
              'text': post.text,
              'ts': post.item.e.ts,
              'likes': post.likes,
              'liked': post.liked,
              'comments': post.comments,
              'views': post.views,
              'ai': post.ai,
              'nsfw': post.nsfw,
              'edited': post.edited,
              'mine': post.author == e.me.id,
              'media': [
                for (final (i, md) in post.media.indexed) {'i': i, 'mime': md.mime, 'name': md.name, 'w': md.width, 'h': md.height},
              ],
            },
        ],
      });
    }
    if (m == 'POST' && path == '/v1/post') {
      final text = (await _body(req))['text'];
      if (text is! String || text.trim().isEmpty || text.length > 5000) return _json(req, 400, {'error': 'text is required (up to 5000 characters)'});
      final env = await e.createPost(text: text.trim());
      _event('feed', 'posted from the dashboard');
      return _json(req, 200, {'id': env.id});
    }
    if (m == 'POST' && path == '/v1/like') {
      final body = await _body(req);
      final post = e.feed().where((x) => x.id == body['id']).firstOrNull;
      if (post == null) return _json(req, 404, {'error': 'no such post'});
      await e.like(post.scope, post.id, body['on'] != false);
      return _json(req, 200, {'ok': true});
    }
    if (m == 'GET' && path == '/v1/people') {
      return _json(req, 200, {
        'people': [
          for (final pe in e.people())
            if (pe.id != e.me.id)
              {
                'id': pe.id,
                'name': pe.name,
                'bio': pe.profile?.bio ?? '',
                'iFollow': pe.iFollow,
                'followsMe': pe.followsMe,
                'blocked': pe.blocked,
                'online': e.isOnline(pe.id),
                'lastSeen': pe.lastSeen,
                'avatar': pe.profile?.avatar != null,
                'scope': Scope.dm(e.me.id, pe.id),
              },
        ],
      });
    }
    if (m == 'POST' && path == '/v1/follow') {
      final body = await _body(req);
      final id = body['id'];
      if (id is! String || id.length != 64) return _json(req, 400, {'error': 'id is required'});
      await e.follow(id, body['on'] != false);
      return _json(req, 200, {'ok': true});
    }
    if (m == 'GET' && path == '/v1/market') {
      final market = e.market;
      if (market == null) return _json(req, 503, {'error': 'market is not ready'});
      final kind = q['kind'];
      return _json(req, 200, {
        'listings': [
          for (final l in market.listings(kind: kind == null || kind.isEmpty ? null : kind).take(200))
            if (!l.deleted)
              {
                'id': l.id,
                'kind': l.kind,
                'title': l.title,
                'about': l.about,
                'price': l.price,
                'mentos': Coin.format(l.price),
                'author': l.author,
                'name': e.nameOf(l.author),
                'ts': l.ts,
                'mine': l.author == e.me.id,
              },
        ],
      });
    }
    if (m == 'GET' && path == '/v1/plugins/registry') {
      if (host == null) return _json(req, 503, {'error': 'plugins are not loaded'});
      final r = await host.browse();
      return _json(req, 200, {
        'failed': r.failed,
        'plugins': [
          for (final en in r.entries)
            {
              ...en.manifest.toJson(),
              'manifestUrl': en.manifestUrl.toString(),
              'installed': host.plugin(en.manifest.id)?.manifest.version,
            },
        ],
      });
    }
    if (path == '/v1/plugins' || path.startsWith('/v1/plugins/')) {
      if (host == null) return _json(req, 503, {'error': 'plugins are not loaded'});
      return _plugins(req, host, path);
    }
    if (m == 'GET' && path == '/v1/logs') {
      final since = int.tryParse(q['since'] ?? '') ?? 0;
      return _json(req, 200, {
        'now': DateTime.now().millisecondsSinceEpoch,
        'requests': [for (final r in requests) if (r.ts > since) r.toJson()],
        'events': [for (final ev in events) if ((ev['ts'] as int) > since) ev],
        'plugins': [for (final l in host?.logs(since: since) ?? const <PluginLog>[]) l.toJson()],
      });
    }
    return _json(req, 404, {'error': 'unknown route', 'routes': routes});
  }

  Future<int> _plugins(HttpRequest req, PluginHost host, String path) async {
    final m = req.method;
    if (m == 'GET' && path == '/v1/plugins') {
      return _json(req, 200, {
        'plugins': [
          for (final p in host.installed)
            {
              ...p.manifest.toJson(),
              'enabled': p.enabled,
              'running': host.isRunning(p.id),
              'error': host.errorOf(p.id),
              'origin': p.origin,
              'commands': [for (final c in host.commands.where((c) => c.plugin == p.id)) c.name],
              'pages': [for (final pg in host.pagesOf(p.id)) pg.title],
            },
        ],
      });
    }
    if (m == 'POST' && path == '/v1/plugins') {
      final raw = await utf8.decoder.bind(req).join();
      if (raw.length > PluginHost.maxScript) return _json(req, 413, {'error': 'script is too large'});
      PluginManifest? manifest;
      var source = raw;
      var origin = 'dev';
      final header = PluginManifest.fromHeader(raw);
      if (header != null) {
        manifest = header;
      } else {
        final j = jsonDecode(raw);
        if (j is! Map) return _json(req, 400, {'error': 'send a single-file script, {manifest, source} or {url}'});
        if (j['url'] is String) {
          final u = Uri.parse(j['url'] as String);
          final (mm, src) = await host.fetchPackage(u, pinnedSha: j['sha256'] is String ? j['sha256'] as String : null);
          manifest = mm;
          source = src;
          origin = u.toString();
        } else {
          manifest = PluginManifest.parse(j['manifest']);
          source = j['source'] is String ? j['source'] as String : (throw const FormatException('source is required'));
        }
      }
      final p = host.install(manifest, source, origin: origin);
      _event('plugin', 'installed ${p.manifest.name} ${p.manifest.version}');
      return _json(req, 200, {'id': p.id, 'running': host.isRunning(p.id), 'error': host.errorOf(p.id)});
    }
    final parts = path.split('/'); // '', v1, plugins, id, action
    final id = parts.length > 3 ? parts[3] : '';
    if (host.plugin(id) == null) return _json(req, 404, {'error': 'no plugin "$id"'});
    if (m == 'DELETE' && parts.length == 4) {
      host.uninstall(id);
      _event('plugin', 'removed $id');
      return _json(req, 200, {'ok': true});
    }
    if (m == 'POST' && parts.length == 5) {
      switch (parts[4]) {
        case 'enable':
          host.setEnabled(id, true);
        case 'disable':
          host.setEnabled(id, false);
        case 'reload':
          host.reload(id);
        default:
          return _json(req, 404, {'error': 'unknown action'});
      }
      return _json(req, 200, {'ok': true, 'running': host.isRunning(id), 'error': host.errorOf(id)});
    }
    return _json(req, 404, {'error': 'unknown route'});
  }

  Future<Map<String, dynamic>> _body(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    if (raw.trim().isEmpty) return const {};
    final j = jsonDecode(raw);
    return j is Map ? j.cast<String, dynamic>() : const {};
  }

  Future<int> _json(HttpRequest req, int code, Map<String, Object?> body) async {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
    return code;
  }
}

final devApiProvider = Provider<DevApi>((ref) {
  final api = DevApi()..plugins = () => ref.read(pluginHostProvider);
  ref.onDispose(api.stop);
  void sync() {
    final s = ref.read(settingsProvider);
    final engine = ref.read(maybeEngineProvider);
    if (!s.devMode || engine == null) {
      unawaited(api.stop());
      return;
    }
    if (s.devToken.isEmpty) {
      // First switch-on: mint the access code, which re-runs sync.
      Future.microtask(() => ref.read(settingsProvider.notifier).update((x) => x.copyWith(devToken: DevApi.newToken())));
      return;
    }
    unawaited(api.start(engine, token: s.devToken, lan: s.devLan));
  }

  ref.listen<Settings>(settingsProvider, (a, b) {
    if (a?.devMode != b.devMode || a?.devLan != b.devLan || a?.devToken != b.devToken) sync();
  });
  ref.listen(maybeEngineProvider, (_, _) => sync());
  sync();
  return api;
});

/// Ticks when the developer API serves a request, for the in-app console.
final devApiTickProvider = StreamProvider.autoDispose<int>((ref) {
  final api = ref.watch(devApiProvider);
  var n = 0;
  return Stream.multi((out) {
    out.add(n);
    final sub = api.changes.listen((_) => out.add(++n));
    out.onCancel = sub.cancel;
  });
});
