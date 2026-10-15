import 'dart:typed_data';

/// Wire format for call media. One QUIC datagram carries one packet:
///
///   audio: [1] [seq u16] [pcm16le mono 16 kHz, one 20 ms frame]
///   video: [2] [frame u16] [part u8] [parts u8] [jpeg slice]
///
/// Sequence numbers wrap at 65536; comparisons use serial-number arithmetic.
abstract final class MediaPacket {
  static const audio = 1;
  static const video = 2;

  static const sampleRate = 16000;
  static const frameMs = 20;
  static const samplesPerFrame = sampleRate * frameMs ~/ 1000; // 320
  static const frameBytes = samplesPerFrame * 2; // 640

  static const audioHeader = 3;
  static const videoHeader = 5;

  static Uint8List encodeAudio(int seq, Uint8List pcm) {
    final out = Uint8List(audioHeader + pcm.length);
    out[0] = audio;
    out[1] = (seq >> 8) & 0xff;
    out[2] = seq & 0xff;
    out.setRange(audioHeader, out.length, pcm);
    return out;
  }

  /// Splits one encoded frame into datagram-sized parts.
  static List<Uint8List> encodeVideo(int frame, Uint8List jpeg, int maxDatagram) {
    final room = maxDatagram - videoHeader;
    if (room <= 0 || jpeg.isEmpty) return const [];
    final parts = (jpeg.length + room - 1) ~/ room;
    if (parts > 255) return const [];
    return [
      for (var i = 0; i < parts; i++)
        () {
          final start = i * room;
          final end = (start + room).clamp(0, jpeg.length);
          final p = Uint8List(videoHeader + end - start);
          p[0] = video;
          p[1] = (frame >> 8) & 0xff;
          p[2] = frame & 0xff;
          p[3] = i;
          p[4] = parts;
          p.setRange(videoHeader, p.length, jpeg, start);
          return p;
        }(),
    ];
  }

  /// True when serial number [a] comes after [b] (RFC 1982, 16 bit).
  static bool newer(int a, int b) {
    final d = (a - b) & 0xffff;
    return d != 0 && d < 0x8000;
  }
}

/// Smooths network timing for one speaker: frames go in as they arrive, and
/// playback pulls one 20 ms frame at a time. Missing frames become silence;
/// if the speaker falls too far behind or ahead, it resynchronises.
class JitterBuffer {
  JitterBuffer({this.target = 3, this.max = 12});

  /// Frames to hold before starting playback (3 x 20 ms = 60 ms).
  final int target;
  final int max;

  final _frames = <int, Uint8List>{};
  int? _next;
  bool _primed = false;
  int lost = 0;
  int late = 0;

  int get depth => _frames.length;

  void push(int seq, Uint8List pcm) {
    final next = _next;
    // Already played (or skipped) that slot: too late to be useful.
    if (_primed && next != null && !MediaPacket.newer(seq, (next - 1) & 0xffff)) {
      late++;
      return;
    }
    _frames[seq] = pcm;
    if (!_primed && (next == null || MediaPacket.newer(next, seq))) _next = seq;
    if (_frames.length > max) _resync();
  }

  /// Keeps only the newest [target] frames, so a backlog does not turn into
  /// permanent delay.
  void _resync() {
    final anchor = _next ?? _frames.keys.first;
    final keys = _frames.keys.toList()..sort((a, b) => ((a - anchor) & 0xffff).compareTo((b - anchor) & 0xffff));
    final keep = keys.sublist(keys.length - target).toSet();
    _frames.removeWhere((k, _) => !keep.contains(k));
    _next = keys[keys.length - target];
  }

  /// The next 20 ms of audio, or null while buffering / silent.
  Uint8List? pull() {
    final next = _next;
    if (next == null) return null;
    if (!_primed) {
      if (_frames.length < target) return null;
      _primed = true;
    }
    final f = _frames.remove(next);
    _next = (next + 1) & 0xffff;
    if (f == null) {
      lost++;
      if (_frames.isEmpty) {
        // The speaker went quiet or the link stalled; rebuffer.
        _primed = false;
        _next = null;
      }
    }
    return f;
  }
}

/// Puts video frames back together. Only the newest frame matters: older
/// partial frames are dropped as soon as a newer one completes.
class VideoAssembler {
  int? _shown;
  final _parts = <int, List<Uint8List?>>{};

  /// Returns a complete JPEG when [packet] finishes a frame.
  Uint8List? push(Uint8List packet) {
    if (packet.length <= MediaPacket.videoHeader || packet[0] != MediaPacket.video) return null;
    final frame = (packet[1] << 8) | packet[2];
    final part = packet[3];
    final count = packet[4];
    if (count == 0 || part >= count) return null;
    final shown = _shown;
    if (shown != null && !MediaPacket.newer(frame, shown)) return null;
    final slots = _parts.putIfAbsent(frame, () => List<Uint8List?>.filled(count, null));
    if (slots.length != count) return null;
    slots[part] = Uint8List.sublistView(packet, MediaPacket.videoHeader);
    if (slots.any((s) => s == null)) {
      if (_parts.length > 4) _parts.remove(_parts.keys.first);
      return null;
    }
    _shown = frame;
    _parts.removeWhere((f, _) => !MediaPacket.newer(f, frame));
    final out = BytesBuilder(copy: false);
    for (final s in slots) {
      out.add(s!);
    }
    return out.takeBytes();
  }
}

/// Mixes 16-bit little-endian PCM frames from several speakers.
Uint8List mixPcm(List<Uint8List> frames, int bytes) {
  final out = Uint8List(bytes);
  if (frames.isEmpty) return out;
  if (frames.length == 1 && frames.first.length == bytes) return frames.first;
  final o = ByteData.sublistView(out);
  for (var i = 0; i + 1 < bytes; i += 2) {
    var sum = 0;
    for (final f in frames) {
      if (i + 1 < f.length) sum += ByteData.sublistView(f).getInt16(i, Endian.little);
    }
    o.setInt16(i, sum.clamp(-32768, 32767), Endian.little);
  }
  return out;
}

/// Root-mean-square level of a PCM frame, 0..1, for speaking indicators.
double pcmLevel(Uint8List pcm) {
  if (pcm.length < 2) return 0;
  final d = ByteData.sublistView(pcm);
  var acc = 0.0;
  final n = pcm.length ~/ 2;
  for (var i = 0; i < n; i++) {
    final s = d.getInt16(i * 2, Endian.little) / 32768;
    acc += s * s;
  }
  final rms = acc / n;
  return rms <= 0 ? 0 : (rms * 8).clamp(0.0, 1.0);
}

/// Cuts a microphone stream into exact 20 ms frames.
class FrameSlicer {
  final _pending = BytesBuilder(copy: true);

  List<Uint8List> add(Uint8List chunk) {
    _pending.add(chunk);
    final all = _pending.takeBytes();
    final out = <Uint8List>[];
    var i = 0;
    for (; i + MediaPacket.frameBytes <= all.length; i += MediaPacket.frameBytes) {
      out.add(Uint8List.fromList(all.sublist(i, i + MediaPacket.frameBytes)));
    }
    if (i < all.length) _pending.add(all.sublist(i));
    return out;
  }
}
