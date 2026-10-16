import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/db.dart';
import 'package:mentos/data/delivery.dart';
import 'package:mentos/data/media_store.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/engine.dart';
import 'package:mentos/net/transport.dart';
import 'package:mentos/state/settings.dart';

import 'support/fake_net.dart';

void main() {
  late Directory root;
  late TestNetwork network;
  late List<Engine> engines;

  Future<Engine> node() async {
    final me = await Identity.generate();
    final dir = Directory('${root.path}/${me.id}');
    await dir.create(recursive: true);
    final db = Db.open('${dir.path}/test.db', toHex(sha256(me.seed)));
    final net = TestTransport(network, me.id);
    final engine = Engine(
      me: me,
      db: db,
      net: net,
      media: MediaStore(dir.path, db, net),
      settings: const Settings(),
    );
    engines.add(engine);
    await engine.start('${dir.path}/node');
    return engine;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-space-test-');
    network = TestNetwork()..acceptBroadcastWithoutPeers = true;
    engines = [];
  });

  tearDown(() async {
    for (final engine in engines) {
      await engine.stop();
      engine.db.close();
      await (engine.net as TestTransport).controller.close();
    }
    final parent = Directory.systemTemp.absolute.path;
    if (!root.absolute.path.startsWith('$parent${Platform.pathSeparator}') ||
        !root.path.contains('mentos-space-test-')) {
      throw StateError('Unexpected test directory');
    }
    await root.delete(recursive: true);
  });

  test('a join reaches the owner over a direct link, then their messages do too', () async {
    final owner = await node();
    final member = await node();
    network.dropDirectFrom.add(member.me.id);
    final created = await owner.createSpace('Room', 'talk');
    final scope = Scope.channel(created.id, 'general');
    await owner.sendMessage(scope, text: 'hello room');
    expect(owner.messages(scope).single.delivery, Delivery.saved);

    final src = owner.space(created.id)!;
    await member.joinSpace(
      SpaceInfo(
        id: src.id,
        name: src.name,
        about: src.about,
        owner: src.owner,
        key: src.key,
        channels: src.channels,
        forums: src.forums,
        preserve: true,
        joined: 1,
      ),
      [owner.me.id],
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      owner.members(created.id).map((m) => m.id),
      isNot(contains(member.me.id)),
      reason: 'a topic join with nobody listening is not a membership',
    );

    network.dropDirectFrom.clear();
    (member.net as TestTransport).controller.add(LinkEvent(owner.me.id, true));
    await eventually(() => owner.members(created.id).map((m) => m.id).contains(member.me.id));
    expect(member.members(created.id).map((m) => m.id), contains(owner.me.id));
    await eventually(() => member.messages(scope).any((m) => m.text == 'hello room'));

    await owner.sendMessage(scope, text: 'second');
    await eventually(() => member.messages(scope).any((m) => m.text == 'second'));
    expect(
      owner.messages(scope).singleWhere((m) => m.text == 'second').delivery,
      isNot(Delivery.saved),
    );

    await member.leaveSpace(created.id);
    await eventually(() => !owner.members(created.id).map((m) => m.id).contains(member.me.id));
    // joinSpace schedules a history refresh. Let it fire before the engines stop.
    await Future<void>.delayed(const Duration(seconds: 3));
  });
}
