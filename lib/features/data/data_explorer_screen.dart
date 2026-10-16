import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/db.dart';
import '../../data/models.dart';
import '../../net/engine.dart';
import '../../net/engine_data.dart';
import '../../state/providers.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';

/// Everything stored on this device, browsable and exportable. Nothing here
/// leaves the phone unless the person shares an export.
class DataExplorerScreen extends ConsumerWidget {
  const DataExplorerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const Scaffold(body: Loading());
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Data explorer'),
          actions: [
            IconBtn(Icons.ios_share_rounded, tooltip: 'Export', onTap: () => showExportSheet(context, e)),
            const SizedBox(width: 8),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Overview'), Tab(text: 'Items'), Tab(text: 'Tables')]),
        ),
        body: TabBarView(
          children: [
            _Overview(e: e),
            ItemBrowser(e: e),
            _Tables(e: e),
          ],
        ),
      ),
    );
  }
}

Future<void> showExportSheet(BuildContext context, Engine e, {String? kind, String? scope}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ExportSheet(e: e, kind: kind, scope: scope),
  );
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.e, this.kind, this.scope});
  final Engine e;
  final String? kind;
  final String? scope;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  bool _secrets = false;
  bool _busy = false;

  Future<void> _go() async {
    setState(() => _busy = true);
    File? f;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/mentos-export');
      f = await widget.e.writeExport(dir, kind: widget.kind, scope: widget.scope, secrets: _secrets);
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/json')], subject: 'Mentos data export'));
      if (mounted) Navigator.pop(context);
    } catch (err) {
      if (mounted) toast(context, 'Export failed: $err');
    } finally {
      // The export is plaintext; it only lives as long as the share sheet.
      try {
        await f?.delete();
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final filtered = widget.kind != null || widget.scope != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(filtered ? 'Export this selection' : 'Export everything', style: Txt.title(p.ink)),
            const SizedBox(height: Space.sm),
            Text(
              filtered
                  ? 'Signed items${widget.kind == null ? '' : ' of kind ${widget.kind}'}${widget.scope == null ? '' : ' in ${widget.scope}'}, as JSON. Each one keeps its signature so anyone can verify it.'
                  : 'Every signed item (yours, kept, and live in memory) plus every table: contacts, custody grants, chats, files, delivery queue and settings, as one JSON file.',
              style: Txt.small(p.muted),
            ),
            const SizedBox(height: Space.md),
            SwitchTile(
              title: 'Include secrets',
              subtitle: 'Space, group and file keys and the PIN hash. Anyone with the file could read those spaces and files.',
              value: _secrets,
              onChanged: (v) => setState(() => _secrets = v),
            ),
            const SizedBox(height: Space.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _go,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.ios_share_rounded, size: 18),
                label: Text(_busy ? 'Preparing' : 'Export JSON'),
              ),
            ),
            const SizedBox(height: Space.sm),
            Text('The file is not encrypted. It is deleted from this phone when the share sheet closes.',
                style: Txt.mono(p.faint, size: 10.5)),
          ],
        ),
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.e});
  final Engine e;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final kinds = e.db.kindStats();
    final tiers = e.tierCounts();
    final scopes = e.db.scopeStats(limit: 12);
    final totalBytes = kinds.fold<int>(0, (a, k) => a + k.bytes);
    return ListView(
      padding: const EdgeInsets.only(bottom: Space.xxl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
          child: FutureBuilder(
            future: e.media.usage(),
            builder: (context, snap) {
              final u = snap.data;
              return Row(
                children: [
                  _Stat(value: bytes(e.db.fileBytes()), label: 'database', hint: 'encrypted SQLite'),
                  const SizedBox(width: Space.sm),
                  _Stat(value: u == null ? '…' : bytes(u.blobs), label: 'files', hint: u == null ? '' : '${u.count} encrypted blobs'),
                ],
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
          child: Row(
            children: [
              _Stat(value: '${tiers.owned}', label: 'yours', hint: 'signed here'),
              const SizedBox(width: Space.sm),
              _Stat(value: '${tiers.kept}', label: 'kept', hint: 'with consent'),
              const SizedBox(width: Space.sm),
              _Stat(value: '${tiers.live}', label: 'live', hint: 'memory only'),
            ],
          ),
        ),
        SectionLabel('By kind', trailing: Text(bytes(totalBytes), style: Txt.mono(p.faint, size: 11))),
        if (kinds.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Text('Nothing stored yet.', style: Txt.small(p.muted)),
          ),
        for (final k in kinds)
          InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Scaffold(appBar: AppBar(title: Text(kindLabel(k.kind))), body: ItemBrowser(e: e, kind: k.kind)),
            )),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 7),
              child: Row(
                children: [
                  Icon(kindIcon(k.kind), size: 18, color: p.inkSoft),
                  const SizedBox(width: Space.md),
                  SizedBox(width: 84, child: Text(kindLabel(k.kind), style: Txt.body(p.ink))),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) => Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          height: 6,
                          width: c.maxWidth * (totalBytes == 0 ? 0 : (k.bytes / totalBytes).clamp(0.02, 1.0)),
                          decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(3)),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 96,
                    child: Text('${k.count} · ${bytes(k.bytes)}', textAlign: TextAlign.right, style: Txt.mono(p.muted, size: 11)),
                  ),
                ],
              ),
            ),
          ),
        SectionLabel('Recent scopes'),
        for (final s in scopes)
          ListTile(
            dense: true,
            title: Text(scopeLabel(e, s.scope), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(s.scope, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.mono(p.faint, size: 10.5)),
            trailing: Text('${s.count} · ${timeAgo(s.last)}', style: Txt.mono(p.muted, size: 11)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                appBar: AppBar(title: Text(scopeLabel(e, s.scope))),
                body: ItemBrowser(e: e, scope: s.scope),
              ),
            )),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.folder_outlined, size: 18),
            label: const Text('Files on this phone'),
            onPressed: () => context.push('/files'),
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.hint});
  final String value;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.md), border: Border.all(color: p.line)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Txt.mono(p.muted, size: 10.5)),
            const SizedBox(height: 2),
            Text(value, style: Txt.heading(p.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(hint, style: Txt.mono(p.faint, size: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

String kindLabel(String k) => switch (k) {
      K.post => 'posts',
      K.comment => 'comments',
      K.like => 'likes',
      K.vote => 'votes',
      K.msg => 'messages',
      K.react => 'reactions',
      K.edit => 'edits',
      K.del => 'deletions',
      K.story => 'stories',
      K.profile => 'profiles',
      K.spaceMeta => 'space info',
      K.member => 'members',
      K.host => 'hosted files',
      K.group => 'group info',
      K.chan => 'channels',
      K.view => 'views',
      K.invite => 'invites',
      _ => k,
    };

IconData kindIcon(String k) => switch (k) {
      K.post => Icons.article_outlined,
      K.comment => Icons.mode_comment_outlined,
      K.like => Icons.favorite_border_rounded,
      K.vote => Icons.how_to_vote_outlined,
      K.msg => Icons.chat_bubble_outline_rounded,
      K.react => Icons.emoji_emotions_outlined,
      K.edit => Icons.edit_outlined,
      K.del => Icons.delete_outline_rounded,
      K.story => Icons.amp_stories_outlined,
      K.profile => Icons.badge_outlined,
      K.host => Icons.cloud_upload_outlined,
      K.view => Icons.visibility_outlined,
      K.chan => Icons.campaign_outlined,
      _ => Icons.data_object_rounded,
    };

/// A human name for a scope, falling back to its type.
String scopeLabel(Engine e, String scope) {
  final parts = Scope.parts(scope);
  final t = Scope.type(scope);
  switch (t) {
    case 'dm':
      final peer = Scope.dmPeer(scope, e.me.id);
      return peer == null ? 'chat' : 'chat with ${e.nameOf(peer)}';
    case 'feed':
      return parts.length > 1 ? 'posts by ${e.nameOf(parts[1])}' : 'posts';
    case 'story':
      return parts.length > 1 ? 'stories by ${e.nameOf(parts[1])}' : 'stories';
    case 'profile':
      return parts.length > 1 ? 'profile of ${e.nameOf(parts[1])}' : 'profile';
    case 'post':
      return 'replies on a post';
    case 'gdm' || 'gmeta':
      return 'group ${e.group(parts.length > 1 ? parts[1] : '')?.name ?? ''}'.trim();
    case 'chan' || 'sfeed' || 'space' || 'forum':
      final s = e.space(Scope.spaceOf(scope) ?? '');
      return 'space ${s?.name ?? ''}'.trim();
    case 'files':
      return parts.length > 1 ? 'files hosted by ${e.nameOf(parts[1])}' : 'hosted files';
    case 'bcast':
      return parts.length > 1 ? 'channel by ${e.nameOf(parts[1])}' : 'channel';
  }
  return t.isEmpty ? scope : t;
}

/// Filterable, paged list of signed items, including live ones in memory.
class ItemBrowser extends StatefulWidget {
  const ItemBrowser({super.key, required this.e, this.kind, this.scope});
  final Engine e;
  final String? kind;
  final String? scope;

  @override
  State<ItemBrowser> createState() => _ItemBrowserState();
}

enum _Where { all, yours, kept, live }

class _ItemBrowserState extends State<ItemBrowser> {
  late String? _kind = widget.kind;
  _Where _where = _Where.all;
  String _query = '';
  final _items = <Item>[];
  bool _more = true;
  static const _page = 60;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _items.clear();
    _more = true;
    _load();
  }

  void _load() {
    if (_where == _Where.live) {
      final q = _query.toLowerCase();
      final live = widget.e.liveItems().where((i) =>
          (_kind == null || i.e.kind == _kind) &&
          (widget.scope == null || i.e.scope == widget.scope) &&
          (q.isEmpty || i.e.payload.toLowerCase().contains(q)));
      setState(() {
        _items.addAll(live.toList()..sort((a, b) => b.ts.compareTo(a.ts)));
        _more = false;
      });
      return;
    }
    final last = _items.isEmpty ? null : _items.last;
    final page = widget.e.db.browseItems(
      kind: _kind,
      scope: widget.scope,
      owned: switch (_where) { _Where.yours => true, _Where.kept => false, _ => null },
      query: _query,
      before: last == null ? null : (ts: last.ts, id: last.id),
      limit: _page,
    );
    setState(() {
      _items.addAll(page);
      _more = page.length == _page;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final kinds = widget.kind == null ? widget.e.db.kindStats() : const <({String kind, int count, int owned, int bytes})>[];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded, size: 20),
              hintText: 'Search text, ids, hashes…',
              isDense: true,
            ),
            onChanged: (v) {
              _query = v;
              _reload();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
          child: Segmented<_Where>(
            value: _where,
            options: const {_Where.all: 'All', _Where.yours: 'Yours', _Where.kept: 'Kept', _Where.live: 'Live'},
            onChanged: (v) {
              _where = v;
              _reload();
            },
          ),
        ),
        if (kinds.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter - 4, vertical: 6),
              children: [
                _KindChip(label: 'all', on: _kind == null, onTap: () {
                  _kind = null;
                  _reload();
                }),
                for (final k in kinds)
                  _KindChip(label: '${kindLabel(k.kind)} ${k.count}', on: _kind == k.kind, onTap: () {
                    _kind = k.kind;
                    _reload();
                  }),
              ],
            ),
          ),
        Expanded(
          child: _items.isEmpty
              ? EmptyState(
                  icon: Icons.data_object_rounded,
                  title: _where == _Where.live ? 'Nothing live' : 'No items',
                  body: _where == _Where.live
                      ? 'Live items are other people\'s posts and messages you can see only while they are online. They are never written to disk.'
                      : 'Nothing matches.',
                  compact: true,
                )
              : ListView.builder(
                  itemCount: _items.length + (_more ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == _items.length) {
                      return Padding(
                        padding: const EdgeInsets.all(Space.md),
                        child: Center(child: TextButton(onPressed: _load, child: const Text('Load more'))),
                      );
                    }
                    final item = _items[i];
                    return _ItemRow(
                      e: widget.e,
                      item: item,
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => ItemInspector(e: widget.e, item: item),
                        ));
                        if (mounted && !widget.e.db.hasItem(item.id) && !item.live) setState(() => _items.remove(item));
                      },
                    );
                  },
                ),
        ),
        if (_items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
            child: Text('${_items.length}${_more ? '+' : ''} shown', style: Txt.mono(p.faint, size: 10.5)),
          ),
      ],
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: on ? p.ink : p.raised,
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          child: Text(label, style: Txt.mono(on ? p.bg : p.inkSoft, size: 11, w: FontWeight.w500)),
        ),
      ),
    );
  }
}

String itemSummary(Item i) {
  final b = i.body;
  final text = b['text'];
  if (text is String && text.trim().isNotEmpty) return text.trim().replaceAll('\n', ' ');
  final name = b['name'];
  if (name is String && name.isNotEmpty) return name;
  final emoji = b['emoji'];
  if (emoji is String) return emoji;
  final target = i.e.target;
  if (target != null) return '→ ${shortId(target)}';
  final media = MediaRef.listFrom(b['media']);
  if (media.isNotEmpty) return media.map((m) => m.name).join(', ');
  return i.e.kind;
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.e, required this.item, required this.onTap});
  final Engine e;
  final Item item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(kindIcon(item.e.kind), size: 18, color: p.inkSoft),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(itemSummary(item), maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.body(p.ink)),
                  const SizedBox(height: 3),
                  Text(
                    '${e.nameOf(item.author)} · ${scopeLabel(e, item.e.scope)} · ${timeAgo(item.ts)} · ${bytes(item.e.payload.length + item.e.sig.length)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.mono(p.muted, size: 10.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.sm),
            ProvenanceTag(ProvenanceTag.of(item), compact: true),
          ],
        ),
      ),
    );
  }
}

/// One signed item, inside out: fields, raw JSON, signature check, and what
/// points at it.
class ItemInspector extends StatefulWidget {
  const ItemInspector({super.key, required this.e, required this.item});
  final Engine e;
  final Item item;

  @override
  State<ItemInspector> createState() => _ItemInspectorState();
}

class _ItemInspectorState extends State<ItemInspector> {
  bool? _valid;
  bool _checking = false;

  Future<void> _verify() async {
    setState(() => _checking = true);
    final ok = await widget.item.e.verify();
    if (!mounted) return;
    setState(() {
      _valid = ok;
      _checking = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _verify();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = widget.e;
    final i = widget.item;
    final pretty = () {
      try {
        return const JsonEncoder.withIndent('  ').convert(jsonDecode(i.e.payload));
      } catch (_) {
        return i.e.payload;
      }
    }();
    final mutations = e.db.mutationsFor([i.id]);
    final target = i.e.target == null ? null : e.db.item(i.e.target!);
    return Scaffold(
      appBar: AppBar(
        title: Text(kindLabel(i.e.kind)),
        actions: [
          IconBtn(Icons.copy_rounded, tooltip: 'Copy signed JSON', onTap: () {
            Clipboard.setData(ClipboardData(text: jsonEncode(i.e.toWire())));
            toast(context, 'Copied signed envelope');
          }),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(
              color: _valid == false ? p.dangerSoft : p.accentSoft,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Row(
              children: [
                Icon(
                  _valid == null
                      ? Icons.hourglass_top_rounded
                      : (_valid! ? Icons.verified_rounded : Icons.gpp_bad_outlined),
                  size: 20,
                  color: _valid == false ? p.danger : p.accent,
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    _checking
                        ? 'Checking the Ed25519 signature…'
                        : _valid == true
                            ? 'Signature valid. ${e.nameOf(i.author)} signed exactly these bytes.'
                            : 'Signature does NOT match these bytes.',
                    style: Txt.small(p.ink),
                  ),
                ),
                if (!_checking) TextButton(onPressed: _verify, child: const Text('Recheck')),
              ],
            ),
          ),
          SectionLabel('Envelope'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: TechRows([
              ('id', i.id, copy: true),
              ('kind', i.e.kind, copy: false),
              ('author', '${e.nameOf(i.author)}\n${i.author}', copy: true),
              ('scope', i.e.scope, copy: true),
              ('meaning', scopeLabel(e, i.e.scope), copy: false),
              ('signed at', DateTime.fromMillisecondsSinceEpoch(i.ts).toLocal().toString(), copy: false),
              ('lives', i.owned ? 'yours, on disk' : (i.kept ? 'kept on disk with the author\'s consent' : 'in memory only'), copy: false),
              ('keep flag', i.e.keep ? 'author allows copies' : 'author did not allow copies', copy: false),
              if (i.e.expires != null) ('expires', DateTime.fromMillisecondsSinceEpoch(i.e.expires!).toLocal().toString(), copy: false),
              ('size', '${bytes(i.e.payload.length)} payload + ${bytes(i.e.sig.length)} signature', copy: false),
              ('signature', i.e.sig, copy: true),
            ]),
          ),
          if (target != null) ...[
            SectionLabel('Points at'),
            _ItemRow(e: e, item: target, onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ItemInspector(e: e, item: target)))),
          ],
          if (mutations.isNotEmpty) ...[
            SectionLabel('Pointing here', trailing: Text('${mutations.length}', style: Txt.mono(p.faint, size: 11))),
            for (final m in mutations.take(50))
              _ItemRow(e: e, item: m, onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ItemInspector(e: e, item: m)))),
          ],
          SectionLabel('Signed payload'),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: Space.gutter),
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.md)),
            child: SelectableText(pretty, style: Txt.mono(p.ink, size: 11)),
          ),
          if (!i.live)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
              child: OutlinedButton.icon(
                icon: Icon(Icons.delete_outline_rounded, size: 18, color: p.danger),
                label: Text('Delete from this phone', style: TextStyle(color: p.danger)),
                onPressed: () async {
                  final ok = await confirm(
                    context,
                    title: 'Delete locally?',
                    body: i.owned
                        ? 'Removes your copy only. People who already received it keep theirs; use delete in the app to ask them to drop it.'
                        : 'Removes the copy you kept. The author still has theirs.',
                    action: 'Delete',
                    danger: true,
                  );
                  if (!ok) return;
                  e.deleteLocal(i);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Tables extends StatelessWidget {
  const _Tables({required this.e});
  final Engine e;

  static const _about = {
    'items': 'every signed item stored here',
    'peers': 'people this node knows',
    'grants': 'custody consent, both directions',
    'spaces': 'spaces you joined',
    'groups': 'group chats',
    'files': 'encrypted blobs and their keys',
    'bookmarks': 'saved posts',
    'receipts': 'delivered/read markers per chat',
    'activity': 'your notifications feed',
    'chats': 'pin, mute, archive, timers',
    'outbox': 'controls waiting to send',
    'message_delivery': 'per-recipient message queue',
    'message_read': 'messages you have read',
    'kv': 'settings and small state',
  };

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final counts = e.db.tableCounts();
    return ListView(
      children: [
        for (final t in Db.explorable)
          ListTile(
            leading: Icon(Icons.table_rows_outlined, color: p.inkSoft),
            title: Text(t, style: Txt.mono(p.ink, size: 13, w: FontWeight.w500)),
            subtitle: Text(_about[t] ?? ''),
            trailing: Text('${counts[t] ?? 0}', style: Txt.mono(p.muted, size: 12)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _TableRows(e: e, table: t))),
          ),
      ],
    );
  }
}

class _TableRows extends StatefulWidget {
  const _TableRows({required this.e, required this.table});
  final Engine e;
  final String table;

  @override
  State<_TableRows> createState() => _TableRowsState();
}

class _TableRowsState extends State<_TableRows> {
  final _rows = <Map<String, Object?>>[];
  bool _more = true;
  bool _secrets = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final page = widget.e.db.tableRows(widget.table, limit: 100, offset: _rows.length);
    setState(() {
      _rows.addAll(page);
      _more = page.length == 100;
    });
  }

  String _preview(Map<String, Object?> r) {
    final parts = <String>[];
    for (final e in r.entries) {
      if (e.key == 'payload' || e.key == 'sig') continue;
      var v = '${e.value}';
      if (v.length > 40) v = '${v.substring(0, 40)}…';
      parts.add('${e.key}=$v');
      if (parts.length >= 4) break;
    }
    return parts.join('  ');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.table, style: Txt.mono(p.ink, size: 16, w: FontWeight.w500)),
        actions: [
          IconBtn(_secrets ? Icons.key_rounded : Icons.key_off_rounded,
              tooltip: _secrets ? 'Hide secrets' : 'Show secrets', active: _secrets, onTap: () => setState(() => _secrets = !_secrets)),
          const SizedBox(width: 8),
        ],
      ),
      body: _rows.isEmpty
          ? const EmptyState(icon: Icons.table_rows_outlined, title: 'Empty table')
          : ListView.separated(
              itemCount: _rows.length + (_more ? 1 : 0),
              separatorBuilder: (_, _) => const Hairline(),
              itemBuilder: (context, i) {
                if (i == _rows.length) {
                  return Center(child: TextButton(onPressed: _load, child: const Text('Load more')));
                }
                final row = redactRow(widget.table, _rows[i], secrets: _secrets);
                return InkWell(
                  onTap: () => showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => SafeArea(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
                        child: TechRows([for (final c in row.entries) (c.key, '${c.value}', copy: true)]),
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 10),
                    child: Text(_preview(row), style: Txt.mono(p.ink, size: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                );
              },
            ),
    );
  }
}
