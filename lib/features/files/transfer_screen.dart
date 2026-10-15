import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/transport.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import '../../widgets/xfer.dart';
import '../common/attach.dart';

class TransfersScreen extends ConsumerWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final xfers = ref.watch(transfersProvider).value ?? const <FileTransfer>[];
    final people = ref.watch(peopleProvider).value ?? const <Peer>[];
    final online = people.where((x) => !x.blocked).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('File transfer')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: Text(
              'Send a file straight to another phone. The bytes go peer to peer; Mentos never hosts them.',
              style: Txt.small(p.muted),
            ),
          ),
          SectionLabel('Send to'),
          if (online.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Text('Add someone first, then you can send a file while they are reachable.'),
            )
          else
            for (final x in online)
              ListTile(
                leading: Avatar(id: x.id, size: 40),
                title: Text(x.name),
                subtitle: Text(shortId(x.id), style: Txt.mono(p.muted, size: 11)),
                trailing: Icon(Icons.chevron_right_rounded, color: p.faint),
                onTap: () => context.push('/transfer/${x.id}'),
              ),
          _XferTabs(xfers: xfers),
        ],
      ),
    );
  }
}

class _XferTabs extends StatefulWidget {
  const _XferTabs({required this.xfers});
  final List<FileTransfer> xfers;

  @override
  State<_XferTabs> createState() => _XferTabsState();
}

class _XferTabsState extends State<_XferTabs> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final moving = widget.xfers.where((x) => x.moving).toList();
    final done = widget.xfers.where((x) => !x.moving).toList();
    final list = _tab == 0 ? moving : done;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
          child: Segmented<int>(
            value: _tab,
            options: {0: 'Transferring (${moving.length})', 1: 'Completed (${done.length})'},
            onChanged: (v) => setState(() => _tab = v),
          ),
        ),
        if (list.isEmpty)
          EmptyState(
            icon: _tab == 0 ? Icons.swap_horiz_rounded : Icons.inventory_2_outlined,
            title: _tab == 0 ? 'Nothing moving' : 'No finished transfers',
            compact: true,
          )
        else
          for (final x in list) XferTile(x: x),
      ],
    );
  }
}

class PeerTransferScreen extends ConsumerStatefulWidget {
  const PeerTransferScreen({super.key, required this.peer});
  final String peer;

  @override
  ConsumerState<PeerTransferScreen> createState() => _PeerTransferScreenState();
}

class _PeerTransferScreenState extends ConsumerState<PeerTransferScreen> {
  bool _busy = false;

  Future<void> _send() async {
    final e = ref.read(engineProvider);
    final picked = await pickFiles(e.media);
    if (picked.isEmpty) return;
    setState(() => _busy = true);
    try {
      for (final f in picked) {
        final ref = await importPending(e, f, scope: Scope.dm(e.me.id, widget.peer));
        await e.offerTransfer(widget.peer, ref);
        e.notifyFiles();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final person = ref.watch(peerProvider(widget.peer)).value;
    final online = ref.watch(onlineProvider(widget.peer)).value ?? false;
    final status = ref.watch(netStatusProvider).value;
    final link = status?.links.where((l) => l.peer == widget.peer).firstOrNull;
    final mine = (ref.watch(transfersProvider).value ?? const <FileTransfer>[])
        .where((x) => x.peer == widget.peer)
        .toList();

    final path = switch (link?.kind) {
      LinkKind.direct => 'direct QUIC',
      LinkKind.relay => 'relayed',
      LinkKind.mixed => 'direct + relay',
      _ => online ? 'reachable' : 'offline',
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(person?.name ?? alias(widget.peer)),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
            child: Row(
              children: [
                Avatar(id: widget.peer, size: 56),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(person?.name ?? alias(widget.peer), style: Txt.heading(p.ink)),
                      const SizedBox(height: 4),
                      Text(
                        '$path${link?.latencyMs == null ? '' : ' · ${link!.latencyMs} ms'} · ${online ? 'online' : lastSeen(person?.lastSeen ?? 0)}',
                        style: Txt.mono(online ? p.accent : p.muted, size: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
            child: Text(
              'The file is encrypted on this phone, addressed by hash, and fetched by their node. '
              'If they go offline mid-transfer, it stops until they return.',
              style: Txt.small(p.muted),
            ),
          ),
          SectionLabel('With ${person?.name ?? 'them'}'),
          if (mine.isEmpty)
            const EmptyState(icon: Icons.folder_open_rounded, title: 'Nothing moving', compact: true)
          else
            for (final x in mine) XferTile(x: x),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, 8),
          child: FilledButton.icon(
            onPressed: _busy || !online ? null : _send,
            icon: const Icon(Icons.upload_rounded, size: 18),
            label: Text(_busy ? 'Preparing…' : online ? 'Send a file' : 'They need to be online'),
          ),
        ),
      ),
    );
  }
}
