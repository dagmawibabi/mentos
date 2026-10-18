import '../plugins/plugins_screen.dart';
import '../../plugins/plugins.dart';
import '../../plugins/plugin_providers.dart';
import 'package:crypto/crypto.dart' as c;
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/market/market.dart';
import '../../net/pay/coin.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import '../common/attach.dart';
import 'market_kit.dart';

/// Create or edit a listing of any kind.
class SellScreen extends ConsumerStatefulWidget {
  const SellScreen({super.key, required this.kind, this.id});
  final String kind;
  final String? id;

  @override
  ConsumerState<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends ConsumerState<SellScreen> {
  final _title = TextEditingController();
  final _about = TextEditingController();
  final _price = TextEditingController();
  final _tags = TextEditingController();
  final _location = TextEditingController();
  final _stock = TextEditingController(text: '1');
  final _extra = TextEditingController();
  final _rate = TextEditingController();
  final _min = TextEditingController();
  final _max = TextEditingController();
  final _payout = TextEditingController();
  final _perView = TextEditingController(text: '0.02');
  final _perClick = TextEditingController(text: '0.10');
  final _dailyCap = TextEditingController(text: '500');
  final _perUnit = TextEditingController();

  final _media = <MediaRef>[];
  final _pending = <Pending>[];
  final _digital = <Pending>[];
  final _delivery = <Map<String, dynamic>>[];
  final _options = <Map<String, dynamic>>[];
  final _criteria = <String>[];
  final _arbiters = <String>{};
  final _evidence = <String>{'text', 'photo'};
  final _jobs = <String>{'gzip', 'pow'};
  final _methods = <String>{'Telebirr'};

  String _category = '';
  String _condition = 'new';
  bool _unlimited = false;
  int _holdDays = 7;
  int _reviewDays = 3;
  DateTime _deadline = DateTime.now().add(const Duration(days: 3));
  String _side = 'sell';
  int _window = 30;
  String _targetType = 'none';
  String _targetValue = '';
  int _share = 50;
  int _adDays = 7;
  bool _offerStorage = true;
  bool _offerCompute = true;
  bool _offerBox = false;
  final _perHour = TextEditingController(text: '0.50');
  int _boxMb = 256;
  int _boxHours = 24;
  int _boxSlots = 2;
  int _gb = 5;
  int _maxMb = 64;
  final _manifestUrl = TextEditingController();
  final _sourceUrl = TextEditingController();
  final _homepage = TextEditingController();
  ({PluginManifest manifest, String sha, int size, String url})? _fetched;
  String? _fetchError;
  bool _checking = false;
  bool _busy = false;
  Listing? _editing;

  @override
  void initState() {
    super.initState();
    final m = ref.read(marketProvider);
    _editing = widget.id == null ? null : m?.listing(widget.id!);
    _category = widget.kind == Kinds.task ? 'errand' : 'other';
    if (widget.kind == Kinds.item) {
      _delivery.add({'id': 'pickup', 'label': 'Pickup', 'kind': 'pickup', 'price': 0, 'days': 0});
    }
    final bench = m?.lastBench;
    if (bench != null && m != null) {
      final s = m.suggestOffer(bench);
      _gb = s.gb;
      _price.text = widget.kind == Kinds.resource ? Coin.format(s.perGbDay) : _price.text;
      _perUnit.text = Coin.format(s.perUnit);
    }
    final l = _editing;
    if (l != null) _load(l);
  }

  void _load(Listing l) {
    final b = l.body;
    _title.text = l.title;
    _about.text = l.about;
    _tags.text = l.tags.join(', ');
    _location.text = '${b['location'] ?? ''}';
    _media.addAll(l.media);
    _arbiters.addAll((b['arbiters'] as List?)?.whereType<String>() ?? const []);
    if (b['category'] is String) _category = b['category'] as String;
    switch (l.kind) {
      case Kinds.item:
        _price.text = Coin.format(l.price);
        final stock = b['stock'] as int;
        _unlimited = stock < 0;
        _stock.text = stock < 0 ? '1' : '$stock';
        _condition = '${b['condition']}';
        _holdDays = b['holdDays'] as int;
        _delivery
          ..clear()
          ..addAll((b['delivery'] as List).whereType<Map>().map((d) => d.cast<String, dynamic>()));
        _options.addAll((b['options'] as List? ?? const []).whereType<Map>().map((d) => d.cast<String, dynamic>()));
      case Kinds.task:
        _price.text = Coin.format(l.price);
        _deadline = DateTime.fromMillisecondsSinceEpoch(b['deadline'] as int);
        _criteria.addAll((b['criteria'] as List).whereType<String>());
        _evidence
          ..clear()
          ..addAll((b['evidence'] as List).whereType<String>());
        _reviewDays = b['reviewDays'] as int;
      case Kinds.ad:
        _extra.text = '${b['text'] ?? ''}';
        _price.text = Coin.format(b['budget'] as int);
        _perView.text = Coin.format(b['perView'] as int);
        _perClick.text = Coin.format(b['perClick'] as int);
        _share = b['viewerShare'] as int;
        _dailyCap.text = '${b['dailyCap']}';
        final t = (b['target'] as Map).cast<String, dynamic>();
        _targetType = '${t['type']}';
        _targetValue = '${t['value'] ?? ''}';
      case Kinds.resource:
        final s = b['storage'] as Map?, c = b['compute'] as Map?;
        _offerStorage = s != null;
        _offerCompute = c != null;
        final sb = b['sandbox'] as Map?;
        _offerBox = sb != null;
        if (sb != null) {
          _perHour.text = Coin.format(sb['perHour'] as int);
          _boxMb = sb['mb'] as int;
          _boxHours = sb['maxHours'] as int;
          _boxSlots = (sb['slots'] as int?) ?? 2;
        }
        if (s != null) {
          _gb = s['gb'] as int;
          _price.text = Coin.format(s['perGbDay'] as int);
        }
        if (c != null) {
          _jobs
            ..clear()
            ..addAll((c['jobs'] as List).whereType<String>());
          _perUnit.text = Coin.format(c['perUnit'] as int);
          _maxMb = c['maxMb'] as int;
        }
      case Kinds.exchange:
        _side = '${b['side']}';
        _rate.text = ((b['rate'] as int) / 100).toStringAsFixed(2);
        _min.text = Coin.format(b['min'] as int);
        _max.text = Coin.format(b['max'] as int);
        _methods
          ..clear()
          ..addAll((b['methods'] as List).whereType<String>());
        _window = b['windowMins'] as int;
        _extra.text = '${b['terms'] ?? ''}';
      case Kinds.plugin:
        _price.text = Coin.format(l.price);
        if (b['manifest'] is String) {
          _manifestUrl.text = b['manifest'] as String;
          _sourceUrl.text = '${b['source'] ?? ''}';
          _homepage.text = '${b['homepage'] ?? ''}';
          _fetched = (manifest: manifestOfListing(l), sha: '${b['sha256']}', size: (b['size'] as int?) ?? 0, url: b['manifest'] as String);
        }
    }
  }

  @override
  void dispose() {
    for (final c in [_perHour, _manifestUrl, _sourceUrl, _homepage, _title, _about, _price, _tags, _location, _stock, _extra, _rate, _min, _max, _payout, _perView, _perClick, _dailyCap, _perUnit]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _heading => switch (widget.kind) {
    Kinds.item => _editing == null ? 'Sell something' : 'Edit item',
    Kinds.task => _editing == null ? 'Post a task' : 'Edit task',
    Kinds.ad => _editing == null ? 'Promote' : 'Edit campaign',
    Kinds.resource => 'Offer this phone',
    Kinds.exchange => _editing == null ? 'New exchange offer' : 'Edit offer',
    _ => _editing == null ? 'List a plugin' : 'Edit plugin listing',
  };

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final m = ref.watch(marketProvider);
    if (m == null) return const Scaffold(body: Loading());
    return Scaffold(
      appBar: AppBar(title: Text(_heading)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 120),
        children: [
          ...switch (widget.kind) {
            Kinds.item => _itemForm(p),
            Kinds.task => _taskForm(p),
            Kinds.ad => _adForm(p, m),
            Kinds.resource => _resourceForm(p, m),
            Kinds.exchange => _exchangeForm(p, m),
            _ => _pluginForm(p),
          },
          const SizedBox(height: Space.xl),
          Text(
            'Your listing is signed with your key and spreads to every phone on the Mentos network. '
            'Only you can change or withdraw it.',
            style: Txt.small(p.muted),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.md),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : _publish,
            child: Text(_busy ? 'Publishing…' : (_editing == null ? 'Publish' : 'Save changes')),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // shared fields

  Widget _field(TextEditingController c, String label, {String? hint, int lines = 1, int? max, TextInputType? keyboard, String? helper}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Space.md),
        child: TextField(
          controller: c,
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 4,
          maxLength: max,
          keyboardType: keyboard,
          inputFormatters: keyboard == TextInputType.number ? [FilteringTextInputFormatter.digitsOnly] : null,
          decoration: InputDecoration(labelText: label, hintText: hint, helperText: helper),
          onChanged: (_) => setState(() {}),
        ),
      );

  Widget _money(TextEditingController c, String label, {String? helper}) => _field(
    c,
    label,
    keyboard: const TextInputType.numberWithOptions(decimal: true),
    helper: helper,
  );

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
    child: Text(t.toUpperCase(), style: Txt.label(context.pal.muted)),
  );

  Widget _photos(Palette p, {int max = 8}) {
    final total = _media.length + _pending.length;
    return SizedBox(
      height: 92,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          if (total < max)
            GestureDetector(
              onTap: () async {
                final picked = await pickImages(context: context, limit: max - total);
                setState(() => _pending.addAll(picked));
              },
              child: Container(
                width: 92,
                margin: const EdgeInsets.only(right: Space.sm),
                decoration: BoxDecoration(
                  color: p.raised,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: p.line),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_a_photo_outlined, color: p.inkSoft),
                    const SizedBox(height: 4),
                    Text('$total/$max', style: Txt.mono(p.muted, size: 11)),
                  ],
                ),
              ),
            ),
          for (final ref0 in _media)
            _thumb(MarketImage(media: ref0, sources: [ref.read(engineProvider).me.id]), () => setState(() => _media.remove(ref0))),
          for (final x in _pending) _thumb(Image.file(x.file, fit: BoxFit.cover), () => setState(() => _pending.remove(x))),
        ],
      ),
    );
  }

  Widget _thumb(Widget child, VoidCallback remove) => Padding(
    padding: const EdgeInsets.only(right: Space.sm),
    child: Stack(
      children: [
        ClipRRect(borderRadius: BorderRadius.circular(16), child: SizedBox(width: 92, height: 92, child: child)),
        Positioned(
          right: 4,
          top: 4,
          child: GestureDetector(
            onTap: remove,
            child: Container(
              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _single(Map<String, String> options, String value, ValueChanged<String> onSelect) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final o in options.entries)
        ChoiceChip(label: Text(o.value), selected: value == o.key, showCheckmark: false, onSelected: (_) => onSelect(o.key)),
    ],
  );

  Widget _chips(Map<String, String> options, Set<String> selected, {bool single = false}) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final o in options.entries)
        FilterChip(
          label: Text(o.value),
          selected: selected.contains(o.key),
          showCheckmark: !single,
          onSelected: (v) => setState(() {
            if (single) selected.clear();
            v || single ? selected.add(o.key) : selected.remove(o.key);
          }),
        ),
    ],
  );

  Widget _arbiterPicker(Palette p) {
    final e = ref.read(engineProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'People both sides can trust to split a disputed payment. Buyers or workers choose one of them, or none.',
          style: Txt.small(p.muted),
        ),
        const SizedBox(height: Space.sm),
        for (final a in _arbiters)
          Row(
            children: [
              Expanded(child: TraderChip(a, dense: true)),
              IconBtn(Icons.close_rounded, size: 18, onTap: () => setState(() => _arbiters.remove(a))),
            ],
          ),
        if (_arbiters.length < 3)
          TextButton.icon(
            onPressed: () async {
              final people = e.db.peers().where((x) => !x.blocked && x.id != e.me.id && !_arbiters.contains(x.id)).toList();
              final pick = await showModalBottomSheet<String>(
                context: context,
                isScrollControlled: true,
                builder: (ctx) => SafeArea(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .6),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        const ListTile(title: Text('Choose an arbiter')),
                        if (people.isEmpty) const ListTile(title: Text('Connect with people first')),
                        for (final x in people) ListTile(title: TraderChip(x.id, dense: true), onTap: () => Navigator.pop(ctx, x.id)),
                      ],
                    ),
                  ),
                ),
              );
              if (pick != null) setState(() => _arbiters.add(pick));
            },
            icon: const Icon(Icons.gavel_rounded),
            label: const Text('Add arbiter'),
          ),
      ],
    );
  }

  List<String> _tagList() => _tags.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).take(8).toList();

  // ---------------------------------------------------------------------------
  // kinds

  List<Widget> _itemForm(Palette p) => [
    _label('Photos'),
    _photos(p),
    const SizedBox(height: Space.lg),
    _field(_title, 'Title', max: 100),
    _field(_about, 'Description', lines: 3, max: 4000),
    Row(
      children: [
        Expanded(child: _money(_price, 'Price (MNT)')),
        const SizedBox(width: Space.md),
        Expanded(child: _unlimited ? const SizedBox.shrink() : _field(_stock, 'In stock', keyboard: TextInputType.number)),
      ],
    ),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Unlimited stock'),
      value: _unlimited,
      onChanged: (v) => setState(() => _unlimited = v),
    ),
    _label('Category'),
    _single(shopCategories, _category, (k) => setState(() => _category = k)),
    _label('Condition'),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in conditions.entries)
          ChoiceChip(label: Text(c.value), selected: _condition == c.key, onSelected: (_) => setState(() {
            _condition = c.key;
            if (c.key == 'digital' && !_delivery.any((d) => d['kind'] == 'digital')) {
              _delivery
                ..clear()
                ..add({'id': 'download', 'label': 'Instant download', 'kind': 'digital', 'price': 0, 'days': 0});
            }
          })),
      ],
    ),
    if (_condition == 'digital') ...[
      _label('Files buyers get'),
      Text('Kept on this phone. Delivered automatically, end-to-end encrypted, once an order is paid.', style: Txt.small(p.muted)),
      const SizedBox(height: Space.sm),
      for (final f in _digital) ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.insert_drive_file_outlined), title: Text(f.name)),
      TextButton.icon(
        onPressed: () async {
          final picked = await pickFiles(ref.read(engineProvider).media, context: context);
          setState(() => _digital.addAll(picked));
        },
        icon: const Icon(Icons.attach_file_rounded),
        label: const Text('Attach files'),
      ),
    ],
    _label('Delivery'),
    for (final d in List.of(_delivery))
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('${d['label']}'),
        subtitle: Text('${deliveryKinds[d['kind']]} · ${(d['price'] as int) == 0 ? 'free' : Coin.format(d['price'] as int)}${(d['days'] as int) > 0 ? ' · ${d['days']} days' : ''}'),
        trailing: _delivery.length > 1 ? IconBtn(Icons.close_rounded, size: 18, onTap: () => setState(() => _delivery.remove(d))) : null,
      ),
    if (_delivery.length < 6)
      TextButton.icon(onPressed: _addDelivery, icon: const Icon(Icons.add_rounded), label: const Text('Add a delivery option')),
    _label('Options'),
    for (final o in List.of(_options))
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('${o['name']}'),
        subtitle: Text((o['values'] as List).join(', ')),
        trailing: IconBtn(Icons.close_rounded, size: 18, onTap: () => setState(() => _options.remove(o))),
      ),
    if (_options.length < 3)
      TextButton.icon(onPressed: _addOption, icon: const Icon(Icons.add_rounded), label: const Text('Add size, colour…')),
    _label('Buyer protection: $_holdDays days'),
    Slider(value: _holdDays.toDouble(), min: 1, max: 30, divisions: 29, onChanged: (v) => setState(() => _holdDays = v.round())),
    Text('After you accept, payment releases automatically this long after delivery unless the buyer disputes.', style: Txt.small(p.muted)),
    _label('Arbiters'),
    _arbiterPicker(p),
    _label('More'),
    _field(_location, 'Area (optional)', hint: 'Bole, Addis Ababa', max: 60),
    _field(_tags, 'Tags', hint: 'vintage, ceramics'),
  ];

  Future<void> _addDelivery() async {
    final label = TextEditingController();
    final price = TextEditingController(text: '0');
    final days = TextEditingController(text: '1');
    var kind = 'ship';
    final ok = await showInputSheet<bool>(context, (ctx) => StatefulBuilder(builder: (ctx, set) => InputSheet(
      title: 'Delivery option',
      action: 'Add',
      onAction: () => Navigator.pop(ctx, true),
      child: Column(
        children: [
          Wrap(spacing: 8, children: [
            for (final k in deliveryKinds.entries) ChoiceChip(label: Text(k.value), selected: kind == k.key, onSelected: (_) => set(() => kind = k.key)),
          ]),
          TextField(controller: label, decoration: const InputDecoration(labelText: 'Label', hintText: 'Courier within Addis')),
          TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Price (MNT)')),
          TextField(controller: days, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Days to arrive')),
        ],
      ),
    )));
    if (ok != true) return;
    setState(() => _delivery.add({
      'id': 'd${_delivery.length}${DateTime.now().millisecond}',
      'label': label.text.trim().isEmpty ? deliveryKinds[kind]! : label.text.trim(),
      'kind': kind,
      'price': price.text.trim() == '0' || price.text.trim().isEmpty ? 0 : (Coin.parse(price.text) ?? 0),
      'days': int.tryParse(days.text.trim())?.clamp(0, 90) ?? 0,
    }));
  }

  Future<void> _addOption() async {
    final name = TextEditingController();
    final values = TextEditingController();
    final ok = await showInputSheet<bool>(context, (ctx) => InputSheet(
      title: 'Option',
      action: 'Add',
      onAction: () => Navigator.pop(ctx, true),
      child: Column(children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', hintText: 'Size')),
        TextField(controller: values, decoration: const InputDecoration(labelText: 'Choices, comma separated', hintText: 'S, M, L')),
      ]),
    ));
    if (ok != true) return;
    final list = values.text.split(',').map((v) => v.trim()).where((v) => v.isNotEmpty).take(12).toList();
    if (name.text.trim().isEmpty || list.isEmpty) return;
    setState(() => _options.add({'name': name.text.trim(), 'values': list}));
  }

  List<Widget> _taskForm(Palette p) => [
    _field(_title, 'What needs doing?', max: 100),
    _field(_about, 'Brief', lines: 3, max: 4000, hint: 'Context, location, anything they need to know'),
    _money(_price, 'Reward (MNT)', helper: 'Goes into escrow when you pick someone'),
    _label('Category'),
    _single(taskCategories, _category, (k) => setState(() => _category = k)),
    _label('Deadline'),
    OutlinedButton.icon(
      onPressed: () async {
        final d = await showDatePicker(
          context: context,
          initialDate: _deadline,
          firstDate: DateTime.now(),
          lastDate: DateTime.now().add(const Duration(days: 300)),
        );
        if (d != null) setState(() => _deadline = DateTime(d.year, d.month, d.day, 23, 59));
      },
      icon: const Icon(Icons.event_outlined),
      label: Text(MaterialLocalizations.of(context).formatMediumDate(_deadline)),
    ),
    _label('Done means'),
    for (final c in List.of(_criteria))
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.check_circle_outline_rounded, color: p.accent),
        title: Text(c),
        trailing: IconBtn(Icons.close_rounded, size: 18, onTap: () => setState(() => _criteria.remove(c))),
      ),
    if (_criteria.length < 10)
      TextButton.icon(
        onPressed: () async {
          final t = await prompt(context, title: 'Acceptance criterion', hint: 'Three photos from different angles', action: 'Add', maxLength: 200);
          if (t != null && t.trim().isNotEmpty) setState(() => _criteria.add(t.trim()));
        },
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add a criterion'),
      ),
    _label('Evidence to submit'),
    _chips(evidenceKinds, _evidence),
    _label('Review window: $_reviewDays days'),
    Slider(value: _reviewDays.toDouble(), min: 1, max: 14, divisions: 13, onChanged: (v) => setState(() => _reviewDays = v.round())),
    Text('If you do not review a submission within this time after the deadline, the worker can claim the reward.', style: Txt.small(p.muted)),
    _label('Arbiters'),
    _arbiterPicker(p),
    _label('Reference photos (optional)'),
    _photos(p, max: 4),
    const SizedBox(height: Space.md),
    _field(_tags, 'Tags', hint: 'photography, bole'),
  ];

  List<Widget> _adForm(Palette p, Market m) {
    final budget = Coin.parse(_price.text) ?? 0;
    final perView = Coin.parse(_perView.text) ?? 1;
    final mine = m.mine().where((l) => !l.deleted && l.kind != Kinds.ad).toList();
    return [
      _field(_title, 'Headline', max: 80),
      _field(_extra, 'Text', lines: 2, max: 280),
      _label('Image'),
      _photos(p, max: 1),
      _label('When tapped'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in const {'none': 'Nothing', 'listing': 'One of my listings', 'profile': 'My profile', 'url': 'A link'}.entries)
          ChoiceChip(label: Text(t.value), selected: _targetType == t.key, onSelected: (_) => setState(() {
            _targetType = t.key;
            _targetValue = t.key == 'profile' ? m.me : '';
          })),
      ]),
      if (_targetType == 'listing')
        DropdownButtonFormField<String>(
          initialValue: mine.any((l) => l.id == _targetValue) ? _targetValue : null,
          items: [for (final l in mine) DropdownMenuItem(value: l.id, child: Text(l.title, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() => _targetValue = v ?? ''),
          decoration: const InputDecoration(labelText: 'Listing'),
        ),
      if (_targetType == 'url')
        TextField(
          controller: TextEditingController(text: _targetValue),
          onChanged: (v) => _targetValue = v.trim(),
          decoration: const InputDecoration(labelText: 'https://…'),
        ),
      _label('Budget'),
      _money(_price, 'Total budget (MNT)'),
      Row(children: [
        Expanded(child: _money(_perView, 'Per view')),
        const SizedBox(width: Space.md),
        Expanded(child: _money(_perClick, 'Per click')),
      ]),
      _field(_dailyCap, 'Most views per day', keyboard: TextInputType.number),
      _label('Split: $_share% to the viewer, ${100 - _share}% to the carrier'),
      Slider(value: _share.toDouble(), min: 0, max: 100, divisions: 20, onChanged: (v) => setState(() => _share = v.round())),
      Text('Carriers are the phones that pass your campaign on to viewers. Paying them keeps the ad moving.', style: Txt.small(p.muted)),
      _label('Runs for $_adDays days'),
      Slider(value: _adDays.toDouble(), min: 1, max: 60, divisions: 59, onChanged: (v) => setState(() => _adDays = v.round())),
      _field(_tags, 'Audience tags', hint: 'food, addis'),
      MCard(
        color: MarketColors(p).violetSoft,
        border: false,
        child: Text(
          budget == 0
              ? 'Set a budget to see the reach.'
              : 'Up to ${budget ~/ math.max(1, perView)} paid views. Payments come from your balance as views arrive; '
                  'the campaign pauses if your balance runs out.',
          style: Txt.small(p.inkSoft),
        ),
      ),
    ];
  }

  List<Widget> _resourceForm(Palette p, Market m) {
    final bench = m.lastBench;
    if (bench == null) {
      return [
        EmptyState(
          icon: Icons.speed_rounded,
          title: 'Measure this phone first',
          body: 'Offers include real numbers from a quick device check.',
          action: FilledButton(onPressed: () => context.push('/market/diagnostics'), child: const Text('Run diagnostics')),
        ),
      ];
    }
    final freeGb = bench['freeGb'] as int? ?? 10;
    final maxGb = math.max(1, (freeGb * .8).floor());
    _gb = _gb.clamp(1, maxGb);
    return [
      MCard(
        child: Text(
          'Score ${bench['score']} · ${bench['cores']} cores · $freeGb GB free · measured ${DateTime.fromMillisecondsSinceEpoch(bench['ts'] as int).toLocal().toString().substring(0, 16)}',
          style: Txt.small(p.inkSoft),
        ),
      ),
      const SizedBox(height: Space.md),
      _field(_title, 'Name', hint: 'My spare phone in Bole', max: 100),
      _field(_about, 'About (optional)', lines: 2, max: 1000, hint: 'Online most evenings, on Wi‑Fi'),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Rent out storage'), value: _offerStorage, onChanged: (v) => setState(() => _offerStorage = v)),
      if (_offerStorage) ...[
        Text('$_gb GB', style: Txt.heading(p.ink)),
        Slider(value: _gb.toDouble(), min: 1, max: maxGb.toDouble(), divisions: math.max(1, maxGb - 1), onChanged: (v) => setState(() => _gb = v.round())),
        _money(_price, 'Price per GB per day (MNT)'),
      ],
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Run compute jobs'), value: _offerCompute, onChanged: (v) => setState(() => _offerCompute = v)),
      if (_offerCompute) ...[
        _chips(jobTypes, _jobs),
        const SizedBox(height: Space.md),
        _money(_perUnit, 'Price per unit (MNT)', helper: 'A unit is 1 MB of input, or one difficulty step'),
        Text('Largest input: $_maxMb MB', style: Txt.bodyStrong(p.ink)),
        Slider(value: _maxMb.toDouble(), min: 1, max: 512, divisions: 63, onChanged: (v) => setState(() => _maxMb = v.round())),
        Text('Jobs run in an isolated worker from a fixed list. Nothing a renter sends runs as code.', style: Txt.small(p.muted)),
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Rent a sandbox'),
        subtitle: const Text('Renters get a private workspace with files and a script runner, paid by the hour'),
        value: _offerBox,
        onChanged: (v) => setState(() => _offerBox = v),
      ),
      if (_offerBox) ...[
        _money(_perHour, 'Price per hour (MNT)'),
        Text('Workspace size: ${_boxMb >= 1024 ? '${(_boxMb / 1024).toStringAsFixed(1)} GB' : '$_boxMb MB'}', style: Txt.bodyStrong(p.ink)),
        Slider(value: _boxMb.toDouble(), min: 16, max: 4096, divisions: 255, onChanged: (v) => setState(() => _boxMb = (v / 16).round() * 16)),
        Text('Longest session: $_boxHours h', style: Txt.bodyStrong(p.ink)),
        Slider(value: _boxHours.toDouble(), min: 1, max: 168, divisions: 167, onChanged: (v) => setState(() => _boxHours = v.round())),
        Text('Renters at once: $_boxSlots', style: Txt.bodyStrong(p.ink)),
        Slider(value: _boxSlots.toDouble(), min: 1, max: 8, divisions: 7, onChanged: (v) => setState(() => _boxSlots = v.round())),
        Text(
          'Scripts are MentosScript, the same sandbox plugins use: no network, no access outside the workspace, '
          'and a step limit on every run. You can see what runs and end a session any time; unused hours are refunded.',
          style: Txt.small(p.muted),
        ),
      ],
    ];
  }

  List<Widget> _exchangeForm(Palette p, Market m) {
    if (_payout.text.isEmpty) _payout.text = m.payoutDetails();
    final rate = ((double.tryParse(_rate.text.trim()) ?? 0) * 100).round();
    return [
      Segmented<String>(value: _side, options: const {'sell': 'I sell Mentos', 'buy': 'I buy Mentos'}, onChanged: (v) => setState(() => _side = v)),
      const SizedBox(height: Space.lg),
      _field(_rate, 'Price: birr per 1 Mentos', keyboard: const TextInputType.numberWithOptions(decimal: true)),
      Row(children: [
        Expanded(child: _money(_min, 'Min (MNT)')),
        const SizedBox(width: Space.md),
        Expanded(child: _money(_max, 'Max (MNT)')),
      ]),
      if (rate > 0 && Coin.parse(_max.text) != null)
        Text('Largest trade: ${Exchange.birr(Exchange.birrFor(Coin.parse(_max.text)!, rate))}', style: Txt.small(p.muted)),
      _label('Payment methods'),
      _chips({for (final x in birrMethods) x: x}, _methods),
      _label('Payment window'),
      Wrap(spacing: 8, children: [
        for (final w in const [15, 30, 60, 180]) ChoiceChip(label: Text('$w min'), selected: _window == w, onSelected: (_) => setState(() => _window = w)),
      ]),
      if (_side == 'sell') ...[
        _label('Where buyers pay you (private)'),
        _field(_payout, 'Account details', lines: 2, hint: 'Telebirr 09…, CBE account …',
            helper: 'Shared only with a buyer, after you lock their Mentos'),
      ],
      _label('Terms'),
      _field(_extra, 'Terms (optional)', lines: 2, max: 1000),
      _label('Arbiters'),
      _arbiterPicker(p),
    ];
  }

  Future<void> _check() async {
    final host = ref.read(pluginHostProvider);
    final u = Uri.tryParse(_manifestUrl.text.trim());
    if (host == null || u == null || u.scheme != 'https' || u.host.isEmpty) {
      setState(() => _fetchError = 'Paste the https:// address of your plugin.json');
      return;
    }
    setState(() {
      _checking = true;
      _fetchError = null;
    });
    try {
      final (m, src) = await host.fetchPackage(u);
      final sha = c.sha256.convert(utf8.encode(src)).toString();
      setState(() {
        _fetched = (manifest: m, sha: sha, size: utf8.encode(src).length, url: u.toString());
        if (_title.text.trim().isEmpty || _editing == null) _title.text = m.name;
        if (_about.text.trim().isEmpty) _about.text = m.description;
        if (_homepage.text.trim().isEmpty && m.homepage != null) _homepage.text = m.homepage!;
        if (_sourceUrl.text.trim().isEmpty) _sourceUrl.text = u.resolve(m.main).toString();
      });
    } catch (e) {
      setState(() {
        _fetched = null;
        _fetchError = '$e';
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  List<Widget> _pluginForm(Palette p) {
    final f = _fetched;
    final stale = f != null && f.url != _manifestUrl.text.trim();
    return [
      Text(
        'Host your plugin anywhere over https (a GitHub repo works: use its raw plugin.json link). '
        'Mentos fetches it, checks it runs, and pins the script\'s checksum to your listing, so buyers get exactly what you checked.',
        style: Txt.small(p.muted),
      ),
      const SizedBox(height: Space.md),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _manifestUrl,
              keyboardType: TextInputType.url,
              style: Txt.mono(p.ink, size: 13),
              decoration: InputDecoration(
                labelText: 'plugin.json link',
                hintText: 'https://raw.githubusercontent.com/you/repo/main/plugin.json',
                errorText: _fetchError,
                errorMaxLines: 3,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _check(),
            ),
          ),
          const SizedBox(width: Space.sm),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: FilledButton.tonal(
              onPressed: _checking ? null : _check,
              child: _checking ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Check'),
            ),
          ),
        ],
      ),
      const SizedBox(height: Space.md),
      if (f != null)
        Container(
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: stale ? p.danger : p.accent.withValues(alpha: .5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  PluginIcon(f.manifest, size: 48),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(f.manifest.name, style: Txt.bodyStrong(p.ink)),
                        Text('${f.manifest.id} · v${f.manifest.version} · ${(f.size / 1024).toStringAsFixed(1)} KB', style: Txt.mono(p.muted, size: 11)),
                      ],
                    ),
                  ),
                  Icon(stale ? Icons.error_outline_rounded : Icons.verified_rounded, color: stale ? p.danger : p.accent),
                ],
              ),
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final perm in f.manifest.permissions)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.pill)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(pluginPermissions[perm]!.$1, size: 13, color: p.inkSoft),
                          const SizedBox(width: 4),
                          Text(perm, style: Txt.mono(p.inkSoft, size: 10.5)),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Space.sm),
              Text(
                stale ? 'The link changed. Check it again before publishing.' : 'Checksum ${f.sha.substring(0, 16)}… will be pinned.',
                style: Txt.small(stale ? p.danger : p.muted),
              ),
            ],
          ),
        ),
      const SizedBox(height: Space.lg),
      _field(_title, 'Name', max: 100),
      _field(_about, 'What it does', lines: 3, max: 1000),
      _field(_tags, 'Tags (comma separated)', hint: 'chat, theme, productivity'),
      _field(_sourceUrl, 'Source code link (optional)', keyboard: TextInputType.url),
      _field(_homepage, 'Website (optional)', keyboard: TextInputType.url),
      _money(_price, 'Price in Mentos (0 for free)', helper: 'Buyers pay you once, then install'),
    ];
  }

  // ---------------------------------------------------------------------------

  Future<void> _publish() async {
    final m = ref.read(marketProvider)!;
    final e = ref.read(engineProvider);
    setState(() => _busy = true);
    final ok = await attempt(context, () async {
      final media = [..._media];
      for (final x in _pending) {
        media.add(await importPending(e, x, scope: 'market'));
      }
      final body = _body(m, media);
      final l = widget.kind == Kinds.ad && _editing == null
          ? await m.launchAd(body)
          : await m.publish(widget.kind, body, id: _editing?.id);
      if (widget.kind == Kinds.item && _digital.isNotEmpty) {
        m.setDigitalFiles(l.id, [for (final x in _digital) await importPending(e, x, scope: 'market-digital')]);
      }
      if (widget.kind == Kinds.exchange && _side == 'sell') m.setPayoutDetails(_payout.text);
      if (mounted) {
        context.pop();
        if (_editing == null) context.push('/market/l/${Uri.encodeComponent(l.id)}');
      }
    }, done: _editing == null ? 'Published to the network' : 'Saved');
    if (!ok && mounted) setState(() => _busy = false);
  }

  Map<String, dynamic> _body(Market m, List<MediaRef> media) {
    int money(TextEditingController c, String what) {
      final v = Coin.parse(c.text);
      if (v == null) throw ArgumentError('Enter a valid $what');
      return v;
    }

    final common = <String, dynamic>{
      'title': _title.text.trim(),
      if (_about.text.trim().isNotEmpty) 'about': _about.text.trim(),
      if (_tagList().isNotEmpty) 'tags': _tagList(),
      if (media.isNotEmpty) 'media': [for (final x in media) x.toJson()],
      if (_location.text.trim().isNotEmpty) 'location': _location.text.trim(),
      if (_arbiters.isNotEmpty) 'arbiters': _arbiters.toList(),
    };
    if (_title.text.trim().isEmpty) throw ArgumentError('Give it a title');
    switch (widget.kind) {
      case Kinds.item:
        if (_delivery.isEmpty) throw ArgumentError('Add at least one delivery option');
        return {
          ...common,
          'price': money(_price, 'price'),
          'stock': _unlimited ? -1 : (int.tryParse(_stock.text.trim()) ?? 1),
          'category': _category.isEmpty ? 'other' : _category,
          'condition': _condition,
          'holdDays': _holdDays,
          'delivery': _delivery,
          if (_options.isNotEmpty) 'options': _options,
          'status': 'active',
        };
      case Kinds.task:
        if (_criteria.isEmpty) throw ArgumentError('Add at least one acceptance criterion');
        return {
          ...common,
          'reward': money(_price, 'reward'),
          'deadline': _deadline.millisecondsSinceEpoch,
          'category': _category,
          'criteria': _criteria,
          'evidence': _evidence.toList(),
          'reviewDays': _reviewDays,
          'status': _editing?.status ?? 'open',
          if (_editing?.body['assignee'] != null) 'assignee': _editing!.body['assignee'],
          if (_editing?.body['applicants'] != null) 'applicants': _editing!.body['applicants'],
        };
      case Kinds.ad:
        return {
          ...common,
          'text': _extra.text.trim(),
          'budget': money(_price, 'budget'),
          'perView': money(_perView, 'price per view'),
          'perClick': _perClick.text.trim().isEmpty || _perClick.text.trim() == '0' ? 0 : money(_perClick, 'price per click'),
          'viewerShare': _share,
          'dailyCap': int.tryParse(_dailyCap.text.trim()) ?? 500,
          'until': DateTime.now().add(Duration(days: _adDays)).millisecondsSinceEpoch,
          'target': {'type': _targetType, if (_targetType != 'none') 'value': _targetValue},
          'status': _editing?.status ?? 'active',
        };
      case Kinds.resource:
        if (!_offerStorage && !_offerCompute && !_offerBox) throw ArgumentError('Offer storage, compute or a sandbox');
        return {
          ...common,
          if (_offerStorage) 'storage': {'gb': _gb, 'perGbDay': money(_price, 'storage price')},
          if (_offerCompute) 'compute': {'jobs': _jobs.toList(), 'perUnit': money(_perUnit, 'compute price'), 'maxMb': _maxMb},
          if (_offerBox) 'sandbox': {'perHour': money(_perHour, 'hourly price'), 'mb': _boxMb, 'maxHours': _boxHours, 'slots': _boxSlots, 'steps': 2000000},
          'bench': m.lastBench ?? const {},
          'status': 'active',
        };
      case Kinds.exchange:
        final rate = ((double.tryParse(_rate.text.trim()) ?? 0) * 100).round();
        if (rate <= 0) throw ArgumentError('Enter a price in birr');
        if (_methods.isEmpty) throw ArgumentError('Pick at least one payment method');
        return {
          ...common,
          'side': _side,
          'rate': rate,
          'min': money(_min, 'minimum'),
          'max': money(_max, 'maximum'),
          'methods': _methods.toList(),
          'windowMins': _window,
          if (_extra.text.trim().isNotEmpty) 'terms': _extra.text.trim(),
          'status': 'active',
        };
      default:
        final f = _fetched;
        if (f == null) throw ArgumentError('Check your plugin link first');
        if (f.url != _manifestUrl.text.trim()) throw ArgumentError('The link changed. Tap Check again.');
        String? link(TextEditingController c, String what) {
          final t = c.text.trim();
          if (t.isEmpty) return null;
          final u = Uri.tryParse(t);
          if (u == null || u.scheme != 'https' || u.host.isEmpty) throw ArgumentError('$what must be an https:// link');
          return t;
        }

        return {
          ...common,
          'price': _price.text.trim().isEmpty || _price.text.trim() == '0' ? 0 : money(_price, 'price'),
          'manifest': f.url,
          'pluginId': f.manifest.id,
          'version': f.manifest.version,
          'sha256': f.sha,
          'size': f.size,
          'permissions': f.manifest.permissions,
          'icon': f.manifest.icon,
          'source': ?link(_sourceUrl, 'Source'),
          'homepage': ?link(_homepage, 'Website'),
          'status': 'active',
        };
    }
  }
}
