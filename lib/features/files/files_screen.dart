import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/media.dart';
import '../../widgets/ui.dart';
import 'hosted_list.dart';

enum _Filter { all, mine, kept, cache }

enum _Kind { any, images, video, audio, docs }

class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  _Filter _filter = _Filter.all;
  _Kind _kind = _Kind.any;
  ({int blobs, int view, int count})? _usage;

  @override
  void initState() {
    super.initState();
    _refreshUsage();
  }

  Future<void> _refreshUsage() async {
    final u = await ref.read(engineProvider).media.usage();
    if (mounted) setState(() => _usage = u);
  }

  bool _matchKind(StoredFile f) => switch (_kind) {
        _Kind.any => true,
        _Kind.images => f.mime.startsWith('image/'),
        _Kind.video => f.mime.startsWith('video/'),
        _Kind.audio => f.mime.startsWith('audio/'),
        _Kind.docs => !f.mime.startsWith('image/') && !f.mime.startsWith('video/') && !f.mime.startsWith('audio/'),
      };

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final files = ref.watch(filesProvider).value ?? const <StoredFile>[];
    final shown = files
        .where((f) => _filter == _Filter.all || f.origin == _filter.name)
        .where(_matchKind)
        .toList();
    int sizeOf(String origin) => files.where((f) => f.origin == origin).fold(0, (a, f) => a + f.size);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          IconBtn(Icons.swap_horiz_rounded, tooltip: 'Transfer', onTap: () => context.push('/transfer')),
          IconBtn(Icons.add_rounded, tooltip: 'Host a file', onTap: () => _host(context)),
          IconBtn(Icons.cleaning_services_outlined, tooltip: 'Clean up', onTap: () => _cleanup(context)),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            padding: const EdgeInsets.all(Space.lg),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: p.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_usage == null ? '…' : bytes(_usage!.blobs), style: Txt.display(p.ink).copyWith(fontSize: 28)),
                Text('encrypted on this phone · ${_usage?.count ?? 0} blobs', style: Txt.mono(p.muted, size: 11)),
                const SizedBox(height: Space.lg),
                _Bar(parts: [
                  (sizeOf('mine'), p.ink),
                  (sizeOf('kept'), p.accent),
                  (sizeOf('cache'), p.faint),
                ]),
                const SizedBox(height: Space.md),
                Row(
                  children: [
                    _Legend(color: p.ink, label: 'yours', value: bytes(sizeOf('mine'))),
                    const SizedBox(width: Space.lg),
                    _Legend(color: p.accent, label: 'kept for others', value: bytes(sizeOf('kept'))),
                    const SizedBox(width: Space.lg),
                    _Legend(color: p.faint, label: 'temporary', value: bytes(sizeOf('cache'))),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
            child: Segmented<_Filter>(
              value: _filter,
              options: const {_Filter.all: 'All', _Filter.mine: 'Yours', _Filter.kept: 'Kept', _Filter.cache: 'Temp'},
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 10),
              children: [
                for (final k in _Kind.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(switch (k) {
                        _Kind.any => 'Any type',
                        _Kind.images => 'Images',
                        _Kind.video => 'Video',
                        _Kind.audio => 'Audio',
                        _Kind.docs => 'Documents',
                      }),
                      selected: _kind == k,
                      showCheckmark: false,
                      labelStyle: Txt.small(_kind == k ? p.bg : p.ink),
                      onSelected: (_) => setState(() => _kind = k),
                    ),
                  ),
              ],
            ),
          ),
          SectionLabel('Hosted catalog'),
          const HostedList(author: '', searchable: true, compact: true),
          SectionLabel('On this phone'),
          if (shown.isEmpty)
            const EmptyState(icon: Icons.folder_open_rounded, title: 'No files here', compact: true)
          else
            for (final f in shown)
              ListTile(
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.sm + 2)),
                  child: Icon(fileIcon(f.mime), color: p.inkSoft, size: 20),
                ),
                title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${bytes(f.size)} · ${_originLabel(f.origin)} · ${timeAgo(f.created)}',
                    style: Txt.mono(p.muted, size: 11)),
                onTap: () => _open(f),
                trailing: IconBtn(Icons.more_vert_rounded, size: 18, color: p.muted, onTap: () => _menu(context, f)),
              ),
          const SizedBox(height: Space.xxl),
        ],
      ),
    );
  }

  String _originLabel(String o) => switch (o) { 'mine' => 'yours', 'kept' => 'kept', _ => 'temporary' };

  Future<void> _host(BuildContext context) async {
    final e = ref.read(engineProvider);
    final n = await hostPickedFiles(context, e);
    if (n == 0) return;
    await _refreshUsage();
    if (context.mounted) toast(context, 'Now hosting on your node');
  }

  Future<void> _open(StoredFile f) async {
    final e = ref.read(engineProvider);
    final out = await e.media.export(f.ref);
    if (out == null) {
      if (mounted) toast(context, 'This file is no longer on this phone.');
      return;
    }
    if (!mounted) return;
    await showLocalFile(context, out, name: f.name, mime: f.mime);
  }

  void _menu(BuildContext context, StoredFile f) {
    final e = ref.read(engineProvider);
    showActions(context, [
      SheetAction(Icons.open_in_new_rounded, 'Open', () => _open(f)),
      SheetAction(Icons.ios_share_rounded, 'Share / save outside Mentos', () async {
        final out = await e.media.export(f.ref);
        if (out != null) await SharePlus.instance.share(ShareParams(files: [XFile(out.path)]));
      }),
      SheetAction(Icons.delete_outline_rounded, 'Delete from this phone', () async {
        final ok = await confirm(context,
            title: 'Delete ${f.name}?',
            body: f.origin == 'mine'
                ? 'Posts and messages that include it will show it as unavailable for everyone.'
                : 'Removes the local copy.',
            action: 'Delete',
            danger: true);
        if (!ok) return;
        await e.media.deleteBlob(f.hash);
        e.notifyFiles();
        await _refreshUsage();
      }, danger: true),
    ], title: f.name.toUpperCase());
  }

  Future<void> _cleanup(BuildContext context) async {
    final e = ref.read(engineProvider);
    final ok = await confirm(context,
        title: 'Clean up?',
        body: 'Deletes temporary copies of other people\'s media and the decrypted preview cache. '
            'Your files and files you keep for others stay.',
        action: 'Clean up');
    if (!ok) return;
    for (final f in e.db.files().where((f) => f.origin == 'cache')) {
      await e.media.deleteBlob(f.hash);
    }
    await e.media.clearViewCache();
    e.notifyFiles();
    await _refreshUsage();
    if (context.mounted) toast(context, 'Cleaned up');
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.parts});
  final List<(int, Color)> parts;

  @override
  Widget build(BuildContext context) {
    final total = parts.fold<int>(0, (a, b) => a + b.$1);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: total == 0
            ? Container(color: context.pal.raised)
            : Row(
                children: [
                  for (final part in parts)
                    if (part.$1 > 0) Expanded(flex: (part.$1 * 1000 ~/ total).clamp(1, 1000), child: Container(color: part.$2)),
                ],
              ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label, required this.value});
  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 5),
          Text(label, style: Txt.mono(p.muted, size: 10)),
        ]),
        Text(value, style: Txt.mono(p.ink, size: 11.5)),
      ],
    );
  }
}
