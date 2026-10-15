import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mentos/features/calls/devices.dart';
import 'package:mentos/net/call/media.dart';

Uint8List frame(int v) {
  final b = ByteData(MediaPacket.frameBytes);
  for (var i = 0; i < MediaPacket.samplesPerFrame; i++) {
    b.setInt16(i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}

int sample(Uint8List f) => ByteData.sublistView(f).getInt16(0, Endian.little);

void main() {
  test('audio packets round trip', () {
    final p = MediaPacket.encodeAudio(0xfffe, frame(7));
    expect(p[0], MediaPacket.audio);
    expect((p[1] << 8) | p[2], 0xfffe);
    expect(p.length, MediaPacket.audioHeader + MediaPacket.frameBytes);
    expect(MediaPacket.newer(1, 0xffff), isTrue, reason: 'wraps');
    expect(MediaPacket.newer(0xffff, 1), isFalse);
  });

  test('jitter buffer waits, plays in order, and fills gaps with silence', () {
    final j = JitterBuffer(target: 3);
    j.push(11, frame(11));
    j.push(10, frame(10));
    expect(j.pull(), isNull, reason: 'still buffering');
    j.push(13, frame(13));
    expect(sample(j.pull()!), 10);
    expect(sample(j.pull()!), 11);
    expect(j.pull(), isNull, reason: '12 never arrived');
    expect(j.lost, 1);
    j.push(12, frame(12));
    expect(j.late, 1, reason: 'arrived after its slot');
    expect(sample(j.pull()!), 13);
  });

  test('jitter buffer drops a backlog instead of drifting behind', () {
    final j = JitterBuffer(target: 3, max: 6);
    for (var s = 0; s < 10; s++) {
      j.push(s, frame(s));
    }
    expect(j.depth, lessThanOrEqualTo(6));
    final first = sample(j.pull()!);
    expect(first, greaterThanOrEqualTo(4));
  });

  test('jitter buffer works across sequence wrap', () {
    final j = JitterBuffer(target: 2);
    j.push(0xffff, frame(1));
    j.push(0, frame(2));
    expect(sample(j.pull()!), 1);
    expect(sample(j.pull()!), 2);
  });

  test('video frames split, reassemble out of order, and stale frames are ignored', () {
    final jpeg = Uint8List.fromList(List.generate(3000, (i) => i % 251));
    final parts = MediaPacket.encodeVideo(5, jpeg, 1200);
    expect(parts.length, 3);
    expect(parts.every((p) => p.length <= 1200), isTrue);
    final v = VideoAssembler();
    expect(v.push(parts[2]), isNull);
    expect(v.push(parts[0]), isNull);
    expect(v.push(parts[1]), jpeg);
    final old = MediaPacket.encodeVideo(4, jpeg, 1200);
    for (final p in old) {
      expect(v.push(p), isNull, reason: 'older than what is on screen');
    }
    expect(v.push(Uint8List.fromList([2, 0, 9, 3, 1, 0])), isNull, reason: 'part index out of range');
    expect(MediaPacket.encodeVideo(1, Uint8List(400 * 1200), 1200), isEmpty, reason: 'too many parts');
  });

  test('mixing clamps instead of wrapping', () {
    final m = mixPcm([frame(30000), frame(30000)], MediaPacket.frameBytes);
    expect(sample(m), 32767);
    expect(sample(mixPcm([frame(100), frame(-40)], MediaPacket.frameBytes)), 60);
    expect(mixPcm([], 8), Uint8List(8));
    expect(pcmLevel(frame(0)), 0);
    expect(pcmLevel(frame(20000)), greaterThan(0.5));
  });

  test('slicer cuts arbitrary chunks into exact frames', () {
    final s = FrameSlicer();
    expect(s.add(Uint8List(500)), isEmpty);
    final out = s.add(Uint8List(900));
    expect(out.length, 2);
    expect(out.every((f) => f.length == MediaPacket.frameBytes), isTrue);
    expect(s.add(Uint8List(520)).length, 1);
  });

  test('camera frames become small upright JPEGs', () {
    // 320x240 frame: left half black, right half white, neutral chroma.
    const w = 320, h = 240;
    final y = Uint8List(w * h);
    for (var r = 0; r < h; r++) {
      for (var c = w ~/ 2; c < w; c++) {
        y[r * w + c] = 255;
      }
    }
    final uv = Uint8List(w * h ~/ 4)..fillRange(0, w * h ~/ 4, 128);
    final jpeg = yuvToJpeg(YuvFrame(width: w, height: h, y: y, u: uv, v: uv, yRow: w, uvRow: w ~/ 2, uvPixel: 1, rotation: 90));
    expect(jpeg.length, lessThan(8000), reason: 'fits in a handful of datagrams');
    final back = img.decodeJpg(jpeg)!;
    expect((back.width, back.height), (180, 240), reason: 'scaled to 240 and turned upright');
    // Turned 90 degrees clockwise: the right (white) half ends up at the bottom.
    expect(back.getPixel(90, 10).r, lessThan(50));
    expect(back.getPixel(90, 230).r, greaterThan(200));
  });
}
