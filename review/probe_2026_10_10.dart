// Synthetic model probes only; no network, account data, or app storage.
import '../lib/core/crypto/crypto.dart';
import '../lib/data/models.dart';
import '../lib/net/views.dart';

Future<void> main() async {
  final owner = await Identity.generate();
  final member = await Identity.generate();
  final scope = Scope.dm(owner.id, member.id);
  final malformed = await Envelope.create(member, kind: K.msg, scope: scope,
      body: {'text': 'hello', 'poll': {'q': 'test', 'o': 42}});
  print('Malformed poll: sane=${malformed.sane}, signature=${await malformed.verify()}');
  try {
    pollState(Item(malformed, owned: false, kept: true), Folded(), owner.id);
    throw StateError('Expected malformed poll to throw');
  } catch (e) {
    print('Poll rendering throws: ${e.runtimeType}');
  }
  final profile = await Envelope.create(member, kind: K.profile, scope: scope,
      body: {'name': 'test', 'bio': ''});
  final parts = Scope.parts(profile.scope);
  print('Profile in DM: sane=${profile.sane}, signature=${await profile.verify()}, '
      'DM authorization predicate=${parts.length == 3 && parts.contains(profile.author) && parts.contains(owner.id)}');
  final group = GroupInfo(id: 'test', name: 'test', owner: owner.id,
      key: 'unchanged-key', members: [member.id]);
  final leave = await Envelope.create(member, kind: K.group,
      scope: Scope.gmeta(group.id), body: {...group.metaJson(), 'members': <String>[]});
  final after = group.withMeta(leave);
  print('Member leave removes member=${!after.has(member.id)}, key unchanged=${after.key == group.key}');
  final takeover = await Envelope.create(member, kind: K.group,
      scope: Scope.gmeta(group.id), body: {'owner': member.id});
  print('Previous takeover fixed=${group.withMeta(takeover).owner == owner.id}');
}
