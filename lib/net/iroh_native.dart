import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _StartC = Int32 Function(Pointer<Uint8>, IntPtr, Pointer<Utf8>, Pointer<Utf8>);
typedef _StartD = int Function(Pointer<Uint8>, int, Pointer<Utf8>, Pointer<Utf8>);
typedef _StopC = Int32 Function();
typedef _StopD = int Function();
typedef _SendC = Int32 Function(Pointer<Utf8>, Pointer<Uint8>, IntPtr);
typedef _SendD = int Function(Pointer<Utf8>, Pointer<Uint8>, int);
typedef _ConnectC = Int32 Function(Pointer<Utf8>);
typedef _ConnectD = int Function(Pointer<Utf8>);
typedef _StrC = Pointer<Utf8> Function();
typedef _StrD = Pointer<Utf8> Function();
typedef _AddTicketC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _AddTicketD = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _JoinC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _JoinD = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _LeaveC = Int32 Function(Pointer<Utf8>);
typedef _LeaveD = int Function(Pointer<Utf8>);
typedef _BroadcastC = Int32 Function(Pointer<Utf8>, Pointer<Uint8>, IntPtr);
typedef _BroadcastD = int Function(Pointer<Utf8>, Pointer<Uint8>, int);
typedef _ImportC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _ImportD = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FetchC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _FetchD = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _CancelC = Int32 Function(Pointer<Utf8>);
typedef _CancelD = int Function(Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeD = void Function(Pointer<Utf8>);

/// Thin C ABI around the iroh node in `native/`.
class IrohNative {
  IrohNative._(DynamicLibrary lib)
      : _start = lib.lookupFunction<_StartC, _StartD>('mentos_start'),
        _stop = lib.lookupFunction<_StopC, _StopD>('mentos_stop'),
        _send = lib.lookupFunction<_SendC, _SendD>('mentos_send'),
        _connect = lib.lookupFunction<_ConnectC, _ConnectD>('mentos_connect'),
        _ticket = lib.lookupFunction<_StrC, _StrD>('mentos_ticket'),
        _addTicket = lib.lookupFunction<_AddTicketC, _AddTicketD>('mentos_add_ticket'),
        _join = lib.lookupFunction<_JoinC, _JoinD>('mentos_join'),
        _leave = lib.lookupFunction<_LeaveC, _LeaveD>('mentos_leave'),
        _broadcast = lib.lookupFunction<_BroadcastC, _BroadcastD>('mentos_broadcast'),
        _import = lib.lookupFunction<_ImportC, _ImportD>('mentos_import_blob'),
        _fetch = lib.lookupFunction<_FetchC, _FetchD>('mentos_fetch_blob'),
        _cancelFetch = _lookupCancel(lib),
        _blobPath = lib.lookupFunction<_AddTicketC, _AddTicketD>('mentos_blob_path'),
        _status = lib.lookupFunction<_StrC, _StrD>('mentos_status'),
        _poll = lib.lookupFunction<_StrC, _StrD>('mentos_poll_event'),
        _lastError = lib.lookupFunction<_StrC, _StrD>('mentos_last_error'),
        _free = lib.lookupFunction<_FreeC, _FreeD>('mentos_free');

  final _StartD _start;
  final _StopD _stop;
  final _SendD _send;
  final _ConnectD _connect;
  final _StrD _ticket;
  final _AddTicketD _addTicket;
  final _JoinD _join;
  final _LeaveD _leave;
  final _BroadcastD _broadcast;
  final _ImportD _import;
  final _FetchD _fetch;
  final _CancelD? _cancelFetch;
  final _AddTicketD _blobPath;
  final _StrD _status;
  final _StrD _poll;
  final _StrD _lastError;
  final _FreeD _free;

  static _CancelD? _lookupCancel(DynamicLibrary lib) {
    try {
      return lib.lookupFunction<_CancelC, _CancelD>('mentos_cancel_fetch');
    } catch (_) {
      return null;
    }
  }

  static IrohNative open() {
    final tried = <String>[];
    Object? last;
    for (final path in _libraryCandidates()) {
      tried.add(path);
      try {
        return IrohNative._(DynamicLibrary.open(path));
      } catch (e) {
        last = e;
      }
    }
    throw UnsupportedError('iroh native library not found (${tried.join(', ')}): $last');
  }

  static Iterable<String> _libraryCandidates() sync* {
    if (Platform.isAndroid) {
      yield 'libmentos_net.so';
      return;
    }
    if (Platform.isWindows) {
      yield 'mentos_net.dll';
      final exe = File(Platform.resolvedExecutable).parent.path;
      yield '$exe${Platform.pathSeparator}mentos_net.dll';
    }
  }

  String? takeError() => _take(_lastError());

  String? _take(Pointer<Utf8> p) {
    if (p == nullptr) return null;
    final s = p.toDartString();
    _free(p);
    return s;
  }

  void start({required Uint8List secret, required String dataDir, required String blobDir}) {
    final s = secret.allocate();
    final d = dataDir.toNativeUtf8();
    final b = blobDir.toNativeUtf8();
    try {
      if (_start(s.cast(), secret.length, d, b) != 0) {
        throw StateError(takeError() ?? 'iroh failed to start');
      }
    } finally {
      malloc.free(s);
      malloc.free(d);
      malloc.free(b);
    }
  }

  void stop() => _stop();

  bool send(String peer, Uint8List data) {
    final p = peer.toNativeUtf8();
    final b = data.allocate();
    try {
      return _send(p, b.cast(), data.length) == 1;
    } finally {
      malloc.free(p);
      malloc.free(b);
    }
  }

  bool connect(String peer) {
    final p = peer.toNativeUtf8();
    try {
      return _connect(p) == 1;
    } finally {
      malloc.free(p);
    }
  }

  String ticket() => _take(_ticket()) ?? '';

  String? addTicket(String ticket) {
    final t = ticket.toNativeUtf8();
    try {
      return _take(_addTicket(t));
    } finally {
      malloc.free(t);
    }
  }

  void join(String topic, List<String> bootstrap) {
    final t = topic.toNativeUtf8();
    final b = bootstrap.join(',').toNativeUtf8();
    try {
      if (_join(t, b) != 0) throw StateError(takeError() ?? 'join failed');
    } finally {
      malloc.free(t);
      malloc.free(b);
    }
  }

  void leave(String topic) {
    final t = topic.toNativeUtf8();
    try {
      _leave(t);
    } finally {
      malloc.free(t);
    }
  }

  bool broadcast(String topic, Uint8List data) {
    final t = topic.toNativeUtf8();
    final b = data.allocate();
    try {
      return _broadcast(t, b.cast(), data.length) == 0;
    } finally {
      malloc.free(t);
      malloc.free(b);
    }
  }

  String importBlob(String path) {
    final p = path.toNativeUtf8();
    try {
      return _take(_import(p)) ?? (throw StateError(takeError() ?? 'import failed'));
    } finally {
      malloc.free(p);
    }
  }

  bool fetchBlob(String hash, String peer) {
    final h = hash.toNativeUtf8();
    final p = peer.toNativeUtf8();
    try {
      return _fetch(h, p) == 1;
    } finally {
      malloc.free(h);
      malloc.free(p);
    }
  }

  void cancelFetch(String hash) {
    final cancel = _cancelFetch;
    if (cancel == null) return;
    final h = hash.toNativeUtf8();
    try {
      cancel(h);
    } finally {
      malloc.free(h);
    }
  }

  String blobPath(String hash) {
    final h = hash.toNativeUtf8();
    try {
      return _take(_blobPath(h)) ?? '';
    } finally {
      malloc.free(h);
    }
  }

  Map<String, dynamic> status() {
    final raw = _take(_status());
    if (raw == null) return const {};
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  Map<String, dynamic>? pollEvent() {
    final raw = _take(_poll());
    if (raw == null) return null;
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }
}

extension on Uint8List {
  Pointer<Uint8> allocate() {
    final p = malloc<Uint8>(length);
    p.asTypedList(length).setAll(0, this);
    return p;
  }
}
