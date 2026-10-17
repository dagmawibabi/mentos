import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/crypto/crypto.dart';
import '../core/device_access.dart';
import '../net/transport.dart';
import 'db.dart';
import 'models.dart';

/// On-device file storage.
///
/// * `blobs/`  encrypted content, addressed by hash, served to peers on request
/// * `view/`   decrypted copies for viewing, wiped on every launch
/// * `tmp/`    scratch space
class MediaStore {
  MediaStore(this.root, this.db, this.net);

  final String root;
  final Db db;
  final Transport net;

  late final Directory blobs = Directory(p.join(root, 'blobs'));
  late final Directory view = Directory(p.join(root, 'view'));
  late final Directory tmp = Directory(p.join(root, 'tmp'));
  final _inflight = <String, Future<File?>>{};

  /// Hard cap for encrypted blobs, set from Settings.quotaMb.
  int quotaBytes = 2048 * 1024 * 1024;

  Future<void> init() async {
    for (final d in [blobs, view, tmp]) {
      await d.create(recursive: true);
    }
    for (final d in [view, tmp]) {
      await for (final f in d.list()) {
        await f.delete(recursive: true);
      }
    }
    await _dropOrphanCache();
  }

  /// Other people's media fetched while they were online is not kept across
  /// launches unless it belongs to content this device agreed to keep.
  Future<void> _dropOrphanCache() async {
    final referenced = db.referencedHashes();
    for (final f in db.files()) {
      if (f.origin == 'cache' && !referenced.contains(f.hash)) {
        await deleteBlob(f.hash);
      }
    }
  }

  String newTmpPath([String ext = '']) => p.join(tmp.path, '${newId()}$ext');

  Future<void> _ensureRoom(int incoming) async {
    final used = await usage();
    // Space rented out to other people is promised separately and does not
    // count against this person's own media quota.
    final leased = db.files().where((f) => f.origin == 'lease').fold<int>(0, (s, f) => s + f.size);
    if (used.blobs - leased + incoming > quotaBytes) {
      throw StateError('This phone is out of room for more files.');
    }
    final free = await _freeBytes();
    if (free != null && free < incoming + 64 * 1024 * 1024) {
      throw StateError('This phone is out of room for more files.');
    }
  }

  Future<int?> _freeBytes() async {
    try {
      if (Platform.isWindows) {
        final root = p.rootPrefix(blobs.path);
        if (root.isEmpty) return null;
        final letter = root[0];
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "(Get-PSDrive -Name '$letter').Free",
        ]);
        return int.tryParse('${r.stdout}'.trim());
      }
      final r = await Process.run('df', ['-k', blobs.path]);
      final lines = '${r.stdout}'.trim().split('\n');
      if (lines.length < 2) return null;
      final parts = lines.last.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) return null;
      final kb = int.tryParse(parts[3]);
      return kb == null ? null : kb * 1024;
    } catch (_) {
      return null;
    }
  }

  /// Encrypts [src] into the blob store and returns a reference to share.
  Future<MediaRef> import(
    File src, {
    String? name,
    String? mime,
    String? scope,
    int? width,
    int? height,
    int? durationMs,
    List<int>? wave,
    bool deleteSource = false,
  }) async {
    final incoming = await src.length();
    await _ensureRoom(incoming);
    final fileName = name ?? p.basename(src.path);
    final type = mime ?? mimeFor(fileName);
    final key = randomBytes(32);
    final enc = File(newTmpPath('.enc'));
    try {
      await FileCipher.encrypt(src, enc, key);
      final size = await src.length();
      final hash = await net.importBlob(enc.path);

      final viewCopy = File(_viewPath(hash, fileName));
      if (!viewCopy.existsSync()) await src.copy(viewCopy.path);
      if (deleteSource) await src.delete().catchError((_) => src);

      final keyB64 = base64Encode(key);
      db.putFile(StoredFile(
        hash: hash,
        name: fileName,
        mime: type,
        size: size,
        key: keyB64,
        origin: 'mine',
        scope: scope,
        created: nowMs(),
      ));
      return MediaRef(
        hash: hash,
        key: keyB64,
        name: fileName,
        mime: type,
        size: size,
        width: width,
        height: height,
        durationMs: durationMs,
        wave: wave,
      );
    } on FileSystemException {
      if (enc.existsSync()) await enc.delete().catchError((_) => enc);
      throw StateError('This phone is out of room for more files.');
    } catch (e) {
      if (enc.existsSync()) await enc.delete().catchError((_) => enc);
      rethrow;
    } finally {
      if (enc.existsSync()) await enc.delete().catchError((_) => enc);
    }
  }

  Future<void> _watchBlob(String hash, int total, void Function(int done, int total) onProgress) async {
    final finalPath = net.blobPath(hash);
    final doneFile = File(finalPath);
    final part = File('$finalPath.part');
    for (var i = 0; i < 600; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (doneFile.existsSync()) {
        onProgress(total, total);
        return;
      }
      if (!part.existsSync() || total <= 0) continue;
      final n = await part.length();
      final shown = n >= total ? total - 1 : n;
      if (shown > 0) onProgress(shown, total);
    }
  }

  String _viewPath(String hash, String name) {
    final h = hash.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(h)) {
      throw FormatException('bad blob hash');
    }
    final ext = p.extension(name).toLowerCase();
    final safeExt = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(ext) ? ext : '';
    return p.join(view.path, '${h.substring(0, 24)}$safeExt');
  }

  String _safeName(String name) {
    var base = p.basename(name.replaceAll('\\', '/')).replaceAll(RegExp(r'[^A-Za-z0-9._\- ]'), '_');
    if (base.isEmpty || base == '.' || base == '..') base = 'file';
    if (base.length > 80) base = base.substring(0, 80);
    return base;
  }

  File? cached(MediaRef ref) {
    try {
      final f = File(_viewPath(ref.hash, ref.name));
      if (!f.existsSync()) return null;
      final n = f.lengthSync();
      if (n != ref.size) {
        f.deleteSync();
        final part = File('${f.path}.part');
        if (part.existsSync()) part.deleteSync();
        return null;
      }
      return f;
    } catch (_) {
      return null;
    }
  }

  bool hasBlob(String hash) => File(net.blobPath(hash)).existsSync();

  /// Returns a viewable file, fetching the blob from [sources] if needed.
  Future<File?> open(
    MediaRef ref, {
    List<String> sources = const [],
    String origin = 'cache',
    String? scope,
    void Function(int done, int total)? onProgress,
  }) {
    final hit = cached(ref);
    if (hit != null) return Future.value(hit);
    return _inflight.putIfAbsent(ref.hash, () async {
      try {
        if (!hasBlob(ref.hash)) {
          await _ensureRoom(ref.size);
          var ok = false;
          for (final s in sources.toSet()) {
            final fetch = net.fetchBlob(ref.hash, s);
            if (onProgress != null && ref.size > 0) {
              unawaited(_watchBlob(ref.hash, ref.size, onProgress));
            }
            if (await fetch) {
              ok = true;
              break;
            }
          }
          if (!ok) return null;
          onProgress?.call(ref.size, ref.size);
          db.putFile(StoredFile(
            hash: ref.hash,
            name: ref.name,
            mime: ref.mime,
            size: ref.size,
            key: ref.key,
            origin: origin,
            scope: scope,
            created: nowMs(),
          ));
        }
        final out = File(_viewPath(ref.hash, ref.name));
        await FileCipher.decrypt(File(net.blobPath(ref.hash)), out, base64Decode(ref.key), plainSize: ref.size);
        return cached(ref);
      } catch (_) {
        final out = File(_viewPath(ref.hash, ref.name));
        if (out.existsSync()) await out.delete().catchError((_) => out);
        final part = File('${out.path}.part');
        if (part.existsSync()) await part.delete().catchError((_) => part);
        return null;
      } finally {
        _inflight.remove(ref.hash);
      }
    });
  }

  /// Fetch and keep a blob without decrypting it (used for custody).
  Future<void> keep(MediaRef ref, List<String> sources, String? scope) async {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(ref.hash)) return;
    if (hasBlob(ref.hash)) {
      db.putFile(StoredFile(
          hash: ref.hash, name: ref.name, mime: ref.mime, size: ref.size, key: ref.key,
          origin: 'kept', scope: scope, created: nowMs()));
      return;
    }
    await _ensureRoom(ref.size);
    for (final s in sources.toSet()) {
      if (await net.fetchBlob(ref.hash, s)) {
        db.putFile(StoredFile(
            hash: ref.hash, name: ref.name, mime: ref.mime, size: ref.size, key: ref.key,
            origin: 'kept', scope: scope, created: nowMs()));
        return;
      }
    }
  }

  bool _inside(String root, String path) {
    final a = p.normalize(root);
    final b = p.normalize(path);
    return b == a || b.startsWith('$a${Platform.pathSeparator}');
  }

  Future<void> deleteBlob(String hash) async {
    final blobPath = net.blobPath(hash);
    if (blobPath.isEmpty || !_inside(blobs.path, blobPath)) return;
    final f = File(blobPath);
    if (f.existsSync()) await f.delete();
    final stored = db.file(hash);
    if (stored != null) {
      try {
        final v = File(_viewPath(hash, stored.name));
        if (_inside(view.path, v.path) && v.existsSync()) await v.delete();
      } catch (_) {}
    }
    db.deleteFile(hash);
  }

  /// Copies a decrypted file out to a temp path for sharing or opening.
  Future<File?> export(MediaRef ref, {List<String> sources = const []}) async {
    final f = await open(ref, sources: sources);
    if (f == null) return null;
    final out = File(p.join(tmp.path, _safeName(ref.name)));
    return f.copy(out.path);
  }

  /// Writes a decrypted copy into Downloads (or Documents if that's missing).
  Future<File?> saveToDevice(MediaRef ref, {List<String> sources = const []}) async {
    await askToSaveFiles();
    final f = await export(ref, sources: sources);
    if (f == null) return null;
    Directory? dir;
    try {
      dir = await getDownloadsDirectory();
    } catch (_) {}
    dir ??= await getApplicationDocumentsDirectory();
    final safe = _safeName(ref.name);
    var dest = File(p.join(dir.path, safe));
    if (dest.existsSync()) {
      final stem = p.basenameWithoutExtension(safe);
      final ext = p.extension(safe);
      dest = File(p.join(dir.path, '$stem-${nowMs()}$ext'));
    }
    return f.copy(dest.path);
  }

  Future<({int blobs, int view, int count})> usage() async {
    var b = 0, v = 0, c = 0;
    await for (final f in blobs.list()) {
      if (f is File) {
        b += await f.length();
        c++;
      }
    }
    await for (final f in view.list()) {
      if (f is File) v += await f.length();
    }
    return (blobs: b, view: v, count: c);
  }

  Future<void> clearViewCache() async {
    await for (final f in view.list()) {
      await f.delete(recursive: true);
    }
  }
}

const _mimes = {
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.heic': 'image/heic',
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
  '.mkv': 'video/x-matroska',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.mp3': 'audio/mpeg',
  '.ogg': 'audio/ogg',
  '.opus': 'audio/opus',
  '.wav': 'audio/wav',
  '.pdf': 'application/pdf',
  '.zip': 'application/zip',
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.json': 'application/json',
  '.csv': 'text/csv',
  '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.apk': 'application/vnd.android.package-archive',
};

String mimeFor(String name) => _mimes[p.extension(name).toLowerCase()] ?? 'application/octet-stream';
