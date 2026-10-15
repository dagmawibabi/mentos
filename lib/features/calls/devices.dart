import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../net/call/calls.dart';
import '../../net/call/media.dart';

/// One camera frame's planes, copied so it can cross to a worker isolate.
class YuvFrame {
  const YuvFrame({
    required this.width,
    required this.height,
    required this.y,
    required this.u,
    required this.v,
    required this.yRow,
    required this.uvRow,
    required this.uvPixel,
    required this.rotation,
  });

  final int width;
  final int height;
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int yRow;
  final int uvRow;
  final int uvPixel;

  /// Clockwise degrees to turn the picture upright.
  final int rotation;
}

/// Downscales a YUV 4:2:0 frame to [maxSide] and encodes it as JPEG.
/// Nearest-neighbour sampling: cheap enough for several frames a second
/// on a phone, and the picture is small anyway.
Uint8List yuvToJpeg(YuvFrame f, {int maxSide = 240, int quality = 45}) {
  final scale = (f.width > f.height ? f.width : f.height) / maxSide;
  final step = scale < 1 ? 1.0 : scale;
  final w = (f.width / step).floor();
  final h = (f.height / step).floor();
  final out = img.Image(width: w, height: h);
  for (var oy = 0; oy < h; oy++) {
    final sy = (oy * step).floor();
    for (var ox = 0; ox < w; ox++) {
      final sx = (ox * step).floor();
      final yy = f.y[sy * f.yRow + sx];
      final uvIndex = (sy >> 1) * f.uvRow + (sx >> 1) * f.uvPixel;
      final u = (uvIndex < f.u.length ? f.u[uvIndex] : 128) - 128;
      final v = (uvIndex < f.v.length ? f.v[uvIndex] : 128) - 128;
      final r = (yy + 1.402 * v).round().clamp(0, 255);
      final g = (yy - 0.344136 * u - 0.714136 * v).round().clamp(0, 255);
      final b = (yy + 1.772 * u).round().clamp(0, 255);
      out.setPixelRgb(ox, oy, r, g, b);
    }
  }
  final upright = f.rotation % 360 == 0 ? out : img.copyRotate(out, angle: f.rotation);
  return img.encodeJpg(upright, quality: quality);
}

/// Microphone, speaker and camera on a real phone.
class PhoneDevices implements CallDevices {
  final _rec = AudioRecorder();
  final _mic = StreamController<Uint8List>.broadcast();
  final _cam = StreamController<Uint8List>.broadcast();
  final _slicer = FrameSlicer();
  StreamSubscription<Uint8List>? _recSub;
  CameraController? _camera;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  bool _encoding = false;
  int _lastFrame = 0;
  Uint8List Function()? _pull;

  /// Frames per second sent while video is on.
  static const fps = 8;

  CameraController? get preview => _camera;

  @override
  Stream<Uint8List> get mic => _mic.stream;
  @override
  Stream<Uint8List> get camera => _cam.stream;

  @override
  Future<void> start({required bool video, required Uint8List Function() pull, bool capture = true}) async {
    _pull = pull;
    if (capture) await [Permission.microphone, if (video) Permission.camera].request();
    if (capture && await Permission.microphone.isGranted) {
      final stream = await _rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: MediaPacket.sampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
        androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.voiceCommunication),
      ));
      _recSub = stream.listen((chunk) {
        for (final f in _slicer.add(chunk)) {
          _mic.add(f);
        }
      });
    }
    await FlutterPcmSound.setLogLevel(LogLevel.none);
    await FlutterPcmSound.setup(sampleRate: MediaPacket.sampleRate, channelCount: 1);
    // Ask for more when less than 60 ms is queued.
    await FlutterPcmSound.setFeedThreshold(MediaPacket.samplesPerFrame * 3);
    FlutterPcmSound.setFeedCallback(_feed);
    FlutterPcmSound.start();
    if (capture && video) await setVideo(true);
  }

  void _feed(int remaining) {
    final pull = _pull;
    if (pull == null) return;
    final frames = <Uint8List>[for (var i = 0; i < 3; i++) pull()];
    final all = BytesBuilder(copy: false);
    for (final f in frames) {
      all.add(f);
    }
    // The plugin sends the whole underlying buffer, so it must be exact.
    final exact = Uint8List.fromList(all.takeBytes());
    unawaited(FlutterPcmSound.feed(PcmArrayInt16(bytes: exact.buffer.asByteData())));
  }

  @override
  Future<void> setVideo(bool on) async {
    if (!on) {
      final c = _camera;
      _camera = null;
      if (c != null) {
        try {
          await c.stopImageStream();
        } catch (_) {}
        await c.dispose();
      }
      return;
    }
    if (_camera != null || !await Permission.camera.isGranted) return;
    _cameras = await availableCameras();
    if (_cameras.isEmpty) return;
    final front = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.front);
    _cameraIndex = front >= 0 ? front : 0;
    await _open();
  }

  Future<void> _open() async {
    final desc = _cameras[_cameraIndex];
    final c = CameraController(desc, ResolutionPreset.low, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
    await c.initialize();
    _camera = c;
    // Frames arrive in sensor orientation; turning by it makes them upright
    // for a phone held in portrait. The front sensor is not mirrored, so the
    // other side sees you as others would, not as a selfie preview.
    final rotation = desc.sensorOrientation;
    await c.startImageStream((image) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_encoding || now - _lastFrame < 1000 ~/ fps || image.planes.length < 3) return;
      _encoding = true;
      _lastFrame = now;
      final frame = YuvFrame(
        width: image.width,
        height: image.height,
        y: Uint8List.fromList(image.planes[0].bytes),
        u: Uint8List.fromList(image.planes[1].bytes),
        v: Uint8List.fromList(image.planes[2].bytes),
        yRow: image.planes[0].bytesPerRow,
        uvRow: image.planes[1].bytesPerRow,
        uvPixel: image.planes[1].bytesPerPixel ?? 1,
        rotation: rotation,
      );
      Isolate.run(() => yuvToJpeg(frame)).then(_cam.add).whenComplete(() => _encoding = false);
    });
  }

  @override
  Future<void> switchCamera() async {
    if (_cameras.length < 2 || _camera == null) return;
    await setVideo(false);
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _open();
  }

  @override
  Future<void> stop() async {
    _pull = null;
    await _recSub?.cancel();
    _recSub = null;
    try {
      await _rec.stop();
    } catch (_) {}
    await setVideo(false);
    FlutterPcmSound.setFeedCallback(null);
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
  }
}
