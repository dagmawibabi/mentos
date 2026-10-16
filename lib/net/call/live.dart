import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/crypto/crypto.dart';
import '../../data/models.dart';
import '../engine.dart';
import '../transport.dart';
import 'calls.dart';
import 'media.dart';

/// Live chat and reactions ride the same datagrams as media:
///   [3] [utf8 json]
abstract final class LivePacket {
  static const chat = 3;
  static const maxText = 300;

  static Uint8List encode(Map<String, Object?> m) {
    final body = utf8.encode(jsonEncode(m));
    return Uint8List(1 + body.length)
      ..[0] = chat
      ..setRange(1, 1 + body.length, body);
  }

  static Map<String, dynamic>? decode(Uint8List p) {
    if (p.length < 2 || p[0] != chat || p.length > 1200) return null;
    try {
      final m = jsonDecode(utf8.decode(Uint8List.sublistView(p, 1)));
      return m is Map ? m.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }
}

class LiveChat {
  const LiveChat(this.from, this.text, this.at, {this.heart = false});
  final String from;
  final String text;
  final int at;
  final bool heart;
}

class LiveState {
  LiveState({required this.id, required this.owner, required this.channel, required this.video, required this.hosting});

  final String id;
  final String owner;
  final String channel;
  final bool video;

  /// This device is the one streaming.
  final bool hosting;
  bool live = true;
  bool joined = false;
  bool mic = true;
  bool camera = false;
  int started = nowMs();
  String? reason;

  /// Hosting: who is watching now. Watching: count the host reports.
  final viewers = <String>{};
  int viewerCount = 0;
  final chat = <LiveChat>[];
  Uint8List? frame;
  double level = 0;
  int hearts = 0;
  String? reaction;

  /// The channel post that announced this stream.
  String? postId;
}

/// One-to-many live audio and video on a channel. The host serves every
/// viewer directly over the call protocol, up to [maxViewers]; viewers
/// only receive media. Chat and hearts go to the host, which relays them.
class LiveManager {
  LiveManager(this.engine, this.link, {this.devices}) {
    _subs.add(engine.callSignals.listen((s) => _onSignal(s.from, s.m)));
    _subs.add(engine.mediaEvents.listen(_onMedia));
  }

  static const maxViewers = 16;

  final Engine engine;
  final MediaLink link;
  final CallDevices? devices;

  final _subs = <StreamSubscription>[];
  final _changes = StreamController<LiveState?>.broadcast();
  LiveState? _live;
  Timer? _pump;
  Timer? _count;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<Uint8List>? _camSub;
  final _jitter = JitterBuffer(target: 5, max: 20);
  final _video = VideoAssembler();
  int _seq = 0;
  int _frame = 0;

  Stream<LiveState?> get changes => _changes.stream;
  LiveState? get current => _live;
  String get _me => engine.me.id;

  void _changed() => _changes.add(_live);

  // ---------------------------------------------------------------------------
  // hosting

  /// Goes live on [channel] and announces it with a post subscribers see.
  Future<LiveState> start(Bcast channel, {bool video = true, String title = ''}) async {
    if (_live?.live ?? false) throw StateError('Already live or watching');
    if (channel.owner != _me) throw StateError('Only the channel owner can go live');
    final id = toHex(randomBytes(12));
    final s = LiveState(id: id, owner: _me, channel: channel.id, video: video, hosting: true)
      ..joined = true
      ..camera = video;
    _live = s;
    link.callListen(id, const []);
    final post = await engine.createPost(
      text: title.trim().isNotEmpty ? title.trim() : '🔴 Live now',
      bcastId: channel.id,
      live: {'id': id, 'video': video},
    );
    s.postId = post.id;
    _startPump();
    _count = Timer.periodic(const Duration(seconds: 3), (_) => _broadcast({'t': 'count', 'n': s.viewers.length}));
    await _startDevices(s, capture: true);
    _changed();
    return s;
  }

  void _admit(LiveState s, String viewer) {
    if (s.viewers.length >= maxViewers && !s.viewers.contains(viewer)) {
      unawaited(engine.sendCallSignal(viewer, {'op': 'live-full', 'id': s.id}));
      return;
    }
    link.callListen(s.id, [viewer]);
    unawaited(engine.sendCallSignal(viewer, {'op': 'live-ok', 'id': s.id, 'video': s.video}));
  }

  void _broadcast(Map<String, Object?> m) {
    final s = _live;
    if (s == null || !s.hosting) return;
    link.callSend(s.id, LivePacket.encode(m));
  }

  /// Ends the stream for everyone and marks the announcement as over.
  Future<void> stop() async {
    final s = _live;
    if (s == null || !s.live) return;
    if (s.hosting) {
      for (final v in s.viewers) {
        unawaited(engine.sendCallSignal(v, {'op': 'live-end', 'id': s.id}));
      }
      final post = s.postId == null ? null : engine.db.item(s.postId!);
      if (post != null) {
        final mins = (nowMs() - s.started) ~/ 60000;
        await engine.edit(post.e.scope, post.id, 'Was live · ${mins < 1 ? 'under a minute' : '$mins min'}');
      }
    } else {
      unawaited(engine.sendCallSignal(s.owner, {'op': 'live-leave', 'id': s.id}));
    }
    await _finish('ended');
  }

  // ---------------------------------------------------------------------------
  // watching

  /// Asks the host of [liveId] to let this device watch.
  Future<LiveState> watch(String owner, String channel, String liveId, {bool video = true}) async {
    if (_live?.live ?? false) {
      if (_live!.id == liveId) return _live!;
      throw StateError('Already live or watching');
    }
    if (owner == _me) throw StateError('That is your own stream');
    final s = LiveState(id: liveId, owner: owner, channel: channel, video: video, hosting: false);
    _live = s;
    link.callListen(liveId, [owner]);
    final ok = await engine.sendCallSignal(owner, {'op': 'live-join', 'id': liveId});
    if (!ok) {
      await _finish('unreachable');
      return s;
    }
    _changed();
    return s;
  }

  void sendChat(String text) {
    final s = _live;
    final t = text.trim();
    if (s == null || !s.live || t.isEmpty) return;
    final clipped = t.length > LivePacket.maxText ? t.substring(0, LivePacket.maxText) : t;
    if (s.hosting) {
      s.chat.add(LiveChat(_me, clipped, nowMs()));
      _broadcast({'t': 'chat', 'from': _me, 'text': clipped});
      _changed();
    } else {
      link.callSend(s.id, LivePacket.encode({'t': 'chat', 'text': clipped}));
    }
  }

  void sendReact(String emoji) {
    final s = _live;
    if (s == null || !s.live || emoji.isEmpty) return;
    s.reaction = emoji;
    if (s.hosting) {
      _broadcast({'t': 'react', 'emoji': emoji});
    } else {
      link.callSend(s.id, LivePacket.encode({'t': 'react', 'emoji': emoji}));
    }
    _changed();
  }

  void sendHeart() {
    final s = _live;
    if (s == null || !s.live) return;
    if (s.hosting) return;
    link.callSend(s.id, LivePacket.encode({'t': 'heart'}));
  }

  void setMic(bool on) {
    _live?.mic = on;
    _changed();
  }

  Future<void> setCamera(bool on) async {
    _live?.camera = on;
    _changed();
    await devices?.setVideo(on);
  }

  // ---------------------------------------------------------------------------
  // signals and media

  void _onSignal(String from, Map<String, dynamic> m) {
    final s = _live;
    final id = m['id'];
    if (s == null || id != s.id) return;
    switch (m['op']) {
      case 'live-join' when s.hosting && s.live:
        _admit(s, from);
      case 'live-leave' when s.hosting:
        s.viewers.remove(from);
        link.callDropPeer(s.id, from);
        _changed();
      case 'live-ok' when !s.hosting && from == s.owner:
        link.callDial(s.id, s.owner);
      case 'live-full' when !s.hosting && from == s.owner:
        unawaited(_finish('full'));
      case 'live-end' when !s.hosting && from == s.owner:
        unawaited(_finish('ended'));
    }
  }

  void _onMedia(MediaEvent ev) {
    final s = _live;
    if (s == null || ev.call != s.id || !s.live) return;
    if (s.hosting) {
      ev.up ? s.viewers.add(ev.peer) : s.viewers.remove(ev.peer);
      s.viewerCount = s.viewers.length;
    } else if (ev.peer == s.owner) {
      if (ev.up && !s.joined) {
        s.joined = true;
        _startPump();
        unawaited(_startDevices(s, capture: false));
      } else if (!ev.up) {
        unawaited(_finish('lost'));
        return;
      }
    }
    _changed();
  }

  void _startPump() {
    _pump?.cancel();
    _pump = Timer.periodic(const Duration(milliseconds: 10), (_) => drain());
  }

  Future<void> _startDevices(LiveState s, {required bool capture}) async {
    final d = devices;
    if (d == null) return;
    try {
      await d.start(video: s.video, pull: pull, capture: capture);
      if (!capture) return;
      _micSub = d.mic.listen((f) {
        if (s.live && s.mic) sendAudio(f);
      });
      _camSub = d.camera.listen((j) {
        if (s.live && s.camera) sendVideo(j);
      });
    } catch (_) {}
  }

  void sendAudio(Uint8List pcm) {
    final s = _live;
    if (s == null || !s.hosting) return;
    link.callSend(s.id, MediaPacket.encodeAudio(_seq, pcm));
    _seq = (_seq + 1) & 0xffff;
  }

  void sendVideo(Uint8List jpeg) {
    final s = _live;
    if (s == null || !s.hosting) return;
    final max = link.callMaxDatagram(s.id);
    for (final p in MediaPacket.encodeVideo(_frame, jpeg, max)) {
      link.callSend(s.id, p);
    }
    _frame = (_frame + 1) & 0xffff;
  }

  /// Hosting: relays viewers' chat. Watching: buffers the host's media.
  void drain() {
    final s = _live;
    if (s == null || !s.live) return;
    var changed = false;
    for (var i = 0; i < 200; i++) {
      final p = link.callRecv(s.id);
      if (p == null) break;
      if (p.data.isEmpty) continue;
      if (s.hosting) {
        if (!s.viewers.contains(p.peer)) continue;
        final m = LivePacket.decode(p.data);
        if (m == null) continue;
        if (m['t'] == 'heart') {
          s.hearts++;
          _broadcast({'t': 'heart'});
          changed = true;
        } else if (m['t'] == 'react' && m['emoji'] is String) {
          s.reaction = m['emoji'] as String;
          _broadcast({'t': 'react', 'emoji': s.reaction});
          changed = true;
        } else if (m['t'] == 'chat' && m['text'] is String) {
          final text = (m['text'] as String).trim();
          if (text.isEmpty || text.length > LivePacket.maxText) continue;
          s.chat.add(LiveChat(p.peer, text, nowMs()));
          _broadcast({'t': 'chat', 'from': p.peer, 'text': text});
          changed = true;
        }
        continue;
      }
      if (p.peer != s.owner) continue;
      switch (p.data[0]) {
        case MediaPacket.audio when p.data.length == MediaPacket.audioHeader + MediaPacket.frameBytes:
          _jitter.push((p.data[1] << 8) | p.data[2], Uint8List.sublistView(p.data, MediaPacket.audioHeader));
        case MediaPacket.video:
          final jpeg = _video.push(p.data);
          if (jpeg != null) {
            s.frame = jpeg;
            changed = true;
          }
        case LivePacket.chat:
          final m = LivePacket.decode(p.data);
          if (m == null) continue;
          switch (m['t']) {
            case 'chat' when m['from'] is String && m['text'] is String:
              final text = m['text'] as String;
              if (text.length <= LivePacket.maxText) s.chat.add(LiveChat(m['from'] as String, text, nowMs()));
            case 'heart':
              s.hearts++;
            case 'react' when m['emoji'] is String:
              s.reaction = m['emoji'] as String;
            case 'count' when m['n'] is num:
              s.viewerCount = (m['n'] as num).toInt().clamp(0, maxViewers);
          }
          changed = true;
      }
    }
    if (s.chat.length > 200) s.chat.removeRange(0, s.chat.length - 200);
    if (changed) _changed();
  }

  Uint8List pull() {
    final f = _jitter.pull();
    _live?.level = f == null ? 0 : pcmLevel(f);
    return f ?? Uint8List(MediaPacket.frameBytes);
  }

  Future<void> _finish(String reason) async {
    final s = _live;
    if (s == null || !s.live) return;
    s.live = false;
    s.camera = false;
    s.reason = reason;
    _changed();
    _pump?.cancel();
    _count?.cancel();
    await _micSub?.cancel();
    await _camSub?.cancel();
    _micSub = null;
    _camSub = null;
    link.callClose(s.id);
    await devices?.stop();
    _changed();
  }

  Future<void> dispose() async {
    await stop();
    for (final s in _subs) {
      await s.cancel();
    }
    await _changes.close();
  }
}
