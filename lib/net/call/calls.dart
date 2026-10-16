import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../../core/crypto/crypto.dart';
import '../../data/models.dart';
import '../engine.dart';
import '../transport.dart';
import 'media.dart';

enum CallPhase { outgoing, incoming, connecting, active, ended }

/// Microphone, camera and speaker. The app supplies a platform one; tests
/// use none (signalling and media routing still run).
abstract class CallDevices {
  /// 20 ms PCM16 mono 16 kHz frames from the microphone.
  Stream<Uint8List> get mic;

  /// JPEG frames from the camera while video is on.
  Stream<Uint8List> get camera;

  /// Starts audio (and video) I/O. [pull] supplies the next 20 ms to play.
  /// With [capture] false only playback runs (watching a live stream).
  Future<void> start({required bool video, required Uint8List Function() pull, bool capture = true});
  Future<void> setVideo(bool on);
  Future<void> switchCamera();

  Future<void> stop();
}

class CallState {
  CallState({
    required this.id,
    required this.members,
    required this.video,
    required this.outgoing,
    required this.from,
    required this.started,
  });

  final String id;

  /// Everyone in the call, including this device.
  final List<String> members;
  final bool video;
  final bool outgoing;

  /// Who started it.
  final String from;
  final int started;
  CallPhase phase = CallPhase.outgoing;
  int? answered;
  String? reason;

  /// Accepted the call (always includes the caller).
  final joined = <String>{};

  /// Media connection is up.
  final connected = <String>{};
  bool mic = true;
  bool camera = false;
  final remote = <String, ({bool mic, bool camera})>{};
  final levels = <String, double>{};
  final frames = <String, Uint8List>{};
  final rtt = <String, double>{};

  bool get group => members.length > 2;
  bool get live => phase != CallPhase.ended;
  Duration get elapsed =>
      answered == null ? Duration.zero : Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - answered!);
}

/// A finished call, for the call log.
class CallRecord {
  const CallRecord({
    required this.id,
    required this.peers,
    required this.video,
    required this.outgoing,
    required this.at,
    required this.seconds,
    required this.result,
  });

  final String id;
  final List<String> peers;
  final bool video;
  final bool outgoing;
  final int at;
  final int seconds;

  /// answered | missed | declined | busy | no answer | failed | cancelled
  final String result;

  Map<String, Object> toJson() =>
      {'id': id, 'p': peers, 'v': video, 'o': outgoing, 'at': at, 's': seconds, 'r': result};

  static CallRecord? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['p'] is! List) return null;
    return CallRecord(
      id: j['id'] as String,
      peers: [for (final p in j['p'] as List) if (p is String) p],
      video: j['v'] == true,
      outgoing: j['o'] == true,
      at: j['at'] is num ? (j['at'] as num).toInt() : 0,
      seconds: j['s'] is num ? (j['s'] as num).toInt() : 0,
      result: j['r'] is String ? j['r'] as String : 'failed',
    );
  }
}

/// Runs calls for one engine: signalling over the direct channel, media
/// over [MediaLink] datagrams, a full mesh for groups of up to [maxMembers].
class CallManager {
  CallManager(this.engine, this.link, {this.devices, Duration? ringFor, Duration? connectFor})
      : ringFor = ringFor ?? const Duration(seconds: 45),
        connectFor = connectFor ?? const Duration(seconds: 25) {
    _subs.add(engine.callSignals.listen((s) => _onSignal(s.from, s.m)));
    _subs.add(engine.mediaEvents.listen(_onMedia));
  }

  static const maxMembers = 4;

  final Engine engine;
  final MediaLink link;
  final CallDevices? devices;
  final Duration ringFor;
  final Duration connectFor;

  final _subs = <StreamSubscription>[];
  final _changes = StreamController<CallState?>.broadcast();
  CallState? _call;
  Timer? _ring;
  Timer? _connect;
  Timer? _pump;
  Timer? _stats;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<Uint8List>? _camSub;
  final _jitter = <String, JitterBuffer>{};
  final _video = <String, VideoAssembler>{};
  int _seq = 0;
  int _frame = 0;

  /// The current call, or null. Fires on every change.
  Stream<CallState?> get changes => _changes.stream;
  CallState? get current => _call;

  String get _me => engine.me.id;

  static bool _validId(Object? id) => id is String && RegExp(r'^[A-Za-z0-9_-]{8,40}$').hasMatch(id);

  void _changed() => _changes.add(_call);

  // ---------------------------------------------------------------------------
  // starting, answering, ending

  /// Calls [peers]. Returns the call, or throws when already in one.
  Future<CallState> start(List<String> peers, {bool video = false}) async {
    if (_call?.live ?? false) throw StateError('Already in a call');
    final others = peers.where((p) => p != _me).toSet().toList();
    if (others.isEmpty) throw ArgumentError('Nobody to call');
    if (others.length + 1 > maxMembers) throw ArgumentError('Calls are limited to $maxMembers people');
    final id = toHex(randomBytes(12));
    final c = CallState(
      id: id,
      members: [_me, ...others],
      video: video,
      outgoing: true,
      from: _me,
      started: nowMs(),
    )
      ..joined.add(_me)
      ..camera = video;
    _call = c;
    link.callListen(id, others);
    for (final p in others) {
      unawaited(engine.sendCallSignal(p, {'op': 'offer', 'id': id, 'video': video, 'members': c.members}));
    }
    _ring = Timer(ringFor, () => _end(c.joined.length > 1 ? 'failed' : 'no answer', notify: true));
    _changed();
    return c;
  }

  Future<void> accept() async {
    final c = _call;
    if (c == null || c.phase != CallPhase.incoming) return;
    _ring?.cancel();
    c.phase = CallPhase.connecting;
    c.joined.add(_me);
    c.camera = c.video;
    link.callListen(c.id, c.members.where((m) => m != _me).toList());
    for (final p in c.members.where((m) => m != _me)) {
      unawaited(engine.sendCallSignal(p, {'op': 'accept', 'id': c.id}));
      if (c.joined.contains(p)) _dialIfMine(c, p);
    }
    _armConnect(c);
    await _startMedia(c);
    _changed();
  }

  Future<void> decline() async {
    final c = _call;
    if (c == null || c.phase != CallPhase.incoming) return;
    unawaited(engine.sendCallSignal(c.from, {'op': 'decline', 'id': c.id}));
    await _end('declined', send: false);
  }

  Future<void> hangUp() async {
    final c = _call;
    if (c == null || !c.live) return;
    await _end(c.phase == CallPhase.outgoing ? 'cancelled' : 'answered');
  }

  void setMic(bool on) => _setLocal(mic: on);
  Future<void> setCamera(bool on) async {
    _setLocal(camera: on);
    await devices?.setVideo(on);
  }

  Future<void> switchCamera() async => devices?.switchCamera();

  void _setLocal({bool? mic, bool? camera}) {
    final c = _call;
    if (c == null) return;
    if (mic != null) c.mic = mic;
    if (camera != null) c.camera = camera;
    for (final p in c.members.where((m) => m != _me)) {
      unawaited(engine.sendCallSignal(p, {'op': 'state', 'id': c.id, 'mic': c.mic, 'cam': c.camera}));
    }
    _changed();
  }

  /// The lower node id dials, so a pair never opens two connections.
  void _dialIfMine(CallState c, String peer) {
    if (_me.compareTo(peer) < 0 && !c.connected.contains(peer)) link.callDial(c.id, peer);
  }

  void _armConnect(CallState c) {
    _connect?.cancel();
    _connect = Timer(connectFor, () {
      if (identical(_call, c) && c.connected.isEmpty && c.live) _end('failed', notify: false);
    });
  }

  Future<void> _end(String result, {bool send = true, bool notify = false}) async {
    final c = _call;
    if (c == null || c.phase == CallPhase.ended) return;
    c.phase = CallPhase.ended;
    c.reason = result;
    _ring?.cancel();
    _connect?.cancel();
    _pump?.cancel();
    _stats?.cancel();
    if (send) {
      for (final p in c.members.where((m) => m != _me)) {
        unawaited(engine.sendCallSignal(p, {'op': 'end', 'id': c.id}));
      }
    }
    link.callClose(c.id);
    await _micSub?.cancel();
    await _camSub?.cancel();
    _micSub = null;
    _camSub = null;
    await devices?.stop();
    _jitter.clear();
    _video.clear();
    _log(c, result);
    if (notify && !c.outgoing && c.answered == null) {
      engine.noteActivity(
        Activity(id: 'call:${c.id}', kind: 'call', actor: c.from, ts: nowMs(), text: c.video ? 'video' : 'voice'),
        title: engine.nameOf(c.from),
        body: 'Missed ${c.video ? 'video' : 'voice'} call',
        route: '/calls',
        category: 'call',
      );
    }
    _changed();
  }

  void _log(CallState c, String result) {
    final rec = CallRecord(
      id: c.id,
      peers: c.members.where((m) => m != _me).toList(),
      video: c.video,
      outgoing: c.outgoing,
      at: c.started,
      seconds: c.elapsed.inSeconds,
      result: c.answered != null ? 'answered' : result,
    );
    final all = [rec, ...history()].take(100).toList();
    engine.db.setKv('callLog', jsonEncode([for (final r in all) r.toJson()]));
  }

  List<CallRecord> history() {
    try {
      final raw = engine.db.getKv('callLog');
      if (raw == null) return const [];
      return [for (final j in jsonDecode(raw) as List) ?CallRecord.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }

  void clearHistory() => engine.db.setKv('callLog', '[]');

  // ---------------------------------------------------------------------------
  // signalling

  void _onSignal(String from, Map<String, dynamic> m) {
    final id = m['id'];
    if (!_validId(id)) return;
    final c = _call;
    switch (m['op']) {
      case 'offer':
        final members = [for (final x in (m['members'] as List?) ?? const []) if (x is String) x];
        if (!members.contains(from) || !members.contains(_me) || members.length > maxMembers) return;
        if (members.toSet().length != members.length) return;
        if (c != null && c.live) {
          if (c.id != id) unawaited(engine.sendCallSignal(from, {'op': 'busy', 'id': id}));
          return;
        }
        final next = CallState(
          id: id as String,
          members: members,
          video: m['video'] == true,
          outgoing: false,
          from: from,
          started: nowMs(),
        )
          ..phase = CallPhase.incoming
          ..joined.add(from);
        _call = next;
        _ring = Timer(ringFor, () => _end('missed', send: false, notify: true));
        engine.noteActivity(
          Activity(id: 'ring:$id', kind: 'call', actor: from, ts: nowMs(), text: next.video ? 'video' : 'voice'),
          title: engine.nameOf(from),
          body: 'Incoming ${next.video ? 'video' : 'voice'} call${next.group ? ' · group' : ''}',
          route: '/call',
          category: 'call',
        );
        unawaited(engine.sendCallSignal(from, {'op': 'ring', 'id': id}));
        _changed();
      case 'accept':
        if (c == null || c.id != id || !c.members.contains(from) || !c.live) return;
        c.joined.add(from);
        if (c.phase == CallPhase.outgoing) {
          _ring?.cancel();
          c.phase = CallPhase.connecting;
          _armConnect(c);
          unawaited(_startMedia(c));
        }
        if (c.joined.contains(_me)) _dialIfMine(c, from);
        _changed();
      case 'decline' || 'busy':
        if (c == null || c.id != id || !c.members.contains(from)) return;
        c.remote.remove(from);
        if (!c.group) {
          unawaited(_end(m['op'] == 'busy' ? 'busy' : 'declined', send: false));
        } else {
          _leftGroup(c, from);
        }
      case 'end':
        if (c == null || c.id != id || !c.members.contains(from)) return;
        if (c.phase == CallPhase.incoming && from == c.from) {
          unawaited(_end('missed', send: false, notify: true));
        } else if (!c.group || c.connected.difference({from}).isEmpty && c.joined.difference({from, _me}).isEmpty) {
          unawaited(_end('answered', send: false));
        } else {
          _leftGroup(c, from);
        }
      case 'state':
        if (c == null || c.id != id || !c.members.contains(from)) return;
        c.remote[from] = (mic: m['mic'] != false, camera: m['cam'] == true);
        if (m['cam'] != true) c.frames.remove(from);
        _changed();
      case 'ring':
        // The callee's phone is ringing; nothing to change yet.
        break;
    }
  }

  void _leftGroup(CallState c, String peer) {
    c.joined.remove(peer);
    c.connected.remove(peer);
    c.frames.remove(peer);
    c.levels.remove(peer);
    _jitter.remove(peer);
    _video.remove(peer);
    link.callDropPeer(c.id, peer);
    _changed();
  }

  void _onMedia(MediaEvent ev) {
    final c = _call;
    if (c == null || c.id != ev.call || !c.live) return;
    if (ev.up) {
      c.connected.add(ev.peer);
      c.joined.add(ev.peer);
      if (c.phase != CallPhase.active) {
        c.phase = CallPhase.active;
        c.answered ??= nowMs();
        _connect?.cancel();
      }
    } else {
      c.connected.remove(ev.peer);
      if (c.connected.isEmpty && !c.group) {
        unawaited(_end('failed', notify: false));
        return;
      }
    }
    _changed();
  }

  // ---------------------------------------------------------------------------
  // media

  Future<void> _startMedia(CallState c) async {
    _pump?.cancel();
    _pump = Timer.periodic(const Duration(milliseconds: 10), (_) => drain());
    _stats?.cancel();
    _stats = Timer.periodic(const Duration(seconds: 2), (_) => _readStats(c));
    final d = devices;
    if (d == null) return;
    try {
      await d.start(video: c.video, pull: pull);
      _micSub = d.mic.listen((f) {
        if (c.mic && c.live) sendAudio(f);
      });
      _camSub = d.camera.listen((jpeg) {
        if (c.camera && c.live) sendVideo(jpeg);
      });
    } catch (_) {
      // No microphone permission or device: the call still connects.
    }
  }

  void _readStats(CallState c) {
    final s = link.callStats(c.id);
    final peers = s?['peers'];
    if (peers is! List) return;
    for (final p in peers) {
      if (p is Map && p['peer'] is String && p['rttMs'] is num) c.rtt[p['peer'] as String] = (p['rttMs'] as num).toDouble();
    }
    _changed();
  }

  /// Sends one 20 ms microphone frame.
  void sendAudio(Uint8List pcm) {
    final c = _call;
    if (c == null || c.connected.isEmpty) return;
    link.callSend(c.id, MediaPacket.encodeAudio(_seq, pcm));
    _seq = (_seq + 1) & 0xffff;
  }

  /// Sends one camera frame, split to fit the smallest path.
  void sendVideo(Uint8List jpeg) {
    final c = _call;
    if (c == null || c.connected.isEmpty) return;
    final max = link.callMaxDatagram(c.id);
    if (max <= MediaPacket.videoHeader) return;
    for (final p in MediaPacket.encodeVideo(_frame, jpeg, max)) {
      link.callSend(c.id, p);
    }
    _frame = (_frame + 1) & 0xffff;
  }

  /// Moves everything waiting in the native queue into jitter buffers and
  /// video assemblers. Called every 10 ms during a call.
  void drain() {
    final c = _call;
    if (c == null || !c.live) return;
    var video = false;
    for (var i = 0; i < 200; i++) {
      final p = link.callRecv(c.id);
      if (p == null) break;
      if (!c.members.contains(p.peer) || p.data.isEmpty) continue;
      switch (p.data[0]) {
        case MediaPacket.audio when p.data.length == MediaPacket.audioHeader + MediaPacket.frameBytes:
          final seq = (p.data[1] << 8) | p.data[2];
          _jitter.putIfAbsent(p.peer, JitterBuffer.new).push(seq, Uint8List.sublistView(p.data, MediaPacket.audioHeader));
        case MediaPacket.video:
          final jpeg = _video.putIfAbsent(p.peer, VideoAssembler.new).push(p.data);
          if (jpeg != null) {
            c.frames[p.peer] = jpeg;
            video = true;
          }
      }
    }
    if (video) _changed();
  }

  /// The next 20 ms to play: every speaker's frame, mixed.
  Uint8List pull() {
    final c = _call;
    final frames = <Uint8List>[];
    for (final e in _jitter.entries) {
      final f = e.value.pull();
      if (f != null) {
        frames.add(f);
        c?.levels[e.key] = pcmLevel(f);
      } else {
        c?.levels[e.key] = 0;
      }
    }
    return mixPcm(frames, MediaPacket.frameBytes);
  }

  /// Packets lost or late per speaker, for the call's technical sheet.
  Map<String, ({int lost, int late, int depth})> jitterStats() =>
      {for (final e in _jitter.entries) e.key: (lost: e.value.lost, late: e.value.late, depth: e.value.depth)};

  Future<void> dispose() async {
    if (_call?.live ?? false) await _end('failed');
    for (final s in _subs) {
      await s.cancel();
    }
    await _changes.close();
  }

  /// People in the call other than this device, in a stable order.
  List<String> others() => (_call?.members ?? const <String>[]).whereNot((m) => m == _me).toList();
}
