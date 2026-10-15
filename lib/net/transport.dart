import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/crypto/crypto.dart';

sealed class NetEvent {}

/// Bytes sent straight to us over an end-to-end encrypted QUIC stream.
class DirectEvent extends NetEvent {
  DirectEvent(this.from, this.data);
  final String from;
  final Uint8List data;
}

/// A gossip message on a topic we joined. [from] is the neighbor that relayed it.
class GossipEvent extends NetEvent {
  GossipEvent(this.topic, this.from, this.data);
  final String topic;
  final String from;
  final Uint8List data;
}

/// A direct connection to [peer] opened or closed.
class LinkEvent extends NetEvent {
  LinkEvent(this.peer, this.up);
  final String peer;
  final bool up;
}

class NeighborEvent extends NetEvent {
  NeighborEvent(this.topic, this.peer, this.up);
  final String topic;
  final String peer;
  final bool up;
}

class StatusEvent extends NetEvent {}

enum LinkKind { direct, relay, mixed, none }

class LinkInfo {
  const LinkInfo({
    required this.peer,
    required this.kind,
    this.latencyMs,
    this.paths = const [],
  });
  final String peer;
  final LinkKind kind;
  final int? latencyMs;
  final List<RoutePath> paths;
}

class RoutePath {
  const RoutePath({
    required this.kind,
    required this.address,
    required this.selected,
    this.latencyMs,
  });
  final LinkKind kind;
  final String address;
  final bool selected;
  final int? latencyMs;
}

class NetStatus {
  const NetStatus({
    required this.nodeId,
    required this.running,
    this.relayUrl,
    this.directAddrs = const [],
    this.relays = const [],
    this.links = const [],
    this.engine = 'offline',
    this.topics = 0,
    this.routeTelemetry = false,
  });

  final String nodeId;
  final bool running;
  final String? relayUrl;
  final List<String> directAddrs;
  final List<String> relays;
  final List<LinkInfo> links;
  final String engine;
  final int topics;

  /// Old native builds supplied guessed relay names, not measured routes.
  final bool routeTelemetry;

  bool get reachable => running && (relayUrl != null || directAddrs.isNotEmpty);
}

/// The only thing the app knows about the network. The production
/// implementation is the iroh node in `rust/` (QUIC + hole punching + relays,
/// gossip for topics, and a verified blob protocol).
abstract class Transport {
  Future<void> start({
    required Uint8List secret,
    required String dataDir,
    required String blobDir,
  });
  Future<void> stop();

  Stream<NetEvent> get events;

  /// Sends to a peer by id, dialing if needed. Returns false if unreachable.
  Future<bool> send(String peer, Uint8List data);

  /// Tries to open a link to [peer] without sending anything.
  Future<bool> connect(String peer);

  /// A shareable address for this node (id plus relay and direct addresses).
  Future<String> ticket();

  /// Registers a peer's address ticket; returns the peer id.
  Future<String?> addTicket(String ticket);

  Future<void> join(String topic, List<String> bootstrap);
  Future<void> leave(String topic);
  Future<bool> broadcast(String topic, Uint8List data);

  /// Moves [path] into the blob store and returns its content hash.
  Future<String> importBlob(String path);

  /// Fetches a blob from [peer] into the blob store. Verifies the hash.
  /// Gives up after the native deadline, or sooner if [cancelFetch] is called.
  Future<bool> fetchBlob(String hash, String peer);

  /// Asks the native fetch for [hash] to stop and delete its partial file.
  Future<void> cancelFetch(String hash);

  String blobPath(String hash);

  Future<NetStatus> status();
}

/// Used when the native iroh library is not bundled. Everything works
/// locally; nothing leaves the device.
class OfflineTransport implements Transport {
  final _events = StreamController<NetEvent>.broadcast();
  late String _blobDir;
  String _id = '';

  @override
  Stream<NetEvent> get events => _events.stream;

  @override
  Future<void> start({
    required Uint8List secret,
    required String dataDir,
    required String blobDir,
  }) async {
    _blobDir = blobDir;
    _id = toHex(secret).substring(0, 8);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<bool> send(String peer, Uint8List data) async => false;

  @override
  Future<bool> connect(String peer) async => false;

  @override
  Future<String> ticket() async => '';

  @override
  Future<String?> addTicket(String ticket) async => null;

  @override
  Future<void> join(String topic, List<String> bootstrap) async {}

  @override
  Future<void> leave(String topic) async {}

  @override
  Future<bool> broadcast(String topic, Uint8List data) async => false;

  @override
  Future<void> cancelFetch(String hash) async {}

  @override
  Future<String> importBlob(String path) async {
    final f = File(path);
    final hash = toHex(sha256(await f.readAsBytes()));
    final dest = blobPath(hash);
    if (!File(dest).existsSync()) {
      await f.copy(dest);
    }
    await f.delete();
    return hash;
  }

  @override
  Future<bool> fetchBlob(String hash, String peer) async =>
      File(blobPath(hash)).existsSync();

  @override
  String blobPath(String hash) => p.join(_blobDir, hash);

  @override
  Future<NetStatus> status() async =>
      NetStatus(nodeId: _id, running: false, engine: 'offline');
}
