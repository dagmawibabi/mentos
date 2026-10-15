import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/media.dart';
import '../../widgets/ui.dart';

class HostedList extends ConsumerStatefulWidget {
  const HostedList({super.key, required this.author, this.searchable = false, this.compact = false});
  final String author;
  final bool searchable;
  final bool compact;

  @override
  ConsumerState<HostedList> createState() => _HostedListState();
}

class _HostedListState extends ConsumerState<HostedList> {
  String _q = '';

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.searchable)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: 'Search hosted files',
                prefixIcon: Icon(Icons.search_rounded, color: p.faint, size: 20),
              ),
            ),
          ),
        if (items.isEmpty)
          EmptyState(
            icon: Icons.hub_outlined,
            title: (widget.author.isEmpty || widget.author == e.me.id) ? 'Nothing hosted' : 'No files from this node',
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final media = MediaRef.listFrom(item.body['media']).firstOrNull;
    if (media == null) return const SizedBox.shrink();
    final note = item.body['note'] as String? ?? '';
    return ListTile(
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.sm + 2)),
        child: Icon(fileIcon(media.mime), color: p.inkSoft, size: 20),
      ),
      title: Text(media.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          bytes(media.size),
          e.nameOf(item.author),
          ProvenanceTag.of(item).name,
          if (note.isNotEmpty) note,
        ].join(' · '),
        style: Txt.mono(p.muted, size: 11),
      ),
      onTap: () async {
        toast(context, 'Fetching ${media.name}');
        final f = await e.takeHosted(item);
        if (f == null) {
          if (context.mounted) toast(context, 'No seeder reachable for this hash.');
          return;
        }
        final r = await OpenFilex.open(f.path, type: media.mime);
        if (r.type != ResultType.done) await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
      },
      trailing: item.owned
          ? IconBtn(Icons.delete_outline_rounded, size: 18, color: p.muted, onTap: () => e.deleteItem(item))
          : null,
    );
  }
}
