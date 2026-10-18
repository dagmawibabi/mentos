import 'dart:convert';

import '../../core/crypto/crypto.dart';
import '../../data/models.dart';
import '../pay/coin.dart';

/// JSON with map keys sorted at every level, so the same listing always
/// signs to the same bytes on every phone.
String canonicalJson(Object? v) => jsonEncode(_sorted(v));

Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return [for (final x in v) _sorted(x)];
  return v;
}

bool isId(Object? s) => s is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

abstract final class Kinds {
  static const item = 'item';
  static const task = 'task';
  static const ad = 'ad';
  static const resource = 'resource';
  static const exchange = 'exchange';
  static const plugin = 'plugin';

  /// A public space's entry in the network directory.
  static const space = 'space';
  static const all = [item, task, ad, resource, exchange, plugin, space];
}

/// Shop departments. The id is what travels; the label is shown.
const shopCategories = <String, String>{
  'electronics': 'Electronics',
  'fashion': 'Fashion',
  'home': 'Home',
  'books': 'Books',
  'art': 'Art & handmade',
  'food': 'Food',
  'digital': 'Digital goods',
  'services': 'Services',
  'vehicles': 'Vehicles',
  'other': 'Other',
};

const taskCategories = <String, String>{
  'errand': 'Errands',
  'design': 'Design',
  'writing': 'Writing',
  'code': 'Code',
  'photo': 'Photo & video',
  'research': 'Research',
  'dare': 'Dares',
  'other': 'Other',
};

const conditions = <String, String>{
  'new': 'New',
  'like-new': 'Like new',
  'used': 'Used',
  'handmade': 'Handmade',
  'digital': 'Digital',
};

/// How an order reaches the buyer.
const deliveryKinds = <String, String>{
  'ship': 'Delivery',
  'pickup': 'Pickup',
  'meet': 'Meet up',
  'digital': 'Instant download',
};

/// Work a phone can do for someone else without running their code.
const jobTypes = <String, String>{
  'gzip': 'Compress a file',
  'image': 'Resize and compress a photo',
  'pow': 'Proof-of-work stamp',
};

const evidenceKinds = <String, String>{
  'text': 'Written report',
  'photo': 'Photos',
  'file': 'Files',
  'link': 'Links',
};

const birrMethods = ['Telebirr', 'CBE Birr', 'CBE', 'Awash', 'Dashen', 'Abyssinia', 'Cash'];

/// One signed, public listing. Anyone can relay it; only its author can
/// change it, and only by signing a higher revision.
class Listing {
  const Listing({
    required this.id,
    required this.kind,
    required this.author,
    required this.rev,
    required this.ts,
    required this.body,
    this.deleted = false,
    this.sig = '',
  });

  final String id;
  final String kind;
  final String author;
  final int rev;
  final int ts;
  final bool deleted;
  final Map<String, dynamic> body;
  final String sig;

  /// Listings not refreshed for this long are hidden and dropped.
  static const ttl = Duration(days: 45);
  static const maxBytes = 24 * 1024;
  static const maxPerAuthor = 60;

  String get signed => canonicalJson({
    'v': 1,
    'id': id,
    'kind': kind,
    'author': author,
    'rev': rev,
    'ts': ts,
    'deleted': deleted,
    'body': body,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'author': author,
    'rev': rev,
    'ts': ts,
    'deleted': deleted,
    'body': body,
    'sig': sig,
  };

  static Listing? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], kind = j['kind'], author = j['author'];
    final rev = j['rev'], ts = j['ts'], body = j['body'], sig = j['sig'];
    final deleted = j['deleted'];
    if (id is! String || kind is! String || author is! String) return null;
    if (rev is! int || ts is! int || body is! Map || sig is! String) return null;
    if (deleted != null && deleted is! bool) return null;
    return Listing(
      id: id,
      kind: kind,
      author: author,
      rev: rev,
      ts: ts,
      deleted: deleted == true,
      body: body.cast<String, dynamic>(),
      sig: sig,
    );
  }

  static Future<Listing> create(
    Identity me, {
    required String id,
    required String kind,
    required int rev,
    required Map<String, dynamic> body,
    bool deleted = false,
  }) async {
    final draft = Listing(
      id: id,
      kind: kind,
      author: me.id,
      rev: rev,
      ts: nowMs(),
      body: body,
      deleted: deleted,
    );
    final problem = draft.problem();
    if (problem != null) {
      throw ArgumentError(
        problem.startsWith('id') || problem.startsWith('bad') || problem == 'too large'
            ? 'This listing cannot be published ($problem)'
            : 'Check the $problem',
      );
    }
    return Listing(
      id: id,
      kind: kind,
      author: me.id,
      rev: rev,
      ts: draft.ts,
      body: body,
      deleted: deleted,
      sig: await me.sign(utf8.encode(draft.signed)),
    );
  }

  Future<bool> verify() async =>
      sig.isNotEmpty && await Identity.verify(author, utf8.encode(signed), sig);

  bool get expired =>
      !deleted && nowMs() - ts > ttl.inMilliseconds;

  // -- common fields --------------------------------------------------------

  String get title => _s('title');
  String get about => _s('about');
  int get price => _i(kind == Kinds.task ? 'reward' : 'price');
  List<String> get tags => _strings(body['tags']);
  String get category => _s('category');
  String get status => body['status'] is String ? body['status'] as String : 'active';
  bool get active =>
      !deleted && !expired && (status == 'active' || status == 'open');
  List<MediaRef> get media => [
    for (final m in (body['media'] is List ? body['media'] as List : const []))
      if (m is Map) ?_ref(m),
  ];
  MediaRef? get cover => media.firstOrNull;

  String _s(String k) => body[k] is String ? body[k] as String : '';
  int _i(String k) => body[k] is int ? body[k] as int : 0;

  /// Search text.
  String get haystack =>
      '$title $about ${tags.join(' ')} $category ${body['location'] ?? ''}'.toLowerCase();

  // -- validation -----------------------------------------------------------

  /// Why this listing must not be stored, or null. Never throws.
  String? problem({int? now}) {
    try {
      return _problem(now ?? nowMs());
    } catch (_) {
      return 'malformed';
    }
  }

  String? _problem(int now) {
    if (!Kinds.all.contains(kind)) return 'unknown kind';
    if (!isId(author)) return 'bad author';
    if (id.length < 8 || id.length > 80 || !RegExp(r'^[A-Za-z0-9:_\-]+$').hasMatch(id)) {
      return 'bad id';
    }
    if (!id.startsWith('${author.substring(0, 8)}-')) return 'id must name its author';
    if (rev < 1 || rev > 1000000) return 'bad revision';
    if (ts <= 0 || ts > now + 600000) return 'bad time';
    if (utf8.encode(canonicalJson(body)).length > maxBytes) return 'too large';
    if (deleted) return null;
    if (!_text(body['title'], 1, 100)) return 'title';
    if (body['about'] != null && !_text(body['about'], 0, 4000)) return 'description';
    if (body['tags'] != null && !_list(body['tags'], 8, (x) => _text(x, 1, 24))) return 'tags';
    if (body['media'] != null && !_list(body['media'], 8, (x) => x is Map && _ref(x) != null)) {
      return 'media';
    }
    if (body['location'] != null && !_text(body['location'], 0, 60)) return 'location';
    if (body['status'] != null && !_text(body['status'], 1, 16)) return 'status';
    final arbiters = body['arbiters'];
    if (arbiters != null && !_list(arbiters, 3, (x) => isId(x) && x != author)) return 'arbiters';
    return switch (kind) {
      Kinds.item => _item(),
      Kinds.task => _task(),
      Kinds.ad => _ad(),
      Kinds.resource => _resource(),
      Kinds.exchange => _exchange(),
      Kinds.plugin => _plugin(),
      Kinds.space => _space(),
      _ => 'unknown kind',
    };
  }

  String? _space() {
    if (!_text(body['space'], 8, 80)) return 'space';
    final invite = body['invite'];
    if (invite is! String || !invite.startsWith('mentos://s/') || invite.length > 8000) return 'invite';
    final members = body['members'];
    if (members != null && (members is! int || members < 0)) return 'members';
    return null;
  }

  String? _item() {
    if (!_money(body['price'], min: 1)) return 'price';
    final stock = body['stock'];
    if (stock is! int || stock < -1 || stock > 1000000) return 'stock';
    if (!shopCategories.containsKey(body['category'])) return 'category';
    if (!conditions.containsKey(body['condition'])) return 'condition';
    final hold = body['holdDays'];
    if (hold is! int || hold < 1 || hold > 60) return 'hold days';
    final delivery = body['delivery'];
    if (!_list(delivery, 6, _deliveryOk) || (delivery as List).isEmpty) return 'delivery';
    final options = body['options'];
    if (options != null &&
        !_list(options, 3, (o) =>
            o is Map &&
            _text(o['name'], 1, 24) &&
            _list(o['values'], 12, (v) => _text(v, 1, 24)) &&
            (o['values'] as List).isNotEmpty)) {
      return 'options';
    }
    return null;
  }

  static bool _deliveryOk(Object? d) =>
      d is Map &&
      _text(d['id'], 1, 16) &&
      _text(d['label'], 1, 40) &&
      deliveryKinds.containsKey(d['kind']) &&
      _money(d['price'], min: 0) &&
      d['days'] is int &&
      (d['days'] as int) >= 0 &&
      (d['days'] as int) <= 90;

  String? _task() {
    if (!_money(body['reward'], min: 1)) return 'reward';
    final deadline = body['deadline'];
    if (deadline is! int || deadline <= 0) return 'deadline';
    if (!taskCategories.containsKey(body['category'])) return 'category';
    if (!_list(body['criteria'], 10, (x) => _text(x, 1, 200))) return 'criteria';
    if (!_list(body['evidence'], 4, (x) => evidenceKinds.containsKey(x)) ||
        (body['evidence'] as List).isEmpty) {
      return 'evidence';
    }
    final review = body['reviewDays'];
    if (review is! int || review < 1 || review > 30) return 'review days';
    if (body['assignee'] != null && !isId(body['assignee'])) return 'assignee';
    if (body['applicants'] != null && body['applicants'] is! int) return 'applicants';
    return null;
  }

  String? _ad() {
    if (!_text(body['text'], 0, 280)) return 'text';
    if (!_money(body['budget'], min: 1)) return 'budget';
    if (!_money(body['perView'], min: 1)) return 'per view';
    if (!_money(body['perClick'], min: 0)) return 'per click';
    final share = body['viewerShare'];
    if (share is! int || share < 0 || share > 100) return 'viewer share';
    final cap = body['dailyCap'];
    if (cap is! int || cap < 1 || cap > 1000000) return 'daily cap';
    final until = body['until'];
    if (until is! int || until <= 0) return 'end date';
    final target = body['target'];
    if (target is! Map || !['url', 'listing', 'profile', 'none'].contains(target['type'])) {
      return 'target';
    }
    if (target['type'] == 'url' && !_url(target['value'])) return 'link';
    if ((target['type'] == 'listing') && !_text(target['value'], 8, 80)) return 'listing';
    if (target['type'] == 'profile' && !isId(target['value'])) return 'profile';
    return null;
  }

  String? _resource() {
    final storage = body['storage'], compute = body['compute'], bench = body['bench'], sandbox = body['sandbox'];
    if (storage == null && compute == null && sandbox == null) return 'offer storage, compute or a sandbox';
    if (sandbox != null) {
      if (sandbox is! Map) return 'sandbox';
      if (!_money(sandbox['perHour'], min: 1)) return 'sandbox price';
      final mb = sandbox['mb'], hours = sandbox['maxHours'], slots = sandbox['slots'];
      if (mb is! int || mb < 1 || mb > 102400) return 'sandbox size';
      if (hours is! int || hours < 1 || hours > 720) return 'sandbox hours';
      if (slots != null && (slots is! int || slots < 1 || slots > 20)) return 'sandbox slots';
    }
    if (storage != null) {
      if (storage is! Map) return 'storage';
      final gb = storage['gb'];
      if (gb is! int || gb < 1 || gb > 4000) return 'storage size';
      if (!_money(storage['perGbDay'], min: 1)) return 'storage price';
    }
    if (compute != null) {
      if (compute is! Map) return 'compute';
      if (!_list(compute['jobs'], jobTypes.length, (x) => jobTypes.containsKey(x)) ||
          (compute['jobs'] as List).isEmpty) {
        return 'jobs';
      }
      if (!_money(compute['perUnit'], min: 1)) return 'compute price';
      final mb = compute['maxMb'];
      if (mb is! int || mb < 1 || mb > 512) return 'job size';
    }
    if (bench is! Map || jsonEncode(bench).length > 4000) return 'diagnostics';
    return null;
  }

  String? _exchange() {
    if (!['sell', 'buy'].contains(body['side'])) return 'side';
    final rate = body['rate'];
    if (rate is! int || rate < 1 || rate > 100000000) return 'rate';
    if (!_money(body['min'], min: 1) || !_money(body['max'], min: 1)) return 'limits';
    if ((body['min'] as int) > (body['max'] as int)) return 'limits';
    if (!_list(body['methods'], 6, (x) => _text(x, 1, 24)) || (body['methods'] as List).isEmpty) {
      return 'payment methods';
    }
    final window = body['windowMins'];
    if (window is! int || window < 10 || window > 1440) return 'payment window';
    if (body['terms'] != null && !_text(body['terms'], 0, 1000)) return 'terms';
    return null;
  }

  /// A script plugin listed for others: where its manifest lives and the
  /// checksum of the script it was reviewed with.
  String? _plugin() {
    if (!_money(body['price'], min: 0)) return 'price';
    final manifest = body['manifest'];
    if (manifest is! String || !_url(manifest)) return 'manifest';
    if (Uri.parse(manifest).scheme != 'https') return 'manifest';
    final pid = body['pluginId'];
    if (pid is! String || !RegExp(r'^[a-z0-9][a-z0-9-]{1,39}$').hasMatch(pid)) return 'plugin id';
    if (!_text(body['version'], 1, 20)) return 'version';
    final sha = body['sha256'];
    if (sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return 'checksum';
    if (!_list(body['permissions'], 16, (x) => _text(x, 1, 24))) return 'permissions';
    if (body['icon'] != null && !_text(body['icon'], 1, 40)) return 'icon';
    if (body['homepage'] != null && !_url(body['homepage'])) return 'homepage';
    if (body['source'] != null && !_url(body['source'])) return 'source';
    final size = body['size'];
    if (size != null && (size is! int || size < 0)) return 'size';
    return null;
  }
}

/// Declarative packs only. Installing one never runs publisher code.
void validatePack(Map<String, dynamic> row) {
  final body = row['body'];
  if (body is! Map || jsonEncode(body).length > 8000) {
    throw ArgumentError('Invalid plugin content');
  }
  final kind = row['plugin'];
  if (kind == 'theme') {
    if (!['emerald', 'blue', 'amber', 'ink'].contains(body['accent'])) {
      throw ArgumentError('Unknown accent');
    }
  } else if (kind == 'stickers' || kind == 'phrases') {
    final values = body[kind == 'stickers' ? 'emoji' : 'lines'];
    if (values is! List ||
        values.isEmpty ||
        values.length > 24 ||
        values.any((x) => x is! String || x.trim().isEmpty || x.length > 300)) {
      throw ArgumentError('Invalid pack entries');
    }
  } else {
    throw ArgumentError('Unsupported plugin type');
  }
}

bool _text(Object? v, int min, int max) =>
    v is String && v.trim().length >= min && v.length <= max;

bool _money(Object? v, {required int min}) =>
    v is int && v >= min && v <= Coin.maxAmount;

bool _list(Object? v, int max, bool Function(Object?) ok) =>
    v is List && v.length <= max && v.every(ok);

bool _url(Object? v) {
  if (v is! String || v.length > 300) return false;
  final u = Uri.tryParse(v);
  return u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty;
}

List<String> _strings(Object? v) => [
  for (final x in (v is List ? v : const [])) if (x is String) x,
];

MediaRef? _ref(Map m) {
  final h = m['h'], key = m['key'], n = m['n'], mime = m['m'], sz = m['sz'];
  if (!isId(h) || key is! String || key.length > 64 || n is! String || n.length > 120) {
    return null;
  }
  if (mime is! String || mime.length > 80 || sz is! int || sz < 0) return null;
  final w = m['w'], ht = m['ht'];
  return MediaRef(
    hash: h as String,
    key: key,
    name: n,
    mime: mime,
    size: sz,
    width: w is int ? w : null,
    height: ht is int ? ht : null,
  );
}

MediaRef? mediaFrom(Object? m) => m is Map ? _ref(m) : null;

/// A buyer's or worker's verdict, tied to the escrow that paid for the
/// work, so only someone who actually traded can leave one.
class Review {
  const Review({
    required this.author,
    required this.subject,
    required this.lock,
    required this.stars,
    required this.text,
    required this.role,
    required this.ts,
    this.listing = '',
    this.sig = '',
  });

  final String author;
  final String subject;
  final String lock;
  final int stars;
  final String text;
  final String role;
  final int ts;
  final String listing;
  final String sig;

  String get id => toHex(sha256(utf8.encode('$author|$lock'))).substring(0, 40);

  String get signed => canonicalJson({
    'v': 1,
    'author': author,
    'subject': subject,
    'lock': lock,
    'stars': stars,
    'text': text,
    'role': role,
    'ts': ts,
    'listing': listing,
  });

  Map<String, dynamic> toJson() => {
    'author': author,
    'subject': subject,
    'lock': lock,
    'stars': stars,
    'text': text,
    'role': role,
    'ts': ts,
    'listing': listing,
    'sig': sig,
  };

  static Review? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['author'], s = j['subject'], l = j['lock'], st = j['stars'];
    final t = j['text'], r = j['role'], ts = j['ts'], sig = j['sig'];
    final listing = j['listing'] ?? '';
    if (!isId(a) || !isId(s) || !isId(l) || a == s) return null;
    if (st is! int || st < 1 || st > 5 || t is! String || t.length > 600) return null;
    if (r is! String || r.length > 16 || ts is! int || sig is! String || listing is! String) {
      return null;
    }
    if (listing.length > 80) return null;
    return Review(
      author: a as String,
      subject: s as String,
      lock: l as String,
      stars: st,
      text: t,
      role: r,
      ts: ts,
      listing: listing,
      sig: sig,
    );
  }

  Future<bool> verify() => Identity.verify(author, utf8.encode(signed), sig);
}
