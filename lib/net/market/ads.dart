part of 'market.dart';

/// Ads. A campaign is a signed listing with a budget and a price per view
/// and per click. Phones that opted in show sponsored cards; after a card
/// has been on screen the viewer's phone signs a receipt and sends it to the
/// advertiser. The advertiser's phone checks it and pays, splitting each
/// view between the viewer and the carrier: the phone that passed the
/// campaign to the viewer, so nodes that keep an ad moving earn from it.
///
/// Limits: one paid view and one paid click per viewer per campaign per
/// day, a daily cap per carrier, the campaign's own daily cap and budget,
/// and viewers must already have a ledger account. Receipts prove a
/// signature, not attention; cheap identities can still farm small amounts.
extension Ads on Market {
  static const carrierDailyCap = 300;
  static const minPayout = 10;

  // ---- viewer side --------------------------------------------------------

  Map<String, dynamic> _adPrefs() {
    try {
      final raw = engine.db.getKv('mk-ads');
      if (raw != null) return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {}
    return {'on': false, 'tags': <String>[]};
  }

  bool get adsEnabled => _adPrefs()['on'] == true;
  List<String> get adInterests => [
    for (final t in (_adPrefs()['tags'] as List? ?? const [])) if (t is String) t,
  ];

  void setAds({bool? on, List<String>? interests}) {
    final p = _adPrefs();
    if (on != null) p['on'] = on;
    if (interests != null) p['tags'] = interests.take(12).toList();
    engine.db.setKv('mk-ads', jsonEncode(p));
    _changed();
  }

  Map<String, dynamic> _seen() {
    try {
      final raw = engine.db.getKv('mk-adseen');
      if (raw != null) return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {}
    return {};
  }

  bool _canAfford(Listing ad) {
    final c = engine.coin;
    if (c == null) return false;
    final perView = ad.body['perView'] as int;
    return c.balance(ad.author) >= perView * 5 && !c.flagged(ad.author);
  }

  /// Campaigns that can run right now, best paying and best matching first.
  List<Listing> runningAds() {
    final now = nowMs();
    final interests = adInterests.map((t) => t.toLowerCase()).toSet();
    final ads = listings(kind: Kinds.ad).where((a) {
      return a.active &&
          a.author != me &&
          (a.body['until'] as int) > now &&
          _canAfford(a);
    }).toList();
    int score(Listing a) {
      final overlap = a.tags.where((t) => interests.contains(t.toLowerCase())).length;
      return (a.body['perView'] as int) * (1 + overlap);
    }

    ads.sort((a, b) => score(b).compareTo(score(a)));
    return ads;
  }

  /// The next campaign to show, respecting a three-a-day frequency cap.
  Listing? nextAd({int slot = 0}) {
    if (!adsEnabled) return null;
    final seen = _seen();
    final today = dayKey();
    final options = runningAds().where((a) {
      final s = seen[a.id];
      return s is! Map || s['d'] != today || ((s['n'] as int?) ?? 0) < 3;
    }).toList();
    if (options.isEmpty) return null;
    return options[slot % math.min(options.length, 3)];
  }

  /// Records a view of [ad] and sends the advertiser a signed receipt.
  Future<void> sawAd(Listing ad) => _adReceipt(ad, 'view');

  Future<void> clickedAd(Listing ad) => _adReceipt(ad, 'click');

  Future<void> _adReceipt(Listing ad, String kind) => _serial(() async {
    if (!adsEnabled || ad.author == me || ad.kind != Kinds.ad) return;
    final today = dayKey();
    final seen = _seen();
    final s = seen[ad.id] is Map ? (seen[ad.id] as Map).cast<String, dynamic>() : <String, dynamic>{};
    if (s['d'] != today) {
      s.clear();
      s['d'] = today;
    }
    final flag = kind == 'view' ? 'v' : 'c';
    if (kind == 'view') s['n'] = ((s['n'] as int?) ?? 0) + 1;
    final first = s[flag] != true;
    s[flag] = true;
    seen[ad.id] = s;
    if (seen.length > 400) {
      seen.removeWhere((_, v) => v is! Map || v['d'] != today);
    }
    engine.db.setKv('mk-adseen', jsonEncode(seen));
    if (!first) return;
    final carrier = via(ad.id) ?? '';
    final body = {
      'c': ad.id,
      'v': me,
      'k': kind,
      'd': today,
      'carrier': carrier == me || carrier == ad.author ? '' : carrier,
      'n': toHex(randomBytes(6)),
      'ts': nowMs(),
    };
    final sig = await engine.me.sign(utf8.encode(canonicalJson(body)));
    await _send(ad.author, 'imp', {'r': {...body, 'sig': sig}}, queue: 'mk-imp:${ad.id}:$today:$kind');
  });

  /// What this phone has earned from showing and carrying ads.
  int get adEarnings {
    final c = engine.coin;
    if (c == null) return 0;
    return c.history().where((t) => t.kind == 'send' && t.to == me && t.memo.startsWith('ad:'))
        .fold<int>(0, (s, t) => s + t.amount);
  }

  // ---- advertiser side ----------------------------------------------------

  Rec campaign(String listingId) =>
      record('ad:$listingId') ??
      {
        'id': 'ad:$listingId',
        'kind': 'campaign',
        'listing': listingId,
        'spent': 0,
        'views': 0,
        'clicks': 0,
        'owed': <String, dynamic>{},
        'paid': <String, dynamic>{},
        'seen': <String, dynamic>{},
        'carriers': <String, dynamic>{},
        'days': <String, dynamic>{},
        'viewers': 0,
      };

  Future<Listing> launchAd(Map<String, dynamic> body) async {
    final c = coin;
    final budget = body['budget'] as int? ?? 0;
    if (c.balance() < budget) {
      throw StateError('Your balance does not cover this budget yet');
    }
    final l = await publish(Kinds.ad, {...body, 'status': 'active'});
    _save(campaign(l.id));
    return l;
  }

  Future<void> setAdStatus(String listingId, String status) async {
    final l = listing(listingId);
    if (l == null || l.author != me) return;
    await revise(l, {'status': status});
  }

  Future<void> _onImpression(String from, Map<String, dynamic> m) async {
    final raw = m['r'];
    if (raw is! Map) return;
    final r = raw.cast<String, dynamic>();
    final sig = r.remove('sig');
    final id = r['c'], viewer = r['v'], kind = r['k'], day = r['d'];
    final carrier = r['carrier'] is String ? r['carrier'] as String : '';
    if (sig is! String || id is! String || viewer != from || day is! int) return;
    if (kind != 'view' && kind != 'click') return;
    final today = dayKey();
    final yesterday = dayKey(DateTime.now().subtract(const Duration(days: 1)));
    if (day != today && day != yesterday) return;
    final ad = listing(id);
    if (ad == null || ad.author != me || ad.kind != Kinds.ad) return;
    if (!ad.active || (ad.body['until'] as int) < nowMs()) return;
    if (!await Identity.verify(from, utf8.encode(canonicalJson(r)), sig)) return;
    final c = engine.coin;
    if (c == null) return;
    final v = c.view();
    if (!v.chains.containsKey(from) || v.flagged.contains(from)) return;
    final rec = campaign(id);
    final seen = (rec['seen'] as Map).cast<String, dynamic>();
    final key = '$from|$day|$kind';
    if (seen.containsKey(key)) return;
    final budget = ad.body['budget'] as int;
    final cost = kind == 'view' ? ad.body['perView'] as int : ad.body['perClick'] as int;
    if (cost <= 0) return;
    final spent = rec['spent'] as int;
    if (spent + cost > budget) return;
    final days = (rec['days'] as Map).cast<String, dynamic>();
    final stat = (days['$day'] as Map?)?.cast<String, dynamic>() ?? {'v': 0, 'c': 0, 's': 0};
    if (kind == 'view' && (stat['v'] as int) >= (ad.body['dailyCap'] as int)) return;
    final carriers = (rec['carriers'] as Map).cast<String, dynamic>();
    final validCarrier = isId(carrier) &&
        carrier != from &&
        carrier != me &&
        v.chains.containsKey(carrier) &&
        ((carriers['$carrier|$day'] as int?) ?? 0) < carrierDailyCap;
    final share = ad.body['viewerShare'] as int;
    final toViewer = validCarrier ? cost * share ~/ 100 : cost;
    final toCarrier = cost - toViewer;
    final owed = (rec['owed'] as Map).cast<String, dynamic>();
    if (toViewer > 0) owed[from] = ((owed[from] as int?) ?? 0) + toViewer;
    if (toCarrier > 0) {
      owed[carrier] = ((owed[carrier] as int?) ?? 0) + toCarrier;
      carriers['$carrier|$day'] = ((carriers['$carrier|$day'] as int?) ?? 0) + 1;
    }
    if (!seen.keys.any((k) => k.startsWith('$from|'))) rec['viewers'] = (rec['viewers'] as int) + 1;
    seen[key] = 1;
    // Only today's and yesterday's keys are needed for deduplication.
    seen.removeWhere((k, _) {
      final d = int.tryParse(k.split('|')[1]) ?? 0;
      return d != today && d != yesterday;
    });
    carriers.removeWhere((k, _) {
      final d = int.tryParse(k.split('|').last) ?? 0;
      return d != today && d != yesterday;
    });
    stat[kind == 'view' ? 'v' : 'c'] = (stat[kind == 'view' ? 'v' : 'c'] as int) + 1;
    stat['s'] = (stat['s'] as int) + cost;
    days['$day'] = stat;
    if (days.length > 60) {
      final keys = days.keys.toList()..sort();
      for (final k in keys.take(days.length - 60)) {
        days.remove(k);
      }
    }
    rec['spent'] = spent + cost;
    rec[kind == 'view' ? 'views' : 'clicks'] = (rec[kind == 'view' ? 'views' : 'clicks'] as int) + 1;
    _save(rec);
    if (spent + cost + (ad.body['perView'] as int) > budget) {
      await _publish(ad.kind, {...ad.body, 'status': 'ended'}, id: ad.id);
    }
  }

  Future<void> _adsTick() async {
    final c = engine.coin;
    if (c == null) return;
    var payments = 0;
    for (final rec in records('campaign')) {
      final ad = listing(rec['listing'] as String);
      final ended = ad == null || ad.deleted || ad.status == 'ended';
      final owed = (rec['owed'] as Map).cast<String, dynamic>();
      final paid = (rec['paid'] as Map).cast<String, dynamic>();
      var changed = false;
      for (final payee in owed.keys.toList()) {
        final amount = owed[payee] as int;
        if (amount <= 0 || (amount < minPayout && !ended)) continue;
        if (payments >= 20) break;
        try {
          await c.pay(payee, amount, memo: 'ad:${rec['listing']}');
          payments++;
          owed.remove(payee);
          paid[payee] = ((paid[payee] as int?) ?? 0) + amount;
          changed = true;
        } catch (_) {
          if (ad != null && ad.author == me && ad.status == 'active') {
            await _publish(ad.kind, {...ad.body, 'status': 'paused'}, id: ad.id);
          }
          break;
        }
      }
      if (changed) _save(rec);
      if (ad != null && ad.author == me && ad.status == 'active' && (ad.body['until'] as int) < nowMs()) {
        await _publish(ad.kind, {...ad.body, 'status': 'ended'}, id: ad.id);
      }
    }
  }
}
