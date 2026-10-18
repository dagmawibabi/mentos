library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:image/image.dart' as img;

import '../../core/crypto/crypto.dart';
import '../../data/models.dart';
import '../engine.dart';
import '../pay/coin.dart';
import '../transport.dart';
import '../../plugins/script.dart';
import 'listing.dart';

export 'listing.dart';

part 'orders.dart';
part 'tasks.dart';
part 'ads.dart';
part 'resources.dart';
part 'sandbox.dart';
part 'exchange.dart';
part 'probe.dart';
part 'spaces.dart';

typedef Rec = Map<String, dynamic>;

/// How much one identity can be trusted with, from the ledger and from
/// reviews that are backed by real escrows.
class Reputation {
  const Reputation({
    this.sales = 0,
    this.purchases = 0,
    this.tasksDone = 0,
    this.disputes = 0,
    this.reviews = 0,
    this.stars = 0,
    this.since,
    this.badge = false,
    this.flagged = false,
    this.volume = 0,
  });
  final int sales;
  final int purchases;
  final int tasksDone;
  final int disputes;
  final int reviews;
  final double stars;
  final int? since;
  final bool badge;
  final bool flagged;
  final int volume;

  int get trades => sales + purchases + tasksDone;
  bool get isNew => trades == 0;
}

/// The peer-to-peer marketplace. Listings are signed by their author and
/// flood the network over a gossip topic, then sync between any two phones
/// that meet, so a listing reaches people its author has never met. Orders,
/// task work, rentals and trades travel privately over the encrypted direct
/// channel between the two people involved. Money only ever moves through
/// the Mentos ledger, mostly in escrow.
class Market {
  Market(this.engine) {
    _sub = engine.appMessages.where((m) => m.app == app).listen((m) {
      unawaited(_guard(() => _onApp(m.from, m.m)));
    });
    _timer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!_closed) unawaited(_guard(_tick));
    });
    _loadVia();
  }

  static const app = 'mkt';
  static const topicLabel = 'mentos-market-v1';
  static final topic = toHex(sha256(utf8.encode(topicLabel)));
  static const maxListings = 5000;

  final Engine engine;
  StreamSubscription<({String from, String app, Map<String, dynamic> m})>? _sub;
  Timer? _timer;
  final _changes = StreamController<void>.broadcast();
  Future<void> _queue = Future.value();
  bool _closed = false;
  final _via = <String, String>{};
  bool _viaDirty = false;
  final _synced = <String, int>{};

  Stream<void> get changes => _changes.stream;
  String get me => engine.me.id;
  CoinLedger get coin =>
      engine.coin ?? (throw StateError('The wallet is still starting'));

  Future<void> _guard(Future<void> Function() f) {
    final next = _queue.then((_) => f()).catchError((Object _) {});
    _queue = next;
    return next;
  }

  /// Runs [f] after everything already queued and returns its result.
  Future<T> _serial<T>(Future<T> Function() f) {
    final done = Completer<T>();
    unawaited(
      _guard(() async {
        try {
          done.complete(await f());
        } catch (e, st) {
          if (!done.isCompleted) done.completeError(e, st);
        }
      }),
    );
    return done.future;
  }

  Future<void> idle() => _queue;

  Future<void> dispose() async {
    _closed = true;
    _timer?.cancel();
    await _sub?.cancel();
    await _queue;
    _saveVia();
    await _changes.close();
  }

  void _changed() {
    if (!_closed && !_changes.isClosed) _changes.add(null);
  }

  bool _blocked(String id) => engine.db.peer(id)?.blocked ?? false;

  // ---------------------------------------------------------------------------
  // listings

  Listing? listing(String id) {
    final raw = engine.db.listing(id);
    return raw == null ? null : Listing.fromJson(jsonDecode(raw));
  }

  /// Live listings, newest first. Withdrawn, expired and blocked authors'
  /// listings are left out unless [all] is set.
  List<Listing> listings({String? kind, String? author, bool all = false}) {
    final out = <Listing>[];
    for (final raw in engine.db.listings(kind: kind, author: author)) {
      final l = Listing.fromJson(jsonDecode(raw));
      if (l == null) continue;
      if (!all && (l.expired || _blocked(l.author))) continue;
      out.add(l);
    }
    return out;
  }

  List<Listing> mine({String? kind}) => listings(kind: kind, author: me, all: true);

  /// Who passed this listing to this phone: the "carrier" an ad pays.
  String? via(String id) => _via[id];

  String newId() => '${me.substring(0, 8)}-${toHex(randomBytes(10))}';

  /// Signs and spreads a listing. Pass [id] to publish a new revision of
  /// one of yours.
  Future<Listing> publish(String kind, Map<String, dynamic> body, {String? id}) =>
      _serial(() => _publish(kind, body, id: id));

  Future<Listing> _publish(
    String kind,
    Map<String, dynamic> body, {
    String? id,
    bool deleted = false,
  }) async {
    final lid = id ?? newId();
    final head = engine.db.listingHead(lid);
    if (head != null && head.author != me) {
      throw StateError('Only its author can change this listing');
    }
    if (head == null && !deleted && engine.db.listingCountBy(me) >= Listing.maxPerAuthor) {
      throw StateError('You can have ${Listing.maxPerAuthor} listings at once');
    }
    final l = await Listing.create(
      engine.me,
      id: lid,
      kind: kind,
      rev: (head?.rev ?? 0) + 1,
      body: body,
      deleted: deleted,
    );
    _store(l, me);
    await _broadcast({'op': 'l', 'l': l.toJson()});
    _changed();
    return l;
  }

  /// Withdraws a listing everywhere by signing a tombstone revision.
  Future<void> withdraw(String id) => _serial(() async {
    final l = listing(id);
    if (l == null || l.author != me || l.deleted) return;
    await _publish(l.kind, {'title': l.title}, id: id, deleted: true);
  });

  /// Publishes [l] again with [changes] merged into its body.
  Future<Listing> revise(Listing l, Map<String, dynamic> changes) =>
      publish(l.kind, {...l.body, ...changes}, id: l.id);

  void _store(Listing l, String from) {
    engine.db.putListing(
      l.id,
      l.kind,
      l.author,
      l.rev,
      l.ts,
      l.deleted,
      jsonEncode(l.toJson()),
    );
    if (!_via.containsKey(l.id)) {
      _via[l.id] = from;
      _viaDirty = true;
    }
    if (engine.db.listingCount() > maxListings) {
      engine.db.trimListings(maxListings);
    }
  }

  Future<bool> _accept(Listing l, String from) async {
    if (l.problem() != null) return false;
    if (_blocked(l.author)) return false;
    if (!l.deleted && l.expired) return false;
    final head = engine.db.listingHead(l.id);
    if (head != null && (head.author != l.author || head.rev >= l.rev)) {
      return false;
    }
    if (head == null &&
        !l.deleted &&
        engine.db.listingCountBy(l.author) >= Listing.maxPerAuthor) {
      return false;
    }
    if (!await l.verify()) return false;
    _store(l, from);
    return true;
  }

  void _loadVia() {
    try {
      final raw = engine.db.getKv('mk-via');
      if (raw == null) return;
      final m = jsonDecode(raw);
      if (m is Map) {
        for (final e in m.entries) {
          if (e.key is String && e.value is String) _via[e.key as String] = e.value as String;
        }
      }
    } catch (_) {}
  }

  void _saveVia() {
    if (!_viaDirty) return;
    _viaDirty = false;
    try {
      if (_via.length > maxListings) {
        final keep = engine.db.listingRevs().keys.toSet();
        _via.removeWhere((k, _) => !keep.contains(k));
      }
      engine.db.setKv('mk-via', jsonEncode(_via));
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // network

  Future<void> join() => _guard(() async {
    if (_closed) return;
    try {
      await engine.net.join(topic, const []);
    } catch (_) {}
  });

  /// Called when a phone links up or joins the market topic: compare what
  /// each side holds.
  Future<void> onPeer(String peer) => _guard(() async {
    if (_closed || peer == me || _blocked(peer)) return;
    final last = _synced[peer] ?? 0;
    if (nowMs() - last < 20000) return;
    _synced[peer] = nowMs();
    final revs = engine.db.listingRevs();
    final reviews = engine.db.allReviews().length;
    await _send(peer, 'sum', {
      'revs': [
        for (final e in revs.entries.take(maxListings)) [e.key, e.value],
      ],
      'rv': reviews,
      'rvh': _reviewDigest(),
    });
  });

  Future<void> onGossip(String from, Map<String, dynamic> m) => _guard(() async {
    if (_closed || _blocked(from)) return;
    switch (m['op']) {
      case 'l':
        final l = Listing.fromJson(m['l']);
        if (l != null && await _accept(l, from)) {
          _changed();
          _onListingSeen(l);
        }
      case 'r':
        final r = Review.fromJson(m['r']);
        if (r != null && await _acceptReview(r)) _changed();
    }
  });

  Future<void> _broadcast(Map<String, dynamic> body) async {
    if (_closed || !engine.running) return;
    final bytes = utf8.encode(jsonEncode(body));
    if (bytes.length > 60000) return;
    try {
      await engine.net.broadcast(topic, Uint8List.fromList(bytes));
    } catch (_) {}
  }

  Future<bool> _send(String peer, String op, Map<String, dynamic> body, {String? queue}) async {
    if (peer == me) return false;
    try {
      return await engine.sendApp(peer, app, {...body, 'op': op}, queueId: queue);
    } catch (_) {
      return false;
    }
  }

  Future<void> _onApp(String from, Map<String, dynamic> m) async {
    if (_closed || from == me || _blocked(from)) return;
    switch (m['op']) {
      case 'sum':
        await _onSummary(from, m);
      case 'want':
        final ids = m['ids'];
        if (ids is List) await _pushListings(from, ids.whereType<String>().take(500).toList());
      case 'ls':
        final list = m['ls'];
        if (list is List) {
          var any = false;
          for (final raw in list.take(60)) {
            final l = Listing.fromJson(raw);
            if (l != null && await _accept(l, from)) {
              any = true;
              _onListingSeen(l);
            }
          }
          if (any) _changed();
        }
      case 'rvs':
        final list = m['rs'];
        if (list is List) {
          var any = false;
          for (final raw in list.take(200)) {
            final r = Review.fromJson(raw);
            if (r != null && await _acceptReview(r)) any = true;
          }
          if (any) _changed();
        }
      case 'order':
      case 'order-up':
        await _onOrderMessage(from, m);
      case 'apply':
      case 'assign':
      case 'task-up':
        await _onTaskMessage(from, m);
      case 'imp':
        await _onImpression(from, m);
      case 'lease':
      case 'lease-up':
      case 'job':
      case 'job-up':
        await _onResourceMessage(from, m);
      case 'box':
        await _onBox(from, m);
      case 'box-up':
        await _onBoxUp(from, m);
      case 'trade':
      case 'trade-up':
        await _onTradeMessage(from, m);
    }
  }

  Future<void> _onSummary(String from, Map<String, dynamic> m) async {
    final raw = m['revs'];
    if (raw is! List) return;
    final theirs = <String, int>{};
    for (final row in raw.take(maxListings)) {
      if (row is List && row.length == 2 && row[0] is String && row[1] is int) {
        theirs[row[0] as String] = row[1] as int;
      }
    }
    final mine = engine.db.listingRevs();
    final push = <String>[
      for (final e in mine.entries)
        if ((theirs[e.key] ?? 0) < e.value) e.key,
    ];
    final want = <String>[
      for (final e in theirs.entries)
        if ((mine[e.key] ?? 0) < e.value) e.key,
    ];
    await _pushListings(from, push);
    for (var i = 0; i < want.length; i += 400) {
      await _send(from, 'want', {'ids': want.sublist(i, math.min(i + 400, want.length))});
    }
    if (m['rvh'] != _reviewDigest()) {
      final reviews = engine.db.allReviews();
      for (var i = 0; i < reviews.length; i += 100) {
        await _send(from, 'rvs', {
          'rs': [
            for (final r in reviews.sublist(i, math.min(i + 100, reviews.length))) jsonDecode(r),
          ],
        });
      }
    }
  }

  Future<void> _pushListings(String peer, List<String> ids) async {
    final batch = <Object?>[];
    var bytes = 0;
    Future<void> flush() async {
      if (batch.isEmpty) return;
      await _send(peer, 'ls', {'ls': List.of(batch)});
      batch.clear();
      bytes = 0;
    }

    for (final id in ids) {
      final raw = engine.db.listing(id);
      if (raw == null) continue;
      batch.add(jsonDecode(raw));
      bytes += raw.length;
      if (batch.length >= 40 || bytes > 600000) await flush();
    }
    await flush();
  }

  // ---------------------------------------------------------------------------
  // reviews and reputation

  String _reviewDigest() {
    final ids = engine.db.allReviews().map((r) {
      final x = Review.fromJson(jsonDecode(r));
      return x?.id ?? '';
    }).toList()
      ..sort();
    return toHex(sha256(utf8.encode(ids.join()))).substring(0, 16);
  }

  Future<bool> _acceptReview(Review r) async {
    if (engine.db.hasReview(r.id)) return false;
    if (_blocked(r.author)) return false;
    if (r.ts > nowMs() + 600000) return false;
    if (!await r.verify()) return false;
    engine.db.putReview(r.id, r.subject, r.author, r.ts, jsonEncode(r.toJson()));
    return true;
  }

  /// A review counts once the ledger shows the two of them on either side
  /// of the escrow it names.
  bool reviewBacked(Review r) {
    final e = engine.coin?.escrow(r.lock);
    if (e == null) return false;
    return (e.payer == r.author && e.payee == r.subject) ||
        (e.payee == r.author && e.payer == r.subject);
  }

  List<Review> reviewsOf(String id, {bool backedOnly = true}) => [
    for (final raw in engine.db.reviews(id))
      if (Review.fromJson(jsonDecode(raw)) case final r?)
        if (!backedOnly || reviewBacked(r)) r,
  ];

  Review? myReviewFor(String lock) {
    final id = Review(author: me, subject: me, lock: lock, stars: 1, text: '', role: '', ts: 0).id;
    for (final raw in engine.db.allReviews()) {
      final r = Review.fromJson(jsonDecode(raw));
      if (r != null && r.id == id) return r;
    }
    return null;
  }

  /// Rates the person on the other side of escrow [lock].
  Future<Review> review({
    required String lock,
    required String subject,
    required int stars,
    String text = '',
    required String role,
    String listing = '',
  }) => _serial(() async {
    final e = coin.escrow(lock);
    if (e == null || !e.involves(me) || !e.involves(subject) || subject == me) {
      throw StateError('You can only review someone you traded with');
    }
    if (myReviewFor(lock) != null) throw StateError('You already reviewed this');
    final draft = Review(
      author: me,
      subject: subject,
      lock: lock,
      stars: stars.clamp(1, 5),
      text: text.trim(),
      role: role,
      ts: nowMs(),
      listing: listing,
    );
    final r = Review(
      author: me,
      subject: subject,
      lock: lock,
      stars: draft.stars,
      text: draft.text,
      role: role,
      ts: draft.ts,
      listing: listing,
      sig: await engine.me.sign(utf8.encode(draft.signed)),
    );
    engine.db.putReview(r.id, r.subject, r.author, r.ts, jsonEncode(r.toJson()));
    await _broadcast({'op': 'r', 'r': r.toJson()});
    _changed();
    return r;
  });

  Reputation reputation(String id) {
    final c = engine.coin;
    if (c == null) return const Reputation();
    final v = c.view();
    var sales = 0, purchases = 0, tasks = 0, disputes = 0, volume = 0;
    for (final e in v.escrows.values) {
      if (!e.involves(id)) continue;
      if (e.disputed && e.payee == id) disputes++;
      if (e.released == 0) continue;
      if (e.payee == id && e.memo.startsWith('order:')) sales++;
      if (e.payer == id && e.memo.startsWith('order:')) purchases++;
      if (e.payee == id && e.memo.startsWith('task:')) tasks++;
      if (e.payee == id) volume += e.released;
    }
    final reviews = reviewsOf(id);
    final stars = reviews.isEmpty
        ? 0.0
        : reviews.fold<int>(0, (s, r) => s + r.stars) / reviews.length;
    final chain = v.chains[id];
    int? since;
    if (chain != null) {
      for (final t in chain) {
        if (t.ts > 0) {
          since = t.ts;
          break;
        }
      }
    }
    return Reputation(
      sales: sales,
      purchases: purchases,
      tasksDone: tasks,
      disputes: disputes,
      reviews: reviews.length,
      stars: stars,
      since: since,
      badge: v.badges.contains(id),
      flagged: v.flagged.contains(id),
      volume: volume,
    );
  }

  // ---------------------------------------------------------------------------
  // private records

  Rec? record(String id) {
    final raw = engine.db.record(id);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  List<Rec> records(String kind) => [
    for (final raw in engine.db.records(kind)) ?_decode(raw),
  ];

  Rec? _decode(String raw) {
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  void _save(Rec r) {
    r['ts'] = nowMs();
    engine.db.putRecord(r['id'] as String, r['kind'] as String, r['ts'] as int, jsonEncode(r));
    _changed();
  }

  /// Appends a step to a record's timeline once; [eid] makes repeats harmless.
  bool _event(Rec r, String by, String what, {String text = '', String? eid, Map<String, dynamic>? data}) {
    final events = (r['events'] as List? ?? []).cast<dynamic>().toList();
    final id = eid ?? '${by.substring(0, 6)}-$what-${nowMs()}';
    if (events.any((e) => e is Map && e['id'] == id)) return false;
    events.add({
      'id': id,
      'by': by,
      'what': what,
      'ts': nowMs(),
      if (text.isNotEmpty) 'text': text,
      ...?data,
    });
    if (events.length > 80) events.removeRange(0, events.length - 80);
    r['events'] = events;
    return true;
  }

  void _notify(String who, String id, String what, String text, String route) {
    engine.noteActivity(
      Activity(
        id: 'mk:$id:$what:${nowMs() ~/ 1000}',
        kind: 'market',
        actor: who,
        ref: route,
        scope: what,
        ts: nowMs(),
        text: text,
      ),
      title: engine.nameOf(who),
      body: text[0].toUpperCase() + text.substring(1),
      route: route,
      category: 'other',
    );
  }

  /// Reads the escrow a counterparty attached to a message, after storing
  /// the payments they bundled with it.
  Future<Escrow?> _escrowFrom(Object? bundle, String lock) async {
    if (bundle is List && bundle.isNotEmpty) await coin.absorb(bundle);
    await coin.idle();
    return coin.escrow(lock);
  }

  /// Runs the periodic housekeeping now (payouts, audits, claims).
  Future<void> tick() => _serial(_tick);

  /// Holds a phone keeps re-checking until the ledger has caught up.
  Future<void> _tick() async {
    if (_closed) return;
    _saveVia();
    await _refreshOwn();
    await _ordersTick();
    await _adsTick();
    await _resourcesTick();
    await _boxesTick();
    await _tradesTick();
    await _spacesTick();
  }

  /// Re-signs this phone's live listings well before they expire.
  Future<void> _refreshOwn() async {
    for (final l in mine()) {
      if (l.deleted) continue;
      if (nowMs() - l.ts < const Duration(days: 7).inMilliseconds) continue;
      try {
        await _publish(l.kind, l.body, id: l.id);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // cart

  List<Rec> cart() {
    try {
      final raw = engine.db.getKv('mk-cart');
      if (raw == null) return const [];
      return [
        for (final x in jsonDecode(raw) as List)
          if (x is Map) x.cast<String, dynamic>(),
      ];
    } catch (_) {
      return const [];
    }
  }

  void _saveCart(List<Rec> lines) {
    engine.db.setKv('mk-cart', jsonEncode(lines));
    _changed();
  }

  int get cartCount => cart().fold<int>(0, (s, l) => s + ((l['qty'] as int?) ?? 0));

  void addToCart(Listing l, {int qty = 1, Map<String, String> options = const {}}) {
    if (l.kind != Kinds.item || l.author == me) {
      throw StateError('Only other people’s items go in the cart');
    }
    final lines = [...cart()];
    final key = '${l.id}|${canonicalJson(options)}';
    final i = lines.indexWhere((x) => x['key'] == key);
    if (i >= 0) {
      lines[i] = {...lines[i], 'qty': (lines[i]['qty'] as int) + qty};
    } else {
      lines.add({'key': key, 'listing': l.id, 'qty': qty, 'options': options});
    }
    _saveCart(lines);
  }

  void setCartQty(String key, int qty) {
    final lines = [...cart()];
    if (qty <= 0) {
      lines.removeWhere((x) => x['key'] == key);
    } else {
      final i = lines.indexWhere((x) => x['key'] == key);
      if (i >= 0) lines[i] = {...lines[i], 'qty': qty};
    }
    _saveCart(lines);
  }

  void clearCart([Iterable<String>? keys]) {
    if (keys == null) {
      _saveCart(const []);
      return;
    }
    final drop = keys.toSet();
    _saveCart([...cart()]..removeWhere((x) => drop.contains(x['key'])));
  }

  // ---------------------------------------------------------------------------
  // plugins

  /// Plugin listings that point at a real script.
  List<Listing> pluginListings() => [
    for (final l in listings(kind: Kinds.plugin))
      if (!l.deleted && l.body['manifest'] is String && l.body['sha256'] is String) l,
  ];

  bool pluginPaid(Listing l) => l.price == 0 || l.author == me || engine.listingOwned(l.id);

  /// Pays a priced plugin's publisher once. Installing is up to the caller,
  /// which must show the permissions first.
  Future<void> buyPlugin(Listing l) async {
    if (l.kind != Kinds.plugin) throw StateError('Not a plugin');
    if (!pluginPaid(l)) {
      await coin.payOnce(l.author, l.price, memo: 'plugin:${l.id.substring(0, math.min(l.id.length, 60))}');
    }
    engine.noteOwned(l.id);
    _changed();
  }

  // ---------------------------------------------------------------------------
  // listing side effects

  void _onListingSeen(Listing l) {
    if (l.kind == Kinds.task && l.body['assignee'] == me) _changed();
  }
}

/// `yyyymmdd` in local time, for daily limits.
int dayKey([DateTime? t]) {
  final d = t ?? DateTime.now();
  return d.year * 10000 + d.month * 100 + d.day;
}

List<MediaRef> refsFrom(Object? list) => [
  for (final m in (list is List ? list : const [])) ?mediaFrom(m),
];
