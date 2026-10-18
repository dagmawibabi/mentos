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

enum _Show { active, requests, done, problems }

/// Files moving straight between phones: what is in flight, what waits for
/// an answer, and what already arrived.
class TransfersScreen extends ConsumerStatefulWidget {
  const TransfersScreen({super.key});

  @override
  ConsumerState<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends ConsumerState<TransfersScreen> {
  _Show _show = _Show.active;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.watch(engineProvider);
    final xfers = ref.watch(transfersProvider).value ?? const <FileTransfer>[];
    final people = (ref.watch(peopleProvider).value ?? const <Peer>[]).where((x) => !x.blocked).toList();
    final online = e.onlinePeers;
    people.sort((a, b) {
      final ao = online.contains(a.id) ? 0 : 1, bo = online.contains(b.id) ? 0 : 1;
      return ao != bo ? ao.compareTo(bo) : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    final requests = xfers.where((x) => x.state == XferState.offer && x.dir == XferDir.inbound).toList();
    final active = xfers.where((x) => x.moving && !requests.contains(x)).toList();
    final done = xfers.where((x) => x.state == XferState.done).toList();
    final problems = xfers.where((x) => x.failed).toList();
    final moving = xfers.where((x) => x.state == XferState.active).toList();
    final paused = xfers.where((x) => x.state == XferState.paused).length;
    final speed = moving.fold<int>(0, (a, x) => a + x.bps);
    final left = moving.fold<int>(0, (a, x) => a + (x.total - x.done).clamp(0, 1 << 40));
    final received = done.where((x) => x.dir == XferDir.inbound).fold<int>(0, (a, x) => a + x.total);
    final sent = done.where((x) => x.dir == XferDir.out).fold<int>(0, (a, x) => a + x.total);
    final list = switch (_show) {
      _Show.active => active,
      _Show.requests => requests,
      _Show.done => done,
      _Show.problems => problems,
    };

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
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            child: Container(
              padding: const EdgeInsets.all(Space.lg),
              decoration: BoxDecoration(
                color: moving.isEmpty ? p.surface : p.accentSoft,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: moving.isEmpty ? p.line : p.accent.withValues(alpha: .4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(moving.isEmpty ? Icons.swap_horiz_rounded : Icons.swap_vert_rounded,
                          color: moving.isEmpty ? p.inkSoft : p.accent),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          moving.isEmpty
                              ? (requests.isEmpty ? 'Nothing moving' : '${requests.length} waiting for you')
                              : '${moving.length} moving · ${speed > 0 ? '${bytes(speed)}/s' : 'starting'}',
                          style: Txt.heading(p.ink),
                        ),
                      ),
                    ],
                  ),
                  if (moving.isNotEmpty && speed > 0 && left > 0) ...[
                    const SizedBox(height: 2),
                    Text('About ${_eta(left ~/ speed)} left for ${bytes(left)}', style: Txt.small(p.inkSoft)),
                  ],
                  const SizedBox(height: Space.md),
                  Row(
                    children: [
                      _Stat('Received', bytes(received)),
                      _Stat('Sent', bytes(sent)),
                      _Stat('Files', '${done.length}'),
                    ],
                  ),
                  if (active.isNotEmpty || problems.isNotEmpty) ...[
                    const SizedBox(height: Space.md),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (moving.isNotEmpty || active.any((x) => x.state == XferState.queued))
                          _Bulk(Icons.pause_rounded, 'Pause all', e.pauseAllTransfers),
                        if (paused > 0) _Bulk(Icons.play_arrow_rounded, 'Resume all', e.resumeAllTransfers),
                        if (problems.any((x) => x.state == XferState.failed))
                          _Bulk(Icons.refresh_rounded, 'Retry failed', e.retryFailedTransfers),
                        if (active.isNotEmpty)
                          _Bulk(Icons.stop_rounded, 'Cancel all', () async {
                            final ok = await confirm(context,
                                title: 'Cancel every transfer?', body: 'Downloads stop and senders are told.', action: 'Cancel all', danger: true);
                            if (ok) await e.cancelAllTransfers();
                          }),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          SectionLabel('Send to', trailing: Text('${people.where((x) => online.contains(x.id)).length} online', style: Txt.mono(p.muted, size: 11))),
          if (people.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Text('Add someone first, then send a file while they are reachable.', style: Txt.small(p.muted)),
            )
          else
            SizedBox(
              height: 92,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                itemCount: people.length,
                separatorBuilder: (_, _) => const SizedBox(width: Space.md),
                itemBuilder: (_, i) {
                  final x = people[i];
                  final on = online.contains(x.id);
                  return GestureDetector(
                    onTap: () => context.push('/transfer/${x.id}'),
                    child: SizedBox(
                      width: 64,
                      child: Column(
                        children: [
                          Opacity(opacity: on ? 1 : .55, child: Avatar(id: x.id, size: 54)),
                          const SizedBox(height: 6),
                          Text(x.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(on ? p.ink : p.muted)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, Space.sm),
            child: Segmented<_Show>(
              value: _show,
              options: {
                _Show.active: 'Moving${active.isEmpty ? '' : ' ${active.length}'}',
                _Show.requests: 'Asks${requests.isEmpty ? '' : ' ${requests.length}'}',
                _Show.done: 'Done${done.isEmpty ? '' : ' ${done.length}'}',
                _Show.problems: 'Issues${problems.isEmpty ? '' : ' ${problems.length}'}',
              },
              onChanged: (v) => setState(() => _show = v),
            ),
          ),
          if ((_show == _Show.done || _show == _Show.problems) && list.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: Space.md),
                child: TextButton(onPressed: e.clearFinishedTransfers, child: const Text('Clear finished')),
              ),
            ),
          if (list.isEmpty)
            EmptyState(
              icon: switch (_show) {
                _Show.active => Icons.swap_horiz_rounded,
                _Show.requests => Icons.mark_email_unread_outlined,
                _Show.done => Icons.inventory_2_outlined,
                _Show.problems => Icons.check_circle_outline_rounded,
              },
              title: switch (_show) {
                _Show.active => 'Nothing moving',
                _Show.requests => 'No one is waiting on you',
                _Show.done => 'No finished transfers',
                _Show.problems => 'No problems',
              },
              compact: true,
            )
          else
            for (final x in list) XferTile(x: x),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Txt.bodyStrong(p.ink)),
          Text(label, style: Txt.small(p.muted)),
        ],
      ),
    );
  }
}

class _Bulk extends StatelessWidget {
  const _Bulk(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ActionChip(
    avatar: Icon(icon, size: 16),
    label: Text(label),
    onPressed: onTap,
  );
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
              child: Text('Downloads beyond this wait in a queue and start as others finish. Mark one "Start next" to jump the line.',
                  style: Txt.small(p.muted)),
            ),
          ],
        ),
      );
    }),
  );
}

/// Sending to one person, with everything you two have exchanged.
class PeerTransferScreen extends ConsumerStatefulWidget {
  const PeerTransferScreen({super.key, required this.peer});
  final String peer;

  @override
  ConsumerState<PeerTransferScreen> createState() => _PeerTransferScreenState();
}

class _PeerTransferScreenState extends ConsumerState<PeerTransferScreen> {
  bool _busy = false;

  Future<void> _send({bool photos = false}) async {
    final e = ref.read(engineProvider);
    final picked = photos ? await pickImages(context: context, limit: 20) : await pickFiles(e.media, context: context);
    if (picked.isEmpty) return;
    setState(() => _busy = true);
    try {
      for (final f in picked) {
        final ref = await importPending(e, f, scope: Scope.dm(e.me.id, widget.peer));
        await e.offerTransfer(widget.peer, ref);
        e.notifyFiles();
      }
    } catch (err) {
      if (mounted) toast(context, '$err');
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
    final e = ref.read(engineProvider);
    final bps = e.peerBps(widget.peer);
    final path = switch (link?.kind) {
      LinkKind.direct => 'Direct QUIC',
      LinkKind.relay => 'Through a relay',
      LinkKind.mixed => 'Direct + relay',
      _ => online ? 'Reachable' : 'Offline',
    };
    final moving = mine.where((x) => x.moving).toList();
    final history = mine.where((x) => !x.moving).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(person?.name ?? alias(widget.peer)),
        actions: [
          IconBtn(Icons.chat_bubble_outline_rounded, tooltip: 'Chat', onTap: () => context.push('/chat/${widget.peer}')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: Container(
              padding: const EdgeInsets.all(Space.lg),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: p.line),
              ),
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
                        Row(
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: online ? p.accent : p.faint),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                [
                                  path,
                                  if (link?.latencyMs != null) '${link!.latencyMs} ms',
                                  if (bps > 0) speed(bps),
                                  if (!online) lastSeen(person?.lastSeen ?? 0),
                                ].join(' · '),
                                style: Txt.small(online ? p.inkSoft : p.muted),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline_rounded, size: 15, color: p.faint),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    'Each file is encrypted on this phone and fetched by theirs. Nothing passes through a server; '
                    'if one of you goes offline, the file waits.',
                    style: Txt.small(p.muted),
                  ),
                ),
              ],
            ),
          ),
          if (moving.isNotEmpty) ...[
            SectionLabel('Moving now', trailing: Text('${moving.length}', style: Txt.mono(p.muted, size: 11))),
            for (final x in moving) XferTile(x: x, showPeer: false),
          ],
          SectionLabel('Shared with ${person?.name ?? 'them'}', trailing: Text('${history.length}', style: Txt.mono(p.muted, size: 11))),
          if (history.isEmpty)
            const EmptyState(icon: Icons.folder_open_rounded, title: 'Nothing exchanged yet', compact: true)
          else
            for (final x in history) XferTile(x: x, showPeer: false),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy || !online ? null : () => _send(photos: true),
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('Photos'),
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: _busy || !online ? null : _send,
                  icon: const Icon(Icons.upload_rounded, size: 18),
                  label: Text(_busy ? 'Preparing…' : online ? 'Send files' : 'They need to be online'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
