// Local, synthetic review probes. No network access or real account data.
// Run with: dart --packages=.dart_tool/package_config.json review/probe.dart
import 'dart:io';
import 'dart:typed_data';
import '../lib/core/crypto/crypto.dart';
import '../lib/data/models.dart';
import '../lib/net/views.dart';

Future<void> main() async {
  final owner = await Identity.generate();
  final member = await Identity.generate();
  final group = GroupInfo(id: 'test', name: 'original', owner: owner.id,
      key: '', members: [member.id]);
  final takeover = await Envelope.create(member, kind: K.group,
      scope: Scope.gmeta(group.id), body: {'owner': member.id, 'members': [member.id]});
  print('Member signature valid: ${await takeover.verify()}; '
      'membership gate passes: ${group.has(takeover.author)}; '
      'withMeta changes owner: ${group.withMeta(takeover).owner == member.id}');

  final post = await Envelope.create(owner, kind: K.post,
      scope: Scope.feed(owner.id), body: {'poll': {'q': 'Test', 'o': ['A', 'B']}});
  final vote = await Envelope.create(member, kind: K.vote,
      scope: Scope.post(owner.id, post.id), body: {'target': post.id, 'option': 0, 'close': true});
  final folded = fold([Item(vote, owned: false, kept: false)],
      {post.id: Item(post, owned: true, kept: false)});
  print('Non-owner vote closes poll: ${folded.closedPolls.contains(post.id)}');

  final bad = await Envelope.create(member, kind: K.msg,
      scope: Scope.dm(owner.id, member.id), body: {'text': 42});
  final parsed = Envelope.fromWire(bad.toWire())!;
  print('Malformed message accepted by parser and signature: ${await parsed.verify()}');
  try {
    parsed.body['text'] as String?;
  } catch (e) {
    print('Message render cast throws: ${e.runtimeType}');
  }

  final root = await Directory.systemTemp.createTemp('mentos-review-');
  try {
    final src = File('${root.path}/plain');
    final enc = File('${root.path}/encrypted');
    final out = File('${root.path}/decrypted');
    final key = randomBytes(32);
    await src.writeAsBytes(Uint8List(FileCipher.chunk + 10));
    await FileCipher.encrypt(src, enc, key);
    final bytes = await enc.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await enc.writeAsBytes(bytes);
    try {
      await FileCipher.decrypt(enc, out, key);
    } catch (e) {
      print('Authentication failure leaves plaintext file: ${await out.exists()}; '
          'bytes: ${await out.length()}');
    }
  } finally {
    final tempRoot = Directory.systemTemp.absolute.path;
    if (!root.absolute.path.startsWith('$tempRoot${Platform.pathSeparator}') ||
        !root.uri.pathSegments.any((s) => s.startsWith('mentos-review-'))) {
      throw StateError('Unexpected temporary path');
    }
    await root.delete(recursive: true);
  }
}
