import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/engine.dart';

import 'support/fake_net.dart';

void main() {
  late Directory root;
  late TestNetwork network;
  late List<Engine> engines;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mentos-gkeys-');
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

  Future<Engine> node({Identity? identity}) async {
    final e = await openEngine(root, network, identity: identity);
    engines.add(e);
    return e;
  }

  Future<void> join(Engine owner, Engine member, String gid) async {
    await owner.inviteToGroup(gid, [member.me.id]);
    await eventually(() => member.groupInvite(gid) != null);
    expect(member.groupInvite(gid)!.containsKey('key'), isFalse, reason: 'no key before accepting');
    await member.respondGroupInvite(gid, true);
    await eventually(() => member.group(gid)?.key == owner.group(gid)!.key);
  }

  test('the key arrives only after accepting; declining never gets it', () async {
    final a = await node();
    final b = await node();
    final c = await node();
    final g = await a.createGroup('crew', []);
    await join(a, b, g.id);
    await a.inviteToGroup(g.id, [c.me.id]);
    await eventually(() => c.groupInvite(g.id) != null);
    await c.respondGroupInvite(g.id, false);
    expect(c.group(g.id), isNull);
    expect(network.messages.where((m) => m.to == c.me.id && m.body['t'] == 'gkey'), isEmpty);
  });

  test('a member leaving makes the owner rotate; the leaver lacks the new key', () async {
    final a = await node();
    final b = await node();
    final c = await node();
    final g = await a.createGroup('crew', []);
    await join(a, b, g.id);
    await join(a, c, g.id);
    final before = a.group(g.id)!.key;
    final leaverKey = c.group(g.id)!.key;
    await c.leaveGroup(g.id);
    await eventually(() => a.group(g.id)!.key != before);
    await eventually(() => b.group(g.id)!.key == a.group(g.id)!.key);
    expect(a.group(g.id)!.members, isNot(contains(c.me.id)));
    expect(a.group(g.id)!.key, isNot(leaverKey));
    expect(network.messages.where((m) => m.to == c.me.id && m.body['t'] == 'gkey' && m.body['key'] == a.group(g.id)!.key), isEmpty);
  });

  test('an acceptance that arrives after the owner restarts still admits the member', () async {
    final a = await node();
    final b = await node();
    final g = await a.createGroup('crew', []);
    await a.inviteToGroup(g.id, [b.me.id]);
    await eventually(() => b.groupInvite(g.id) != null);

    await a.stop();
    a.db.close();
    engines.remove(a);
    await (a.net as TestTransport).controller.close();
    final a2 = await node(identity: a.me);

    await b.respondGroupInvite(g.id, true);
    await eventually(() => a2.group(g.id)!.members.contains(b.me.id));
    await eventually(() => b.group(g.id)?.key == a2.group(g.id)!.key);
  });

  test('messages sealed with the previous key still open after a rotation', () async {
    final a = await node();
    final b = await node();
    final c = await node();
    final g = await a.createGroup('crew', []);
    await join(a, b, g.id);
    await join(a, c, g.id);
    final scope = Scope.gdm(g.id);
    // b is offline during the rotation and sends with the key it still has.
    (b.net as TestTransport).online = false;
    final late = await b.sendMessage(scope, text: 'sent before I heard about the new key');
    await c.leaveGroup(g.id);
    await eventually(() => a.group(g.id)!.members.length == 2);
    (b.net as TestTransport).online = true;
    await b.flushDeliveries();
    await eventually(() => a.messages(scope).any((m) => m.id == late.id));
  });

  test('a revoked invite cannot be accepted', () async {
    final a = await node();
    final b = await node();
    final g = await a.createGroup('crew', []);
    await a.inviteToGroup(g.id, [b.me.id]);
    await eventually(() => b.groupInvite(g.id) != null);
    expect(a.pendingInvites(g.id), [b.me.id]);
    a.revokeGroupInvite(g.id, b.me.id);
    expect(a.pendingInvites(g.id), isEmpty);
    await b.respondGroupInvite(g.id, true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(a.group(g.id)!.members, isNot(contains(b.me.id)));
    expect(network.messages.where((m) => m.to == b.me.id && m.body['t'] == 'gkey'), isEmpty);
  });
}
