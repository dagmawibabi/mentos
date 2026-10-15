import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/data/models.dart';
import 'package:mentos/net/views.dart';

void main() {
  test('phrase round-trips to the same identity', () async {
    final a = await Identity.generate();
    final b = await Identity.fromPhrase(a.phrase);
    expect(b.id, a.id);
  });

  test('envelopes verify and reject tampering', () async {
    final me = await Identity.generate();
    final e = await Envelope.create(me, kind: K.post, scope: Scope.feed(me.id), body: {'text': 'hi'});
    expect(await e.verify(), isTrue);
    final wire = e.toWire();
    final forged = Envelope.fromWire({...wire, 'p': wire['p']!.replaceFirst('hi', 'yo')})!;
    expect(await forged.verify(), isFalse);
  });

  test('seal opens only with the right key', () async {
    final key = randomBytes(32);
    final box = await Seal.close(key, utf8.encode('secret'));
    expect(utf8.decode((await Seal.open(key, box))!), 'secret');
    expect(await Seal.open(randomBytes(32), box), isNull);
  });

  test('file cipher round-trips across chunk boundaries', () async {
    final dir = await Directory.systemTemp.createTemp('mentos');
    final data = Uint8List.fromList(List.generate(600 * 1024, (i) => i % 251));
    final key = randomBytes(32);
    final plain = File('${dir.path}/a')..writeAsBytesSync(data);
    final enc = File('${dir.path}/b');
    final out = File('${dir.path}/c');
    await FileCipher.encrypt(plain, enc, key);
    await FileCipher.decrypt(enc, out, key);
    expect(out.readAsBytesSync(), data);
    await expectLater(
      FileCipher.decrypt(enc, out, randomBytes(32), plainSize: data.length),
      throwsA(isA<Object>()),
    );
    expect(out.existsSync(), isFalse);
    expect(File('${out.path}.part').existsSync(), isFalse);
    await dir.delete(recursive: true);
  });

  test('malformed records do not throw while rendering', () async {
    expect(Poll.fromJson({'q': 'test', 'o': 42}), isNull);
    expect(Poll.fromJson({'q': 'test', 'o': ['only']}), isNull);
    expect(Poll.fromJson({'q': 'test', 'o': ['a', 2]}), isNull);
    final ok = Poll.fromJson({'q': 'test', 'o': ['a', 'b']});
    expect(ok?.options, ['a', 'b']);

    expect(Scope.type('nocolon'), '');
    expect(Scope.dmPeer('dm:only', 'abc'), isNull);
    expect(Scope.spaceOf('chan'), isNull);
    expect(Scope.postAuthor('post'), isNull);

    expect(Envelope.fromParts('{"id":"x","k":"msg","a":"aa","s":"dm:a:b"}', 'sig'), isNull);
    expect(MediaRef.fromJson({'h': 'not-a-hash', 'key': 'k'}), isNull);
    expect(SpaceInfo.tryParse('{"id":1}'), isNull);
    expect(GroupInfo.tryParse({'members': [1, true]}), isNull);

    final me = await Identity.generate();
    final other = await Identity.generate();
    final profile = await Envelope.create(
      me,
      kind: K.profile,
      scope: Scope.dm(me.id, other.id),
      body: {'name': 'nope', 'bio': 12},
    );
    expect(profile.sane, isFalse);
    expect(Profile.fromEnvelope(profile).bio, '');
    final real = await Envelope.create(
      me,
      kind: K.profile,
      scope: Scope.profile(me.id),
      body: {'name': 'Ada', 'bio': 'hi'},
    );
    expect(real.sane, isTrue);
    expect(real.allowedHere, isTrue);
  });

  test('a stranger cannot close someone else\'s poll', () async {
    final author = await Identity.generate();
    final other = await Identity.generate();
    final post = await Envelope.create(author, kind: K.msg, scope: Scope.dm(author.id, other.id), body: {
      'text': 'Pick one',
      'poll': {'q': 'Pick one', 'o': ['a', 'b']},
    });
    final target = Item(post, owned: true, kept: false);
    final stranger = await Envelope.create(other, kind: K.vote, scope: post.scope, body: {
      'target': post.id,
      'option': 0,
      'close': true,
    });
    expect(fold([Item(stranger, owned: false, kept: false)], {post.id: target}).closedPolls, isEmpty);
    final owner = await Envelope.create(author, kind: K.vote, scope: post.scope, body: {
      'target': post.id,
      'option': 1,
      'close': true,
    });
    expect(fold([Item(owner, owned: true, kept: false)], {post.id: target}).closedPolls, contains(post.id));
  });
}
