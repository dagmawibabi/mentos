import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/state/settings.dart';

import 'support/fake_net.dart';

/// Blob fetches wait until the test releases them, so concurrency is visible.
class GatedTransport extends TestTransport {
  GatedTransport(super.network, super.id);
  final gates = <Completer<bool>>[];
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<bool> fetchBlob(String hash, String peer) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    final g = Completer<bool>();
    gates.add(g);
    final ok = await g.future;
    inFlight--;
    return ok;
  }
}

MediaRef fakeRef(int n) => MediaRef(
      hash: n.toRadixString(16).padLeft(64, '0'),
      key: 'a2V5',
      name: 'file$n.bin',
      mime: 'application/octet-stream',
      size: 1000,
    );

void main() {
  late Directory root;
  late TestNetwork network;
  late List<Engine> engines;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-xfer-');
    network = TestNetwork();
    engines = [];
  });
  tearDown(() async {
    for (final e in engines) {
      await e.stop();
      e.db.close();
    }
    await root.delete(recursive: true);
  });

  test('downloads queue behind the parallel limit, and failures can be retried', () async {
    final a = await openEngine(root, network);
    late GatedTransport bt;
    final b = await openEngine(root, network,
        settings: const Settings(xferParallel: 1), transport: (id) => bt = GatedTransport(network, id));
    engines.addAll([a, b]);
    final x1 = await a.offerTransfer(b.me.id, fakeRef(1));
    final x2 = await a.offerTransfer(b.me.id, fakeRef(2));
    await eventually(() => b.transfers().length == 2);
    await b.respondTransfer(x1.id, true);
    await b.respondTransfer(x2.id, true);
    await eventually(() => bt.gates.length == 1);
    expect(b.transfers().where((x) => x.state == XferState.queued).length, 1);
    bt.gates.first.complete(false);
    await eventually(() => bt.gates.length == 2);
    expect(bt.maxInFlight, 1);
    bt.gates[1].complete(false);
    await eventually(() => b.transfers().every((x) => x.state == XferState.failed));

    await b.retryTransfer(x1.id);
    await eventually(() => bt.gates.length == 3);
    expect(b.transfers().firstWhere((x) => x.id == x1.id).state, XferState.active);
    bt.gates[2].complete(false);
    await eventually(() => b.transfers().firstWhere((x) => x.id == x1.id).state == XferState.failed);

    b.clearFinishedTransfers();
    expect(b.transfers(), isEmpty);
  });

  test('auto-accept only for people you follow, under the size limit', () async {
    final a = await openEngine(root, network);
    final stranger = await openEngine(root, network);
    late GatedTransport bt;
    final b = await openEngine(root, network,
        settings: const Settings(xferAutoAccept: true, xferAutoMaxMb: 1),
        transport: (id) => bt = GatedTransport(network, id));
    engines.addAll([a, stranger, b]);
    b.db.ensurePeer(a.me.id);
    b.db.updatePeer(a.me.id, {'i_follow': 1});

    await a.offerTransfer(b.me.id, fakeRef(1));
    await eventually(() => bt.gates.length == 1);
    final big = fakeRef(2);
    await a.offerTransfer(
        b.me.id, MediaRef(hash: big.hash, key: big.key, name: 'big', mime: big.mime, size: 5 * 1024 * 1024));
    await stranger.offerTransfer(b.me.id, fakeRef(3));
    await eventually(() => b.transfers().length == 3);
    expect(b.transfers().where((x) => x.state == XferState.offer).length, 2);
    for (final g in bt.gates) {
      g.complete(false);
    }
  });

  group('hosting', () {
    test('tags are cleaned and validated', () async {
      expect(HostMeta.parseTags('Travel, #Photos 2024,travel,, x'), ['travel', 'photos-2024', 'x']);
      expect(HostMeta.cleanTags(List.generate(20, (i) => 't$i')).length, HostMeta.maxTags);
      final me = await Identity.generate();
      Future<bool> sane(Map<String, dynamic> body) async =>
          (await Envelope.create(me, kind: K.host, scope: Scope.files(me.id), body: body)).sane;
      expect(await sane({'tags': ['ok'], 'folder': 'Music', 'note': 'n'}), isTrue);
      expect(await sane({'tags': 'nope'}), isFalse);
      expect(await sane({'tags': [1]}), isFalse);
      expect(await sane({'folder': 'x' * 61}), isFalse);
      expect(await sane({'note': 7}), isFalse);
    });

    test('metadata, search by tag and folder, and download counts', () async {
      final a = await openEngine(root, network);
      engines.add(a);
      final host = await a.hostFile(fakeRef(9), note: 'live set', folder: 'Music', tags: ['Techno', '#live']);
      final meta = HostMeta.of(host);
      expect(meta.folder, 'Music');
      expect(meta.tags, ['techno', 'live']);
      expect(a.searchHosted('#techno').single.id, host.id);
      expect(a.searchHosted('music').single.id, host.id);
      expect(a.searchHosted('nothing'), isEmpty);

      for (var i = 0; i < 2; i++) {
        final who = await Identity.generate();
        final v = await Envelope.create(who,
            kind: K.view, scope: Scope.post(a.me.id, host.id), body: {'target': host.id}, keep: true);
        expect(await a.ingest(v, via: who.id), isTrue);
      }
      expect(a.hostDownloads(host), 2);
    });
  });
}
