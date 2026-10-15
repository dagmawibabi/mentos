import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../../data/media_store.dart';
import '../../data/models.dart';
import '../../net/engine.dart';

/// A picked file waiting to be encrypted and stored.
class Pending {
  Pending(this.file, this.name, {this.width, this.height, this.durationMs, this.wave, this.temp = false});
  final File file;
  final String name;
  final int? width;
  final int? height;
  final int? durationMs;
  final List<int>? wave;

  /// Delete [file] after import (it lives in our tmp dir).
  final bool temp;

  String get mime => mimeFor(name);
  bool get isImage => mime.startsWith('image/');
  bool get isVideo => mime.startsWith('video/');
}

final _picker = ImagePicker();

Future<Pending> _image(XFile x) async {
  int? w, h;
  try {
    final codec = await ui.instantiateImageCodec(await x.readAsBytes());
    final frame = await codec.getNextFrame();
    w = frame.image.width;
    h = frame.image.height;
  } catch (_) {}
  return Pending(File(x.path), x.name, width: w, height: h);
}

Future<List<Pending>> pickImages({int limit = 10}) async {
  final xs = await _picker.pickMultiImage(maxWidth: 2048, imageQuality: 86, limit: limit);
  return Future.wait(xs.map(_image));
}

Future<Pending?> takePhoto() async {
  final x = await _picker.pickImage(source: ImageSource.camera, maxWidth: 2048, imageQuality: 86);
  return x == null ? null : _image(x);
}

Future<Pending?> pickVideo({bool camera = false}) async {
  final x = await _picker.pickVideo(
    source: camera ? ImageSource.camera : ImageSource.gallery,
    maxDuration: const Duration(minutes: 10),
  );
  return x == null ? null : Pending(File(x.path), x.name);
}

Future<List<Pending>> pickFiles(MediaStore store) async {
  final files = await FilePicker.pickFiles();
  final out = <Pending>[];
  for (final f in files) {
    final local = f.path;
    if (local != null) {
      out.add(Pending(File(local), f.name));
      continue;
    }
    final dest = File(store.newTmpPath(p.extension(f.name)));
    final sink = dest.openWrite();
    await sink.addStream(f.readAsByteStream());
    await sink.close();
    out.add(Pending(dest, f.name, temp: true));
  }
  return out;
}

Future<MediaRef> importPending(Engine e, Pending x, {String? scope}) => e.media.import(
      x.file,
      name: x.name,
      scope: scope,
      width: x.width,
      height: x.height,
      durationMs: x.durationMs,
      wave: x.wave,
      deleteSource: x.temp,
    );
