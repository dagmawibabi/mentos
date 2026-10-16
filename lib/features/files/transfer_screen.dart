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

    final moving = xfers.where((x) => x.state == XferState.active).toList();
    final speed = moving.fold<int>(0, (a, x) => a + x.bps);
    final left = moving.fold<int>(0, (a, x) => a + (x.total - x.done).clamp(0, 1 << 40));

    return Scaffold(
      appBar: AppBar(
        title: const Text('File transfer'),
        actions: [
          IconBtn(Icons.tune_rounded, tooltip: 'Transfer settings', onTap: () => _settings(context, ref)),
          const SizedBox(width: 8),
        ],
      ),
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
          if (moving.isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(Radii.md)),
              child: Row(
                children: [
                  Icon(Icons.swap_vert_rounded, color: p.accent, size: 20),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      '${moving.length} moving · ${speed > 0 ? '${bytes(speed)}/s' : 'starting'}'
                      '${speed > 0 && left > 0 ? ' · about ${_eta(left ~/ speed)} left' : ''}',
                      style: Txt.mono(p.ink, size: 11.5),
                    ),
                  ),
                ],
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

String _eta(int seconds) => seconds < 60
    ? '${seconds}s'
    : seconds < 3600
        ? '${seconds ~/ 60}m ${seconds % 60}s'
        : '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';

void _settings(BuildContext context, WidgetRef ref) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Consumer(builder: (ctx, ref, _) {
      final p = ctx.pal;
      final s = ref.watch(settingsProvider);
      final n = ref.read(settingsProvider.notifier);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
              child: Text('Transfer settings', style: Txt.title(p.ink)),
            ),
            SwitchTile(
              icon: Icons.pause_circle_outline_rounded,
              title: 'Hold new transfers',
              subtitle: 'Incoming offers are declined until you turn this off',
              value: ref.read(engineProvider).xferHeld,
              onChanged: (v) => ref.read(engineProvider).setXferHeld(v),
            ),
            SwitchTile(
              icon: Icons.download_done_rounded,
              title: 'Auto-accept from people you follow',
              subtitle: 'Files up to ${s.xferAutoMaxMb} MB start without asking. Everyone else still asks.',
              value: s.xferAutoAccept,
              onChanged: (v) => n.update((x) => x.copyWith(xferAutoAccept: v)),
            ),
            if (s.xferAutoAccept)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                child: Segmented<int>(
                  value: s.xferAutoMaxMb,
                  options: const {10: '10 MB', 50: '50 MB', 200: '200 MB', 1024: '1 GB'},
                  onChanged: (v) => n.update((x) => x.copyWith(xferAutoMaxMb: v)),
                ),
              ),
            SectionLabel('At the same time'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Segmented<int>(
                value: s.xferParallel,
                options: const {1: '1', 2: '2', 3: '3', 5: '5'},
                onChanged: (v) => n.update((x) => x.copyWith(xferParallel: v)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.lg),
              child: Text('Downloads beyond this wait in a queue and start as others finish.',
                  style: Txt.small(p.muted)),
            ),
          ],
        ),
      );
    }),
  );
}

class _XferTabs extends ConsumerStatefulWidget {
  const _XferTabs({required this.xfers});
  final List<FileTransfer> xfers;

  @override
  ConsumerState<_XferTabs> createState() => _XferTabsState();
}

class _XferTabsState extends ConsumerState<_XferTabs> {
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
        if (_tab == 1 && done.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: Space.md),
              child: TextButton(
                onPressed: () => ref.read(engineProvider).clearFinishedTransfers(),
                child: const Text('Clear list'),
              ),
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
    final picked = await pickFiles(e.media, context: context);
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
