import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/engine.dart';
import '../../state/providers.dart';
import '../../widgets/media.dart';
import '../../widgets/ui.dart';
import '../common/attach.dart';

/// Picks files, asks for a description, folder and tags, and hosts them.
Future<int> hostPickedFiles(BuildContext context, Engine e) async {
  final picked = await pickFiles(e.media, context: context);
  if (picked.isEmpty || !context.mounted) return 0;
  final folders = {for (final i in e.hosted(e.me.id)) HostMeta.of(i).folder}
    ..remove('');
  final meta = await showInputSheet<HostMeta>(
    context,
    (_) => _HostSheet(
      files: picked,
      folders: folders.toList()..sort(),
      people: e.people().where((x) => !x.blocked).toList(),
    ),
  );
  if (meta == null) return 0;
  var n = 0;
  for (final f in picked) {
    final media = await importPending(e, f, scope: Scope.files(e.me.id));
    await e.hostFile(
      media,
      note: meta.note,
      folder: meta.folder,
      tags: meta.tags,
      lock: meta.password.isEmpty ? '' : e.lockHash(meta.password),
      audience: meta.audience,
    );
    n++;
  }
  e.notifyFiles();
  return n;
}

class _HostSheet extends StatefulWidget {
  const _HostSheet({
    required this.files,
    required this.folders,
    required this.people,
  });
  final List<Pending> files;
  final List<String> folders;
  final List<Peer> people;

  @override
  State<_HostSheet> createState() => _HostSheetState();
}

class _HostSheetState extends State<_HostSheet> {
  final _note = TextEditingController();
  final _folder = TextEditingController();
  final _tags = TextEditingController();
  final _password = TextEditingController();
  final _extra = TextEditingController();
  final _filter = TextEditingController();
  final _audience = <String>{};
  bool _hidePassword = true;

  @override
  void dispose() {
    _note.dispose();
    _folder.dispose();
    _tags.dispose();
    _password.dispose();
    _extra.dispose();
    _filter.dispose();
    super.dispose();
  }

  int _len(Pending f) {
    try {
      return f.file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  void _submit() {
    final tags = HostMeta.parseTags(_tags.text);
    final extra = _extra.text
        .split(RegExp(r'[,\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    final audience = {..._audience, ...extra}.toList();
    Navigator.pop(
      context,
      HostMeta(
        note: _note.text.trim(),
        folder: _folder.text.trim(),
        tags: tags,
        password: _password.text,
        audience: audience,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final tags = HostMeta.parseTags(_tags.text);
    final q = _filter.text.trim().toLowerCase();
    final matched = widget.people.where((person) {
      if (q.isEmpty) return true;
      return person.name.toLowerCase().contains(q) || person.id.startsWith(q);
    }).toList();
    final selected = widget.people
        .where((person) => _audience.contains(person.id))
        .toList();
    final rest = matched
        .where((person) => !_audience.contains(person.id))
        .toList();
    final shown = q.isEmpty ? rest.take(12).toList() : rest.take(40).toList();
    final locked = _password.text.isNotEmpty;
    final limited = _audience.isNotEmpty || _extra.text.trim().isNotEmpty;
    return InputSheet(
      title: widget.files.length == 1
          ? 'Host this file'
          : 'Host ${widget.files.length} files',
      body: 'Stays on this phone. Others can fetch it while you are online, or from someone keeping a copy.',
      action: locked ? 'Host with password' : 'Host',
      onAction: _submit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final f in widget.files.take(4))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                _len(f) == 0 ? f.name : '${f.name} · ${bytes(_len(f))}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Txt.mono(p.muted, size: 12),
              ),
            ),
          if (widget.files.length > 4)
            Text(
              '+ ${widget.files.length - 4} more',
              style: Txt.mono(p.faint, size: 11),
            ),
          const SizedBox(height: Space.lg),
          SheetLabel('Description', trailing: '${_note.text.length}/500'),
          TextField(
            controller: _note,
            autofocus: true,
            maxLength: 500,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'What is in here',
              counterText: '',
            ),
          ),
          const SizedBox(height: Space.lg),
          SheetLabel('Folder', trailing: '${_folder.text.length}/60'),
          TextField(
            controller: _folder,
            maxLength: 60,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Music, photos, …',
              counterText: '',
            ),
          ),
          if (widget.folders.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in widget.folders.take(12))
                  SheetChip(
                    f,
                    selected: _folder.text.trim() == f,
                    onTap: () {
                      _folder.text = f;
                      setState(() {});
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: Space.lg),
          SheetLabel('Tags', trailing: '${tags.length}/${HostMeta.maxTags}'),
          TextField(
            controller: _tags,
            textCapitalization: TextCapitalization.none,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'comma separated',
              counterText: '',
            ),
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in tags)
                  SheetChip(
                    '#$t',
                    selected: true,
                    onTap: () {
                      _tags.text = tags.where((x) => x != t).join(', ');
                      setState(() {});
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: Space.lg),
          const SheetLabel('Password'),
          TextField(
            controller: _password,
            obscureText: _hidePassword,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Optional',
              counterText: '',
              suffixIcon: IconButton(
                tooltip: _hidePassword ? 'Show' : 'Hide',
                onPressed: () => setState(() => _hidePassword = !_hidePassword),
                icon: Icon(
                  _hidePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color: p.muted,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            locked
                ? 'Fetch asks for this password.'
                : 'Leave empty and anyone who can see the file can fetch it.',
            style: Txt.small(p.faint),
          ),
          const SizedBox(height: Space.lg),
          SheetLabel('Who can fetch it'),
          Text(
            limited
                ? 'Only the people you pick, plus any keys you paste.'
                : 'Anyone who can see your hosted files.',
            style: Txt.small(p.muted),
          ),
          if (widget.people.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            TextField(
              controller: _filter,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Filter people',
                counterText: '',
              ),
            ),
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final person in [...selected, ...shown])
                  SheetChip(
                    person.name,
                    selected: _audience.contains(person.id),
                    onTap: () => setState(() {
                      if (!_audience.add(person.id))
                        _audience.remove(person.id);
                    }),
                  ),
              ],
            ),
            if (q.isEmpty && rest.length > shown.length)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${rest.length - shown.length} more. Filter by name.',
                  style: Txt.small(p.faint),
                ),
              ),
          ],
          const SizedBox(height: Space.sm),
          TextField(
            controller: _extra,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Or paste keys, comma separated',
              counterText: '',
            ),
          ),
        ],
      ),
    );
  }
}

enum _Sort { newest, name, size, popular }

class HostedList extends ConsumerStatefulWidget {
  const HostedList({
    super.key,
    required this.author,
    this.searchable = false,
    this.compact = false,
  });
  final String author;
  final bool searchable;
  final bool compact;

  @override
  ConsumerState<HostedList> createState() => _HostedListState();
}

class _HostedListState extends ConsumerState<HostedList> {
  String _q = '';
  String? _folder;
  _Sort _sort = _Sort.newest;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final e = ref.read(engineProvider);
      final a = widget.author.isEmpty ? e.me.id : widget.author;
      if (a != e.me.id) e.refreshHosted(a);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final local = widget.author.isEmpty ? e.me.id : widget.author;
    var items = ref.watch(hostedProvider(local)).value ?? const <Item>[];
    if (widget.searchable && _q.isNotEmpty) {
      items = widget.author.isEmpty
          ? e.searchHosted(_q)
          : e.searchHosted(_q).where((i) => i.author == widget.author).toList();
    }
    final folders = {for (final i in items) HostMeta.of(i).folder}..remove('');
    if (_folder != null)
      items = items.where((i) => HostMeta.of(i).folder == _folder).toList();
    MediaRef? ref0(Item i) => MediaRef.listFrom(i.body['media']).firstOrNull;
    items = [...items];
    switch (_sort) {
      case _Sort.newest:
        items.sort((a, b) => b.ts.compareTo(a.ts));
      case _Sort.name:
        items.sort(
          (a, b) => (ref0(a)?.name ?? '').toLowerCase().compareTo(
            (ref0(b)?.name ?? '').toLowerCase(),
          ),
        );
      case _Sort.size:
        items.sort(
          (a, b) => (ref0(b)?.size ?? 0).compareTo(ref0(a)?.size ?? 0),
        );
      case _Sort.popular:
        items.sort((a, b) => e.hostDownloads(b).compareTo(e.hostDownloads(a)));
    }
    final total = items.fold<int>(0, (a, i) => a + (ref0(i)?.size ?? 0));
    final own = local == e.me.id && widget.author.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.searchable)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              0,
              Space.gutter,
              Space.sm,
            ),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: 'Search names, descriptions, #tags',
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: p.faint,
                  size: 20,
                ),
              ),
            ),
          ),
        if (items.isNotEmpty || folders.isNotEmpty)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter - 4),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: PopupMenuButton<_Sort>(
                    initialValue: _sort,
                    onSelected: (v) => setState(() => _sort = v),
                    itemBuilder: (_) => [
                      for (final s in _Sort.values)
                        PopupMenuItem(value: s, child: Text(s.name)),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.sort_rounded, size: 16),
                      label: Text(_sort.name),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                if (folders.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: const Text('all'),
                      selected: _folder == null,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _folder = null),
                    ),
                  ),
                for (final f in folders.toList()..sort())
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      avatar: const Icon(Icons.folder_outlined, size: 16),
                      label: Text(f),
                      selected: _folder == f,
                      visualDensity: VisualDensity.compact,
                      onSelected: (on) =>
                          setState(() => _folder = on ? f : null),
                    ),
                  ),
              ],
            ),
          ),
        if (items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              4,
              Space.gutter,
              0,
            ),
            child: Text(
              '${items.length} file${items.length == 1 ? '' : 's'} · ${bytes(total)}'
              '${own ? ' · ${items.fold<int>(0, (a, i) => a + e.hostDownloads(i))} downloads' : ''}',
              style: Txt.mono(p.faint, size: 10.5),
            ),
          ),
        if (items.isEmpty)
          EmptyState(
            icon: Icons.hub_outlined,
            title: (widget.author.isEmpty || widget.author == e.me.id)
                ? 'Nothing hosted'
                : 'No files from this node',
            body: (widget.author.isEmpty || widget.author == e.me.id)
                ? 'Pick a file to announce it. Others can fetch it from your profile while you (or a keeper) are online.'
                : 'Hosted files appear while this person is reachable, or if you keep their catalog.',
            compact: widget.compact,
          )
        else
          for (final i in items) _HostRow(item: i),
      ],
    );
  }
}

class _HostRow extends ConsumerWidget {
  const _HostRow({required this.item});
  final Item item;

  Future<void> _take(BuildContext context, Engine e, MediaRef media) async {
    final meta = HostMeta.of(item);
    String? password;
    if (meta.lock.isNotEmpty) {
      password = await prompt(
        context,
        title: 'Password',
        body: 'This file is locked. The password is checked before the download starts.',
        action: 'Open',
        obscure: true,
        allowEmpty: false,
        capitalization: TextCapitalization.none,
      );
      if (password == null || !context.mounted) return;
    }
    toast(context, 'Fetching ${media.name}');
    final f = await e.takeHosted(item, password: password);
    if (f == null) {
      if (context.mounted)
        toast(
          context,
          meta.lock.isNotEmpty
              ? 'Wrong password, or no seeder is reachable.'
              : 'No seeder reachable for this hash.',
        );
      return;
    }
    if (!context.mounted) return;
    await showLocalFile(context, f, name: media.name, mime: media.mime);
  }

  void _details(BuildContext context, Engine e, MediaRef media, HostMeta meta) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final p = ctx.pal;
        final sources = e.sourcesFor(item);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              0,
              Space.gutter,
              Space.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(media.name, style: Txt.title(p.ink)),
                if (meta.note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(meta.note, style: Txt.body(p.inkSoft)),
                ],
                if (meta.tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final t in meta.tags)
                        Chip(
                          label: Text('#$t'),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: Space.md),
                for (final (k, v) in [
                  ('size', bytes(media.size)),
                  ('type', media.mime),
                  ('host', e.nameOf(item.author)),
                  if (meta.folder.isNotEmpty) ('folder', meta.folder),
                  ('hosted', timeAgo(item.ts)),
                  (
                    'downloads',
                    '${e.hostDownloads(item)}${item.owned ? '' : ' seen from here'}',
                  ),
                  (
                    'seeders',
                    sources.isEmpty
                        ? 'none reachable'
                        : sources.map(e.nameOf).join(', '),
                  ),
                  ('hash', media.hash),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: GestureDetector(
                      onLongPress: () {
                        Clipboard.setData(ClipboardData(text: v));
                        toast(ctx, 'Copied');
                      },
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 84,
                            child: Text(k, style: Txt.mono(p.faint, size: 11)),
                          ),
                          Expanded(
                            child: Text(v, style: Txt.mono(p.ink, size: 11.5)),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: Space.md),
                Row(
                  children: [
                    if (!item.owned)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            ctx.push('/u/${item.author}');
                          },
                          child: const Text('Host profile'),
                        ),
                      ),
                    if (!item.owned) const SizedBox(width: Space.sm),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _take(context, e, media);
                        },
                        child: Text(item.owned ? 'Open' : 'Download'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final media = MediaRef.listFrom(item.body['media']).firstOrNull;
    if (media == null) return const SizedBox.shrink();
    final meta = HostMeta.of(item);
    final downloads = e.hostDownloads(item);
    return ListTile(
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: p.raised,
          borderRadius: BorderRadius.circular(Radii.sm + 2),
        ),
        child: Icon(fileIcon(media.mime), color: p.inkSoft, size: 20),
      ),
      title: Text(media.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          bytes(media.size),
          if (!item.owned) e.nameOf(item.author),
          if (downloads > 0) '$downloads ↓',
          if (meta.tags.isNotEmpty) meta.tags.map((t) => '#$t').join(' '),
          if (meta.note.isNotEmpty) meta.note,
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Txt.mono(p.muted, size: 11),
      ),
      onTap: () => _take(context, e, media),
      onLongPress: () => _details(context, e, media, meta),
      trailing: item.owned
          ? IconBtn(
              Icons.delete_outline_rounded,
              size: 18,
              color: p.muted,
              tooltip: 'Stop hosting',
              onTap: () async {
                final ok = await confirm(
                  context,
                  title: 'Stop hosting?',
                  body:
                      'Removes ${media.name} from your hosted files. People who already downloaded it keep their copy.',
                  action: 'Stop hosting',
                  danger: true,
                );
                if (ok) await e.deleteItem(item);
              },
            )
          : IconBtn(
              Icons.info_outline_rounded,
              size: 18,
              color: p.muted,
              tooltip: 'Details',
              onTap: () => _details(context, e, media, meta),
            ),
    );
  }
}
