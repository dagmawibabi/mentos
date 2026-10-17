part of 'market.dart';

/// The public space directory. A space its owner marks public is listed as
/// a signed entry that spreads like any listing, so people who have never
/// met a member can still find it. The entry carries the owner-signed
/// invite: a public space's key is, by definition, available to anyone.
extension SpaceDirectory on Market {
  /// Entries are only shown when the invite inside was signed by the
  /// entry's own author, so nobody can list someone else's space as theirs.
  List<Listing> publicSpaces() =>
      [for (final l in listings(kind: Kinds.space)) if (!l.deleted && !l.expired && _ownInvite(l)) l]
        ..sort((a, b) => ((b.body['members'] as int?) ?? 0).compareTo((a.body['members'] as int?) ?? 0));

  Listing? spaceListing(String spaceId) => listings(kind: Kinds.space, all: true)
      .where((l) => l.body['space'] == spaceId && !l.deleted && _ownInvite(l))
      .firstOrNull;

  bool _ownInvite(Listing l) {
    try {
      final m = RegExp(r'^mentos://s/([A-Za-z0-9_\-]+)$').firstMatch('${l.body['invite']}');
      if (m == null) return false;
      final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(m.group(1)!)))) as Map;
      final e = Envelope.fromWire(j['e']);
      return e != null && e.author == l.author && e.body['id'] == l.body['space'];
    } catch (_) {
      return false;
    }
  }

  String _spaceListingId(String spaceId) {
    final clean = spaceId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return '${me.substring(0, 8)}-sp-${clean.substring(0, math.min(24, clean.length))}';
  }

  /// Publishes, refreshes or withdraws the directory entry for a space
  /// this phone owns, to match whether it is public.
  Future<void> syncSpace(String spaceId) => _serial(() => _syncSpace(spaceId));

  Future<void> _syncSpace(String spaceId) async {
    final s = engine.db.space(spaceId);
    final id = _spaceListingId(spaceId);
    final current = listing(id);
    if (s == null || s.owner != me || !s.public) {
      if (current != null && !current.deleted) {
        await _publish(Kinds.space, {'title': current.title}, id: id, deleted: true);
      }
      return;
    }
    final members = engine.members(spaceId).length;
    final fresh = current == null ||
        current.deleted ||
        current.title != s.name ||
        current.about != s.about ||
        current.body['members'] != members ||
        nowMs() - current.ts > const Duration(days: 7).inMilliseconds;
    if (!fresh) return;
    final invite = await engine.spaceInvite(spaceId);
    await _publish(Kinds.space, {
      'title': s.name.isEmpty ? 'Space' : (s.name.length > 100 ? s.name.substring(0, 100) : s.name),
      if (s.about.isNotEmpty) 'about': s.about.length > 4000 ? s.about.substring(0, 4000) : s.about,
      'space': spaceId,
      'invite': invite,
      'members': members,
    }, id: id);
  }

  Future<void> _spacesTick() async {
    for (final s in engine.db.spaces()) {
      if (s.owner != me) continue;
      try {
        await _syncSpace(s.id);
      } catch (_) {}
    }
  }
}
