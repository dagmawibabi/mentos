import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';

import '../common/attach.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/engine.dart';
import '../../net/pay/coin.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

/// A stall on the peer network. Listings travel to people you can reach.
/// Mentos move on the ledger. Birr is the price two people agreed, not a
/// transfer this app sends.
class MarketScreen extends ConsumerStatefulWidget {
  const MarketScreen({super.key});

  @override
  ConsumerState<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends ConsumerState<MarketScreen> {
  final _search = TextEditingController();
  String _filter = 'all';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const Scaffold(body: SizedBox.shrink());
    ref.watch(coinTickProvider);
    ref.watch(feedProvider);
    final q = _search.text.trim().toLowerCase();
    final rows = [
      for (final row in [...e.marketBoard(), ...starterPlugins])
        if (_matches(row, _filter, q, e)) row,
    ];
    final installed = e.installedPlugins();
    final showDepartments = q.isEmpty && _filter == 'all';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Marketplace'),
        actions: [
          IconBtn(
            Icons.add_rounded,
            tooltip: 'Sell',
            onTap: () => _sell(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.all(Space.gutter),
            child: Container(
              padding: const EdgeInsets.all(Space.lg),
              decoration: BoxDecoration(
                color: p.accentSoft,
                borderRadius: BorderRadius.circular(Radii.lg),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Made here. Traded here.', style: Txt.display(p.ink)),
                  const SizedBox(height: 10),
                  Text(
                    'Put your skills to work, share something useful, and earn Mentos together.',
                    style: Txt.body(p.inkSoft),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _sell(context),
                        icon: const Icon(Icons.add),
                        label: const Text('Create listing'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => context.push('/wallet'),
                        icon: const Icon(Icons.account_balance_wallet_outlined),
                        label: const Text('Your wallet'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.sm,
              Space.gutter,
              0,
            ),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search listings, people, plugins',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: p.raised,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: Space.md),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              children: [
                for (final chip in const [
                  ('all', 'All'),
                  ('task', 'Tasks'),
                  ('plugin', 'Plugins'),
                  ('exchange', 'Mentos'),
                  ('ad', 'Ads'),
                  ('resource', 'Phones'),
                  ('task', 'Tasks'),
                  ('mine', 'My work'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(chip.$2),
                      selected: _filter == chip.$1,
                      onSelected: (_) => setState(() => _filter = chip.$1),
                    ),
                  ),
              ],
            ),
          ),
          if (showDepartments) ...[
            const SectionLabel('Browse'),
            SizedBox(
              height: 112,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                children: [
                  _Dept(
                    'Mentos',
                    'Offers priced in birr',
                    Icons.currency_exchange_rounded,
                    () => setState(() => _filter = 'exchange'),
                  ),
                  _Dept(
                    'Plugins',
                    'Stickers, accents, phrases',
                    Icons.extension_outlined,
                    () => setState(() => _filter = 'plugin'),
                  ),
                  _Dept(
                    'Check',
                    'See the paid mark',
                    Icons.verified_outlined,
                    () => _openCheck(context),
                  ),
                  _Dept(
                    'Ads',
                    'A post with a budget',
                    Icons.campaign_outlined,
                    () => setState(() => _filter = 'ad'),
                  ),
                  _Dept(
                    'Phones',
                    'Storage and compute',
                    Icons.storage_rounded,
                    () => setState(() => _filter = 'resource'),
                  ),
                  _Dept(
                    'Tasks',
                    'Paid when accepted',
                    Icons.task_alt_rounded,
                    () => setState(() => _filter = 'task'),
                  ),
                ],
              ),
            ),
          ],
          if (installed.isNotEmpty &&
              (_filter == 'all' || _filter == 'plugin')) ...[
            const SectionLabel('On this phone'),
            for (final pack in installed)
              RowTile(
                icon: Icons.extension_rounded,
                title: pack['title'] as String? ?? 'Plugin',
                subtitle: _pluginBlurb(pack),
                onTap: () => _openInstalled(context, pack),
              ),
          ],
          SectionLabel(
            rows.isEmpty
                ? 'Listings'
                : '${rows.length} ${rows.length == 1 ? 'listing' : 'listings'}',
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Text(
                q.isEmpty
                    ? 'Be the first to list here. Offer a resource, publish a pack, or find someone for your next task.'
                    : 'No listing matches that search.',
                style: Txt.small(p.muted),
              ),
            )
          else
            for (final row in rows)
              _Card(row: row, onTap: () => _openListing(context, row)),
        ],
      ),
    );
  }

  bool _matches(Map<String, dynamic> row, String filter, String q, Engine e) {
    if (row['deleted'] == true) return false;
    final kind = row['kind'] as String? ?? '';
    final ok = switch (filter) {
      'exchange' => kind == 'sell-mentos' || kind == 'buy-mentos',
      'plugin' => kind == 'plugin',
      'ad' => kind == 'ad',
      'resource' => kind == 'resource',
      'task' => kind == 'task',
      'mine' =>
        row['from'] == e.me.id ||
            row['worker'] == e.me.id ||
            (row['applications'] is List &&
                (row['applications'] as List).contains(e.me.id)),
      _ => true,
    };
    if (!ok) return false;
    if (q.isEmpty) return true;
    final from = row['from'] as String? ?? '';
    final blob =
        '${row['title']} ${row['about']} ${row['plugin']} ${_kindLabel(kind)} ${e.nameOf(from)}'
            .toLowerCase();
    return blob.contains(q);
  }

  Future<void> _sell(BuildContext context) async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: Space.sm),
            for (final item in const [
              (
                'sell-mentos',
                Icons.north_east_rounded,
                'Offer Mentos for birr',
              ),
              ('buy-mentos', Icons.south_west_rounded, 'Offer birr for Mentos'),
              ('plugin', Icons.extension_outlined, 'Sell a plugin'),
              ('check', Icons.verified_outlined, 'Paid checkmark'),
              ('ad', Icons.campaign_outlined, 'Run an ad'),
              ('resource', Icons.storage_rounded, 'Offer this phone'),
              ('task', Icons.task_alt_rounded, 'Post a task'),
            ])
              ListTile(
                leading: Icon(item.$2),
                title: Text(item.$3),
                onTap: () => Navigator.pop(ctx, item.$1),
              ),
          ],
        ),
      ),
    );
    if (kind == null || !context.mounted) return;
    if (kind == 'check') {
      await _openCheck(context);
      return;
    }
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => _SellPage(kind: kind)));
  }

  Future<void> _openCheck(BuildContext context) {
    return Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const _CheckPage()));
  }

  void _openListing(BuildContext context, Map<String, dynamic> row) {
    if (row['kind'] == 'task') {
      context.push('/market/task/${Uri.encodeComponent(row['id'] as String)}');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .86,
        minChildSize: .45,
        maxChildSize: .95,
        builder: (_, scroll) => _ListingSheet(row: row, scroll: scroll),
      ),
    );
  }

  void _openInstalled(BuildContext context, Map<String, dynamic> pack) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _InstalledSheet(pack: pack),
    );
  }
}

class _Dept extends StatelessWidget {
  const _Dept(this.title, this.subtitle, this.icon, this.onTap);
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: p.line),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.md),
          child: SizedBox(
            width: 148,
            child: Padding(
              padding: const EdgeInsets.all(Space.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 20, color: p.ink),
                  const Spacer(),
                  Text(title, style: Txt.heading(p.ink)),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.mono(p.muted, size: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends ConsumerWidget {
  const _Card({required this.row, required this.onTap});
  final Map<String, dynamic> row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final kind = row['kind'] as String? ?? '';
    final title = row['title'] as String? ?? _kindLabel(kind);
    final from = row['from'] as String? ?? '';
    final minor = (row['minor'] as num?)?.toInt() ?? 0;
    final birr = row['birr'] as String? ?? '';
    final about = row['about'] as String? ?? '';
    final cover = MediaRef.listFrom(row['media']).where((m) => m.isImage).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 10),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: p.line),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.md),
          child: Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (cover != null) _ListingCover(media: cover, from: from),
                Row(
                  children: [
                    Icon(
                      kind == 'task'
                          ? Icons.task_alt
                          : kind == 'plugin'
                          ? Icons.extension_outlined
                          : kind == 'resource'
                          ? Icons.storage_outlined
                          : Icons.storefront_outlined,
                      size: 20,
                      color: p.accent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _kindLabel(kind).toUpperCase(),
                      style: Txt.mono(p.faint, size: 10.5, w: FontWeight.w500),
                    ),
                    const Spacer(),
                    Text(
                      _priceLabel(kind, minor, birr),
                      style: Txt.mono(p.ink, size: 13, w: FontWeight.w500),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(title, style: Txt.heading(p.ink)),
                if (about.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    about,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.small(p.muted),
                  ),
                ],
                const SizedBox(height: 8),
                if (kind == 'task')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '${row['status'] ?? 'open'} · ${(row['applications'] as List? ?? []).length} applicants',
                      style: Txt.mono(p.accent),
                    ),
                  ),
                _PluginPreview(row: row),
                Row(
                  children: [
                    Avatar(id: from, size: 18, presence: false),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        from.isEmpty ? 'Mentos essentials' : e.nameOf(from),
                        style: Txt.small(p.inkSoft),
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, size: 18, color: p.faint),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PluginPreview extends StatelessWidget {
  const _PluginPreview({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    if (row['kind'] != 'plugin') return const SizedBox.shrink();
    final p = context.pal;
    final plugin = row['plugin'] as String? ?? '';
    final body = row['body'];
    if (plugin == 'stickers' && body is Map && body['emoji'] is List) {
      final emoji = [
        for (final x in body['emoji'] as List)
          if (x is String) x,
      ];
      if (emoji.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          emoji.take(8).join('  '),
          style: const TextStyle(fontSize: 22),
        ),
      );
    }
    if (plugin == 'theme' && body is Map) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'Accent · ${body['accent'] ?? 'emerald'}',
          style: Txt.mono(p.accent, size: 12),
        ),
      );
    }
    if (plugin == 'phrases' && body is Map && body['lines'] is List) {
      final first = (body['lines'] as List).whereType<String>().firstOrNull;
      if (first == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          '“$first”',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Txt.small(p.inkSoft),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _ListingSheet extends ConsumerWidget {
  const _ListingSheet({required this.row, required this.scroll});
  final Map<String, dynamic> row;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(engineProvider);
    ref.watch(coinTickProvider);
    ref.watch(feedProvider);
    final kind = row['kind'] as String? ?? '';
    final id = row['id']?.toString() ?? '';
    final title = row['title'] as String? ?? _kindLabel(kind);
    final about = row['about'] as String? ?? '';
    final from = row['from'] as String? ?? '';
    final minor = (row['minor'] as num?)?.toInt() ?? 0;
    final birr = (row['birr'] as String? ?? '').trim();
    final mine = from == e.me.id;
    final owned = id.isNotEmpty && (minor == 0 || mine || e.listingOwned(id));
    final installed = kind == 'plugin' && e.pluginInstalled(id);
    final claims = kind == 'ad' ? e.adClaims(id) : const <String>[];

    return Material(
      color: p.bg,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.lg)),
      child: ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          Space.md,
          Space.gutter,
          Space.xl,
        ),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: p.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: Space.lg),
          Text(
            _kindLabel(kind).toUpperCase(),
            style: Txt.mono(p.faint, size: 11, w: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(title, style: Txt.title(p.ink)),
          const SizedBox(height: Space.sm),
          Text(
            _priceLabel(kind, minor, birr),
            style: Txt.display(p.ink).copyWith(fontSize: 32, height: 1.1),
          ),
          if (about.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            Text(about, style: Txt.body(p.inkSoft)),
          ],
          const SizedBox(height: Space.lg),
          _PluginPreview(row: row),
          if (kind == 'ad') _AdPreview(title: title, about: about, from: from),
          for (final media in MediaRef.listFrom(row['media']))
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: Text(media.name),
              onTap: () async {
                try {
                  final file = await e.media.open(media, sources: [from]);
                  if (file == null) {
                    throw StateError(
                      'File unavailable; the seller may be offline',
                    );
                  }
                  await OpenFilex.open(file.path);
                } catch (err) {
                  if (context.mounted) toast(context, '$err');
                }
              },
            ),
          if (mine && kind != 'ad')
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _SellPage(kind: kind, initial: row),
                  ),
                );
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit listing'),
            ),
          const SectionLabel('Record'),
          _Fact(
            'seller',
            from.isEmpty ? '—' : e.nameOf(from),
            onTap: from.isEmpty ? null : () => context.push('/u/$from'),
          ),
          _Fact('address', from.isEmpty ? '—' : from, copy: from),
          _Fact('listing', id.isEmpty ? '—' : id, copy: id),
          _Fact(
            'price',
            minor > 0 ? '${Coin.format(minor)} Mentos' : '—',
            copy: '',
          ),
          if (birr.isNotEmpty)
            _Fact('birr', '$birr birr, agreed between you', copy: ''),
          _Fact(
            'you',
            mine
                ? 'you listed this'
                : minor == 0
                ? 'free to install'
                : owned
                ? 'you already paid'
                : 'not paid from this phone',
            copy: '',
          ),
          if (kind == 'plugin')
            _Fact(
              'runs as',
              _pluginKind(row['plugin'] as String? ?? ''),
              copy: '',
            ),
          if (kind == 'plugin')
            _Fact(
              'on this phone',
              installed ? 'installed' : 'not installed',
              copy: '',
            ),
          if (kind == 'ad') ...[
            _Fact('budget', Coin.format(minor), copy: ''),
            _Fact(
              'kept by',
              claims.isEmpty ? 'no phone yet' : '${claims.length}',
              copy: '',
            ),
            _Fact('each phone', '0.05 Mentos when you settle', copy: ''),
            for (final peer in claims)
              _Fact('claim', e.nameOf(peer), copy: peer),
          ],
          const SizedBox(height: Space.md),
          Text(_finePrint(kind), style: Txt.small(p.muted)),
          const SizedBox(height: Space.lg),
          if (mine && kind == 'ad')
            FilledButton(
              onPressed: () => _settle(context, ref),
              child: const Text('Settle claims'),
            )
          else if (mine && kind == 'task')
            FilledButton(
              onPressed: () => _payTask(context, ref),
              child: Text('Pay ${Coin.format(minor)} for the result'),
            )
          else if (kind == 'plugin' && (installed || owned || mine))
            FilledButton(
              onPressed: installed ? null : () => _install(context, ref),
              child: Text(installed ? 'Installed' : 'Install on this phone'),
            )
          else if (!mine && kind != 'ad')
            FilledButton(
              onPressed: () => _take(context, ref),
              child: Text(_takeLabel(kind, minor)),
            ),
          if (kind == 'plugin' && installed)
            TextButton(
              onPressed: () => _removeInstall(context, ref),
              child: const Text('Remove from this phone'),
            ),
          if (mine)
            TextButton(
              onPressed: () async {
                e.removeMarket(id);
                if (context.mounted) Navigator.pop(context);
              },
              child: Text('Remove listing', style: TextStyle(color: p.danger)),
            ),
        ],
      ),
    );
  }

  Future<void> _install(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(engineProvider).installPlugin(row);
      if (context.mounted) {
        toast(context, 'Installed');
        Navigator.pop(context);
      }
    } catch (err) {
      if (context.mounted) toast(context, '$err');
    }
  }

  void _removeInstall(BuildContext context, WidgetRef ref) {
    final id = row['id']?.toString() ?? '';
    ref.read(engineProvider).removePlugin(id);
    toast(context, 'Removed');
    Navigator.pop(context);
  }

  Future<void> _take(BuildContext context, WidgetRef ref) async {
    final e = ref.read(engineProvider);
    final coin = ref.read(coinProvider);
    final from = row['from'] as String? ?? '';
    final minor = (row['minor'] as num?)?.toInt() ?? 0;
    final kind = row['kind'] as String? ?? '';
    final title = row['title'] as String? ?? 'listing';
    final birr = row['birr'] as String? ?? '';
    final id = row['id']?.toString() ?? '';
    if (from.isEmpty) return;
    if (kind == 'buy-mentos' || kind == 'sell-mentos') {
      final text = kind == 'sell-mentos'
          ? 'I want your offer of ${Coin.format(minor)} Mentos for $birr birr.'
          : 'I can sell you ${Coin.format(minor)} Mentos for $birr birr. Send the birr, then I will send the Mentos.';
      await e.sendMessage(Scope.dm(e.me.id, from), text: text);
      if (context.mounted) {
        toast(
          context,
          'Sent in chat. Birr stays between you. Mentos move when one of you sends them.',
        );
        Navigator.pop(context);
      }
      return;
    }
    if (kind == 'task') {
      await e.sendMessage(
        Scope.dm(e.me.id, from),
        text:
            'I can take “$title”. Pay me from the listing when you accept the result.',
      );
      if (context.mounted) {
        toast(context, 'Sent in chat. They pay when they accept the result.');
        Navigator.pop(context);
      }
      return;
    }
    if (coin == null || minor <= 0) return;
    final ok = await confirm(
      context,
      title: 'Pay ${Coin.format(minor)} Mentos?',
      body: kind == 'plugin'
          ? 'This pays ${e.nameOf(from)} and installs “$title” on this phone.'
          : 'This pays ${e.nameOf(from)} for “$title”, plus a 5% network fee. The work itself is between you.',
      action: 'Pay',
    );
    if (!ok || !context.mounted) return;
    try {
      await coin.payOnce(
        from,
        minor,
        memo:
            '${kind == 'plugin' ? 'plugin' : 'resource'}:${id.length <= 100 ? id : id.substring(id.length - 100)}',
      );
      e.noteOwned(id);
      if (kind == 'plugin') await e.installPlugin(row);
      if (context.mounted) {
        toast(
          context,
          kind == 'plugin'
              ? 'Paid and installed'
              : 'Sent ${Coin.format(minor)} Mentos',
        );
        Navigator.pop(context);
      }
    } catch (err) {
      if (context.mounted) toast(context, '$err');
    }
  }

  Future<void> _payTask(BuildContext context, WidgetRef ref) async {
    final e = ref.read(engineProvider);
    final coin = ref.read(coinProvider);
    final minor = (row['minor'] as num?)?.toInt() ?? 0;
    if (coin == null || minor <= 0) return;
    final people = e
        .people()
        .where((x) => !x.blocked && x.id != e.me.id)
        .toList();
    if (people.isEmpty || !context.mounted) {
      toast(context, 'Add the person who did the task first.');
      return;
    }
    final to = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(Space.gutter),
              child: Text('Who did the task?'),
            ),
            for (final person in people)
              ListTile(
                title: Text(e.nameOf(person.id)),
                onTap: () => Navigator.pop(ctx, person.id),
              ),
          ],
        ),
      ),
    );
    if (to == null || !context.mounted) return;
    try {
      await coin.pay(to, minor, memo: 'task');
      if (context.mounted) toast(context, 'Paid ${Coin.format(minor)} Mentos');
    } catch (err) {
      if (context.mounted) toast(context, '$err');
    }
  }

  Future<void> _settle(BuildContext context, WidgetRef ref) async {
    final e = ref.read(engineProvider);
    final coin = ref.read(coinProvider);
    if (coin == null) return;
    final id = row['id']?.toString() ?? '';
    final claims = e.adClaims(id);
    if (claims.isEmpty) {
      toast(context, 'No phone has kept this ad yet.');
      return;
    }
    final each = Coin.parse('0.05')!;
    final prefix = 'ad:${id.length > 64 ? id.substring(id.length - 64) : id}:';
    final paid = coin.history().where((t) => t.from == e.me.id && t.memo.startsWith(prefix)).toList();
    var remaining = (row['minor'] as num? ?? 0).toInt() - paid.fold<int>(0, (sum, tx) => sum + tx.amount);
    var n = 0;
    for (final peer in claims) {
      if (paid.any((t) => t.to == peer)) continue;
      if (coin.balance() < each || remaining < each) break;
      try {
        await coin.payOnce(peer, each, memo: '$prefix$peer');
        remaining -= each;
        n++;
      } catch (_) {}
    }
    if (context.mounted) {
      toast(
        context,
        n == 0 ? 'Nothing paid' : 'Paid $n ${n == 1 ? 'phone' : 'phones'}',
      );
    }
  }
}

class _AdPreview extends ConsumerWidget {
  const _AdPreview({
    required this.title,
    required this.about,
    required this.from,
  });
  final String title;
  final String about;
  final String from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    return Container(
      margin: const EdgeInsets.only(bottom: Space.md),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Avatar(id: from, size: 28, presence: false),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  from.isEmpty ? 'Someone' : e.nameOf(from),
                  style: Txt.heading(p.ink),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: p.dangerSoft,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Text(
                  'AD',
                  style: Txt.mono(p.danger, size: 10, w: FontWeight.w500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(title, style: Txt.bodyStrong(p.ink)),
          if (about.isNotEmpty) Text(about, style: Txt.small(p.inkSoft)),
          const SizedBox(height: 6),
          Text(
            'This is how the post reads in the feed.',
            style: Txt.mono(p.faint, size: 11),
          ),
        ],
      ),
    );
  }
}

class _InstalledSheet extends ConsumerWidget {
  const _InstalledSheet({required this.pack});
  final Map<String, dynamic> pack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final id = pack['id']?.toString() ?? '';
    final title = pack['title'] as String? ?? 'Plugin';
    final plugin = pack['plugin'] as String? ?? '';
    final body = pack['body'];
    final accent = body is Map ? body['accent'] as String? : null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          Space.md,
          Space.gutter,
          Space.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Txt.title(p.ink)),
            const SizedBox(height: 4),
            Text(_pluginKind(plugin), style: Txt.mono(p.muted, size: 11)),
            const SizedBox(height: Space.md),
            _PluginPreview(
              row: {'kind': 'plugin', 'plugin': plugin, 'body': body},
            ),
            Text(_pluginBlurb(pack), style: Txt.small(p.inkSoft)),
            const SizedBox(height: Space.lg),
            if (plugin == 'theme' && accent != null)
              FilledButton(
                onPressed: () {
                  ref
                      .read(settingsProvider.notifier)
                      .update((s) => s.copyWith(accent: accent));
                  toast(context, 'Accent is $accent');
                  Navigator.pop(context);
                },
                child: Text('Use $accent'),
              ),
            TextButton(
              onPressed: () {
                e.removePlugin(id);
                toast(context, 'Removed');
                Navigator.pop(context);
              },
              child: Text(
                'Remove from this phone',
                style: TextStyle(color: p.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckPage extends ConsumerWidget {
  const _CheckPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(engineProvider);
    ref.watch(coinTickProvider);
    ref.watch(feedProvider);
    final coin = ref.watch(coinProvider);
    final me = e.myProfile;
    final paid = coin?.hasBadge(e.me.id) ?? false;
    final treasury = coin?.balance(Coin.treasury);
    final price = treasury == null ? null : Coin.badgePrice(treasury);
    final priceText = price == null ? '…' : '${Coin.format(price)} Mentos';
    return Scaffold(
      appBar: AppBar(title: const Text('Paid check')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          Space.md,
          Space.gutter,
          Space.xxl,
        ),
        children: [
          Text('This is the mark on your name.', style: Txt.small(p.muted)),
          const SizedBox(height: Space.md),
          Container(
            padding: const EdgeInsets.all(Space.lg),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: p.line),
            ),
            child: Row(
              children: [
                Avatar(id: e.me.id, size: 48, presence: false),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              me.displayName,
                              style: Txt.heading(p.ink),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.verified_rounded,
                            size: 18,
                            color: p.accent,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        paid
                            ? 'On your posts now'
                            : 'After you pay $priceText',
                        style: Txt.mono(p.muted, size: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.lg),
          Text(
            'The check means you contributed $priceText to the network treasury. The price is 10.00 while the treasury is full, then 0.01 higher for every 5.00 drawn out, and lower again as checkmarks and service fees refill it. It is not a review of who you are, and this app does not confirm a legal name.',
            style: Txt.body(p.inkSoft),
          ),
          const SizedBox(height: Space.lg),
          _Fact('price', priceText, copy: ''),
          _Fact('shows on', 'your name beside posts', copy: ''),
          _Fact('paid to', 'Network treasury', copy: ''),
          _Fact(
            'status',
            paid ? 'paid' : 'not paid from this identity',
            copy: '',
          ),
          const SizedBox(height: Space.lg),
          FilledButton(
            onPressed: paid || price == null || !Coin.treasuryConfigured
                ? null
                : () => _pay(context, ref),
            child: Text(
              paid
                  ? 'Already on your profile'
                  : !Coin.treasuryConfigured
                  ? 'Treasury setup pending'
                  : 'Pay $priceText',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pay(BuildContext context, WidgetRef ref) async {
    final coin = ref.read(coinProvider);
    if (coin == null) return;
    if (!Coin.treasuryConfigured) {
      toast(context, 'The network treasury has not been configured yet.');
      return;
    }
    final to = Coin.treasury;
    final me = ref.read(engineProvider).me.id;
    if (coin.hasBadge(me)) return;
    final due = Coin.badgePrice(coin.balance(Coin.treasury));
    final label = Coin.format(due);
    if (!await confirm(
          context,
          title: 'Buy a checkmark?',
          body:
              'Pay $label Mentos to the network treasury. The price follows the treasury balance. This is a paid mark, not identity verification.',
          action: 'Pay',
        ) ||
        !context.mounted) {
      return;
    }
    try {
      final memo = 'badge:$due';
      final retry = coin.history(me).any((t) => t.to == to && t.memo == memo);
      if (retry) {
        await coin.pay(to, due, memo: '$memo:${nowMs()}');
      } else {
        await coin.payOnce(to, due, memo: memo);
      }
      if (context.mounted) {
        toast(context, 'Paid. The check shows beside your name.');
      }
    } catch (err) {
      if (context.mounted) toast(context, '$err');
    }
  }
}

class _SellPage extends ConsumerStatefulWidget {
  const _SellPage({required this.kind, this.initial});
  final String kind;
  final Map<String, dynamic>? initial;

  @override
  ConsumerState<_SellPage> createState() => _SellPageState();
}

class _SellPageState extends ConsumerState<_SellPage> {
  final _title = TextEditingController();
  final _about = TextEditingController();
  final _price = TextEditingController();
  final _birr = TextEditingController();
  final _extra = TextEditingController();
  String _plugin = 'stickers';
  String _accent = 'emerald';
  String _resource = 'storage';
  final _attachments = <Pending>[];
  final _existingMedia = <MediaRef>[];

  @override
  void initState() {
    super.initState();
    final row = widget.initial;
    if (row == null) return;
    _title.text = row['title'] as String? ?? '';
    _about.text = row['about'] as String? ?? '';
    _price.text = Coin.format(row['minor'] as int? ?? 0);
    _birr.text = row['birr'] as String? ?? '';
    _plugin = row['plugin'] as String? ?? 'stickers';
    _resource = row['resource'] as String? ?? 'storage';
    final body = row['body'];
    if (body is Map) {
      _accent = body['accent'] as String? ?? 'emerald';
      _extra.text =
          ((body[_plugin == 'stickers' ? 'emoji' : 'lines'] as List?) ?? [])
              .join(_plugin == 'stickers' ? ' ' : '\n');
    }
    _existingMedia.addAll(MediaRef.listFrom(row['media']));
  }

  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _about.dispose();
    _price.dispose();
    _birr.dispose();
    _extra.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final kind = widget.kind;
    final exchange = kind == 'sell-mentos' || kind == 'buy-mentos';
    return Scaffold(
      appBar: AppBar(title: Text(_sellTitle(kind))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          Space.md,
          Space.gutter,
          Space.xxl,
        ),
        children: [
          Text(_sellHelp(kind), style: Txt.small(p.muted)),
          if (kind == 'plugin')
            Text(
              'Packs add stickers, saved phrases, or an accent. They cannot access files or run code. Set the price to 0 to share for free.',
              style: Txt.small(p.muted),
            ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _title,
            maxLength: 80,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: kind == 'ad' ? 'Headline' : 'Title',
            ),
          ),
          TextField(
            controller: _about,
            maxLength: kind == 'ad' ? 180 : 400,
            minLines: 2,
            maxLines: 5,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: kind == 'ad' ? 'What the post says' : 'Details',
            ),
          ),
          if (kind == 'plugin') ...[
            const SizedBox(height: Space.sm),
            Segmented<String>(
              value: _plugin,
              options: const {
                'stickers': 'Stickers',
                'theme': 'Accent',
                'phrases': 'Phrases',
              },
              onChanged: (v) => setState(() => _plugin = v),
            ),
            const SizedBox(height: Space.md),
            if (_plugin == 'stickers')
              TextField(
                controller: _extra,
                decoration: const InputDecoration(
                  labelText: 'Emoji',
                  hintText: '🌟 🚀 ☕',
                ),
              )
            else if (_plugin == 'theme')
              Segmented<String>(
                value: _accent,
                options: const {
                  'emerald': 'Emerald',
                  'blue': 'Blue',
                  'amber': 'Amber',
                  'ink': 'Ink',
                },
                onChanged: (v) => setState(() => _accent = v),
              )
            else
              TextField(
                controller: _extra,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Phrases, one per line',
                ),
              ),
          ],
          if (kind == 'resource') ...[
            const SizedBox(height: Space.sm),
            Segmented<String>(
              value: _resource,
              options: const {'storage': 'Storage', 'compute': 'Compute'},
              onChanged: (v) => setState(() => _resource = v),
            ),
          ],
          const SizedBox(height: Space.sm),
          Text('Listing attachments', style: Txt.heading(p.ink)),
          Text(
            'Add photos, a sample, or a detailed brief. These files are public with the listing.',
            style: Txt.small(p.muted),
          ),
          for (final file in _existingMedia.toList())
            ListTile(
              title: Text(file.name),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _existingMedia.remove(file)),
              ),
            ),
          for (final file in _attachments.toList())
            ListTile(
              title: Text(file.name),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _attachments.remove(file)),
              ),
            ),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    final picked = await pickFiles(
                      ref.read(engineProvider).media,
                      context: context,
                    );
                    if (mounted) {
                      setState(
                        () => _attachments.addAll(
                          picked.take(
                            (8 - _attachments.length - _existingMedia.length)
                                .clamp(0, 8),
                          ),
                        ),
                      );
                    }
                  },
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Add photos or files'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: _priceLabelFor(kind),
              hintText: '1.00',
            ),
          ),
          if (exchange)
            TextField(
              controller: _birr,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Birr you agreed',
                hintText: '100',
              ),
            ),
          if (kind == 'ad') ...[
            const SizedBox(height: Space.md),
            _AdPreview(
              title: _title.text.isEmpty ? 'Headline' : _title.text,
              about: _about.text,
              from: ref.read(engineProvider).me.id,
            ),
          ],
          const SizedBox(height: Space.lg),
          FilledButton(
            onPressed: _busy ? null : _publish,
            child: Text(_busy ? 'Listing' : 'List it'),
          ),
        ],
      ),
    );
  }

  Future<void> _publish() async {
    final e = ref.read(engineProvider);
    final kind = widget.kind;
    final title = _title.text.trim();
    final about = _about.text.trim();
    if (title.isEmpty || about.isEmpty) {
      toast(context, 'Add a title and describe what you are offering');
      return;
    }
    final minor =
        kind == 'plugin' &&
            (_price.text.trim() == '0' || _price.text.trim() == '0.00')
        ? 0
        : Coin.parse(_price.text.trim());
    if (minor == null || (minor <= 0 && kind != 'plugin')) {
      toast(context, 'Enter an amount like 1.50');
      return;
    }
    if ((kind == 'sell-mentos' || kind == 'buy-mentos') &&
        _birr.text.trim().isEmpty) {
      toast(context, 'Add the birr price you agreed');
      return;
    }
    Map<String, Object?> body = {};
    if (kind == 'plugin') {
      if (_plugin == 'stickers') {
        final emoji = _extra.text
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .take(24)
            .toList();
        if (emoji.isEmpty) {
          toast(context, 'Add at least one emoji');
          return;
        }
        body = {'emoji': emoji};
      } else if (_plugin == 'phrases') {
        final lines = _extra.text
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .take(12)
            .toList();
        if (lines.isEmpty) {
          toast(context, 'Add at least one phrase');
          return;
        }
        body = {'lines': lines};
      } else {
        body = {'accent': _accent};
      }
    }
    setState(() => _busy = true);
    try {
      String? id = widget.initial?['id'] as String?;
      final media = [..._existingMedia];
      for (final file in _attachments) {
        media.add(await importPending(e, file));
      }
      if (kind == 'ad') {
        final post = await e.createPost(
          text: about.isEmpty ? title : '$title\n$about',
          ad: true,
          budget: minor,
        );
        id = post.id;
      }
      if (kind == 'plugin') validatePlugin({'plugin': _plugin, 'body': body});
      await e.postMarket({
        ...?widget.initial,
        'id': ?id,
        'media': media.map((m) => m.toJson()).toList(),
        'kind': kind,
        'title': title,
        'about': about,
        'minor': minor,
        if (kind == 'task') 'status': 'open',
        'birr': _birr.text.trim(),
        if (kind == 'plugin') 'plugin': _plugin,
        if (kind == 'plugin') 'body': body,
        if (kind == 'resource') 'resource': _resource,
        if (kind == 'ad') 'post': id,
      });
      if (mounted) {
        toast(context, 'Listed');
        Navigator.pop(context);
      }
    } catch (err) {
      if (mounted) toast(context, '$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.copy = '', this.onTap});
  final String label;
  final String value;
  final String copy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return InkWell(
      onTap:
          onTap ??
          (copy.isEmpty
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: copy));
                  toast(context, 'Copied');
                }),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 108,
              child: Text(label, style: Txt.mono(p.faint, size: 11)),
            ),
            Expanded(child: Text(value, style: Txt.mono(p.ink, size: 11.5))),
          ],
        ),
      ),
    );
  }
}

String _kindLabel(String kind) => switch (kind) {
  'sell-mentos' => 'Selling Mentos',
  'buy-mentos' => 'Buying Mentos',
  'plugin' => 'Plugin',
  'ad' => 'Ad',
  'resource' => 'Phone',
  'task' => 'Task',
  _ => kind,
};

String _priceLabel(String kind, int minor, String birr) {
  final coins = minor > 0 ? '${Coin.format(minor)} Mentos' : '';
  if ((kind == 'sell-mentos' || kind == 'buy-mentos') && birr.isNotEmpty) {
    return coins.isEmpty ? '$birr birr' : '$coins · $birr birr';
  }
  return coins.isEmpty ? (kind == 'plugin' ? 'Free' : 'No price') : coins;
}

String _pluginKind(String plugin) => switch (plugin) {
  'stickers' => 'Sticker pack, in the chat sticker tray',
  'theme' => 'Accent, applied from this listing',
  'phrases' => 'Saved phrases, in the attach menu',
  _ => plugin,
};

String _pluginBlurb(Map<String, dynamic> pack) {
  final plugin = pack['plugin'] as String? ?? '';
  final body = pack['body'];
  if (plugin == 'stickers' && body is Map && body['emoji'] is List) {
    return '${(body['emoji'] as List).length} stickers';
  }
  if (plugin == 'theme' && body is Map) return 'Accent ${body['accent']}';
  if (plugin == 'phrases' && body is Map && body['lines'] is List) {
    return '${(body['lines'] as List).length} phrases';
  }
  return _pluginKind(plugin);
}

String _finePrint(String kind) => switch (kind) {
  'sell-mentos' || 'buy-mentos' => 'Birr is the price you agreed. This app does not send birr. Asking in chat records the offer. Mentos move only when a wallet sends them.',
  'plugin' => 'A plugin here is a pack this app can run: stickers in chats, an accent, or phrases in the attach menu. Paying installs it on this phone. It is not outside code.',
  'ad' => 'The ad is a post. Phones that keep it can be paid 0.05 Mentos each from this budget when you settle.',
  'resource' => 'Paying is the agreement. Storage or compute still happens between the two phones. Nothing here rents a datacenter.',
  'task' => 'Offering to do it sends a chat. The person who posted it pays the listed Mentos when they accept the result.',
  _ => 'Confirming a trade signs a Mentos payment on the shared ledger.',
};

String _takeLabel(String kind, int minor) => switch (kind) {
  'sell-mentos' || 'buy-mentos' => 'Ask in chat',
  'task' => 'Offer to do it',
  'plugin' => 'Pay ${Coin.format(minor)} and install',
  _ => 'Pay ${Coin.format(minor)}',
};

String _sellTitle(String kind) => switch (kind) {
  'sell-mentos' => 'Offer Mentos',
  'buy-mentos' => 'Offer birr',
  'plugin' => 'Sell a plugin',
  'ad' => 'Run an ad',
  'resource' => 'Offer this phone',
  'task' => 'Post a task',
  _ => 'List',
};

String _sellHelp(String kind) => switch (kind) {
  'sell-mentos' =>
    'Say how many Mentos you will send, and the birr you want in return.',
  'buy-mentos' =>
    'Say how many Mentos you want, and the birr you will pay the other person.',
  'plugin' => 'Pack stickers, an accent, or phrases. Buyers install the pack on their phone after they pay.',
  'ad' =>
    'The headline and text become a post. The budget pays phones that keep it.',
  'resource' =>
    'Describe the storage or compute you are offering from this phone.',
  'task' =>
    'Describe the result. You pay the listed Mentos when you accept it.',
  _ => 'Write the listing the way a buyer should read it.',
};

String _priceLabelFor(String kind) => switch (kind) {
  'sell-mentos' => 'Mentos you will send',
  'buy-mentos' => 'Mentos you want',
  'ad' => 'Budget in Mentos',
  _ => 'Price in Mentos',
};


class _ListingCover extends ConsumerStatefulWidget {
  const _ListingCover({required this.media, required this.from});
  final MediaRef media;
  final String from;
  @override
  ConsumerState<_ListingCover> createState() => _ListingCoverState();
}
class _ListingCoverState extends ConsumerState<_ListingCover> {
  File? file;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    file = ref.read(engineProvider).media.cached(widget.media);
  }
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(
      height: 160, width: double.infinity,
      child: file != null ? Image.file(file!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Center(child: Text('Photo could not be displayed')))
        : OutlinedButton.icon(onPressed: busy ? null : () async {
          setState(() => busy = true);
          try {
            final loaded = await ref.read(engineProvider).media.open(widget.media, sources: [widget.from]);
            if (mounted) { setState(() => file = loaded); if (loaded == null && context.mounted) toast(context, 'Photo unavailable; try when the seller is online'); }
          } catch (err) { if (context.mounted) toast(context, '$err'); }
          finally { if (mounted) setState(() => busy = false); }
        }, icon: const Icon(Icons.photo_outlined), label: Text(busy ? 'Loading photo…' : 'View listing photo')),
    )),
  );
}
