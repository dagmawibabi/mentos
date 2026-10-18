import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../data/models.dart';
import '../state/providers.dart';
import 'media.dart';
import 'ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProgressMeter extends StatelessWidget {
  const ProgressMeter({
    super.key,
    required this.progress,
    this.done = 0,
    this.total = 0,
    this.bps = 0,
    this.label,
  });
  final double progress;
  final int done;
  final int total;
  final int bps;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: progress <= 0 || progress > 1 ? null : progress,
            minHeight: 6,
            backgroundColor: p.raised,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                [
                  if (label != null) label!,
                  if (total > 0) '${bytes(done)} / ${bytes(total)}',
                  if (bps > 0) speed(bps),
                ].join(' · '),
                style: Txt.mono(p.faint, size: 10.5),
              ),
            ),
            if (progress > 0 && progress <= 1)
              Text(
                '${(progress * 100).round()}%',
                style: Txt.mono(p.muted, size: 10.5),
              ),
          ],
        ),
      ],
    );
  }
}

/// One file moving to or from someone, with a preview when this phone has
/// the bytes and the controls that fit its state.
class XferTile extends ConsumerWidget {
  const XferTile({super.key, required this.x, this.showPeer = true});
  final FileTransfer x;
  final bool showPeer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final inbound = x.dir == XferDir.inbound;
    final (label, fg, bg) = switch (x.state) {
      XferState.offer => (inbound ? 'Wants to send' : 'Waiting for them', p.ink, p.raised),
      XferState.queued => (x.priority ? 'Next in line' : 'Queued', p.inkSoft, p.raised),
      XferState.active => (inbound ? 'Receiving' : 'Sending', p.accent, p.accentSoft),
      XferState.paused => ('Paused', p.inkSoft, p.raised),
      XferState.done => (inbound ? 'Received' : 'Sent', p.accent, p.accentSoft),
      XferState.failed => ('Failed', p.danger, p.dangerSoft),
      XferState.declined => ('Declined', p.muted, p.raised),
      XferState.cancelled => ('Cancelled', p.muted, p.raised),
    };
    final when = x.finished ?? x.started;
    final eta = x.state == XferState.active && x.bps > 0 && x.total > x.done
        ? _eta((x.total - x.done) ~/ x.bps)
        : null;

    Future<void> open() async {
      final f = inbound
          ? await e.media.export(x.media, sources: [x.peer])
          : (e.media.cached(x.media) ?? await e.media.export(x.media));
      if (!context.mounted) return;
      if (f == null) {
        toast(context, 'The file is not on this phone any more');
        return;
      }
      await showLocalFile(context, f, name: x.media.name, mime: x.media.mime);
    }

    final actions = <Widget>[
      if (x.state == XferState.offer && inbound) ...[
        _Act('Decline', Icons.close_rounded, () => e.respondTransfer(x.id, false)),
        _Act('Receive', Icons.download_rounded, () => e.respondTransfer(x.id, true), primary: true),
      ],
      if (x.state == XferState.queued && inbound)
        _Act(x.priority ? 'Not first' : 'Start next', Icons.vertical_align_top_rounded, () => e.prioritizeTransfer(x.id)),
      if ((x.state == XferState.active || x.state == XferState.queued) && inbound)
        _Act('Pause', Icons.pause_rounded, () => e.pauseTransfer(x.id)),
      if (x.state == XferState.paused)
        _Act('Resume', Icons.play_arrow_rounded, () => e.resumeTransfer(x.id), primary: true),
      if (x.moving && !(x.state == XferState.offer && inbound))
        _Act('Cancel', Icons.stop_rounded, () => e.cancelTransfer(x.id), danger: true),
      if (x.state == XferState.done) ...[
        _Act('Open', Icons.visibility_outlined, open, primary: true),
        if (inbound)
          _Act('Save', Icons.save_alt_rounded, () async {
            final f = await e.media.saveToDevice(x.media, sources: [x.peer]);
            if (context.mounted) toast(context, f == null ? 'Could not save' : 'Saved to ${f.path}');
          }),
      ],
      if (x.state == XferState.failed || x.state == XferState.cancelled)
        _Act('Retry', Icons.refresh_rounded, () => e.retryTransfer(x.id), primary: true),
      if (!x.moving || x.state == XferState.paused)
        _Act('Remove', Icons.delete_outline_rounded, () => e.removeTransfer(x.id)),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 6, Space.gutter, 6),
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: x.state == XferState.active ? p.accent.withValues(alpha: .6) : p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: x.state == XferState.done ? open : null,
                  child: _XferThumb(x: x),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(x.media.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(p.ink)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(inbound ? Icons.south_west_rounded : Icons.north_east_rounded, size: 12, color: p.muted),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              [
                                if (showPeer) '${inbound ? 'from' : 'to'} ${e.nameOf(x.peer)}',
                                bytes(x.media.size),
                                timeAgo(when),
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Txt.small(p.muted),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.sm),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
                  child: Text(label, style: Txt.mono(fg, size: 10.5, w: FontWeight.w500)),
                ),
              ],
            ),
            if (x.state == XferState.active || x.state == XferState.queued || x.state == XferState.paused) ...[
              const SizedBox(height: Space.md),
              ProgressMeter(
                progress: x.state == XferState.queued ? -1 : x.progress,
                done: x.done,
                total: x.total,
                bps: x.bps,
                label: eta == null ? null : '$eta left',
              ),
            ],
            if (x.state == XferState.failed && x.error != null && x.error != 'cancelled') ...[
              const SizedBox(height: 6),
              Text(x.error!, style: Txt.small(p.danger)),
            ],
            if (x.state == XferState.paused) ...[
              const SizedBox(height: 4),
              Text('Resuming starts the file again from the beginning.', style: Txt.small(p.faint)),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Wrap(spacing: 6, runSpacing: 6, alignment: WrapAlignment.end, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}

String _eta(int seconds) => seconds < 60
    ? '${seconds}s'
    : seconds < 3600
        ? '${seconds ~/ 60}m ${seconds % 60}s'
        : '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';

class _Act extends StatelessWidget {
  const _Act(this.label, this.icon, this.onTap, {this.primary = false, this.danger = false});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final fg = primary ? p.accentInk : (danger ? p.danger : p.ink);
    return Material(
      color: primary ? p.accent : p.raised,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.pill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 5),
              Text(label, style: Txt.small(fg).copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A photo preview once this phone holds the bytes; otherwise a type icon.
class _XferThumb extends ConsumerWidget {
  const _XferThumb({required this.x});
  final FileTransfer x;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final file = x.media.isImage ? e.media.cached(x.media) : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 52,
        height: 52,
        child: file != null
            ? Image.file(file, fit: BoxFit.cover, errorBuilder: (_, _, _) => _icon(p))
            : _icon(p),
      ),
    );
  }

  Widget _icon(Palette p) => Container(
    color: x.media.isImage || x.media.isVideo ? p.accentSoft : p.raised,
    alignment: Alignment.center,
    child: Icon(
      x.media.isVideo ? Icons.play_circle_outline_rounded : fileIcon(x.media.mime),
      size: 24,
      color: x.media.isImage || x.media.isVideo ? p.accent : p.inkSoft,
    ),
  );
}

class AlertHost extends StatelessWidget {
  const AlertHost({super.key, required this.child, required this.router});
  final Widget child;
  final GoRouter router;

  @override
  Widget build(BuildContext context) {
    // Banners listen on their own. Rebuilding this stack to show one would
    // mount the navigator, which carries a GlobalKey, twice in one child list.
    return Stack(
      children: [
        KeyedSubtree(
          key: const ValueKey<String>('alert-host-content'),
          child: child,
        ),
        Positioned(
          key: const ValueKey<String>('alert-host-banners'),
          left: 12,
          right: 12,
          top: 0,
          child: _AlertLayer(router: router),
        ),
      ],
    );
  }
}

class _AlertLayer extends ConsumerStatefulWidget {
  const _AlertLayer({required this.router});
  final GoRouter router;

  @override
  ConsumerState<_AlertLayer> createState() => _AlertLayerState();
}

class _AlertLayerState extends ConsumerState<_AlertLayer> {
  String _path = '/';
  bool _routeQueued = false;

  @override
  void initState() {
    super.initState();
    _path = _currentPath();
    widget.router.routerDelegate.addListener(_onRoute);
  }

  @override
  void didUpdateWidget(covariant _AlertLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router == widget.router) return;
    oldWidget.router.routerDelegate.removeListener(_onRoute);
    widget.router.routerDelegate.addListener(_onRoute);
    _path = _currentPath();
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_onRoute);
    super.dispose();
  }

  String _currentPath() =>
      widget.router.routerDelegate.currentConfiguration.uri.path;

  void _onRoute() {
    if (_routeQueued) return;
    _routeQueued = true;
    // The delegate notifies while the navigator under this host is still
    // building. setState here marks the element dirty mid-rebuild, which
    // fails the navigator and replaces the screen with the error placeholder.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeQueued = false;
      if (!mounted) return;
      final latest = _currentPath();
      if (latest == _path) return;
      setState(() => _path = latest);
    });
  }

  @override
  Widget build(BuildContext context) {
    final alerts = ref.watch(alertsProvider).value ?? const <Alert>[];
    final path = _path.isEmpty ? '/' : _path;
    final visible = <Alert>[];
    final covered = <String>[];
    for (final a in alerts) {
      if (_alertAlreadyHere(a, path)) {
        covered.add(a.id);
      } else {
        visible.add(a);
      }
    }
    if (covered.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final e = ref.read(maybeEngineProvider);
        if (e == null) return;
        for (final id in covered) {
          e.dismissAlert(id);
        }
      });
    }
    if (visible.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 8),
      child: Column(
        children: [
          for (final a in visible.take(3))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _Banner(a: a, router: widget.router),
            ),
        ],
      ),
    );
  }
}

/// True when [path] is already the screen this banner would interrupt.
bool _alertAlreadyHere(Alert a, String path) {
  final route = a.route;
  if (route != null && route.isNotEmpty) {
    final target = Uri.tryParse(route)?.path ?? route;
    if (path == target || (target != '/' && path.startsWith('$target/')))
      return true;
  }
  if (a.kind == 'xfer' && (path == '/files' || path.startsWith('/transfer')))
    return true;

  final scope = a.scope;
  if (scope == null || scope.isEmpty) return false;
  final parts = scope.split(':');
  if (parts.isEmpty) return false;
  switch (parts.first) {
    case 'dm':
      if (!path.startsWith('/chat/') || parts.length < 3) return false;
      final peer = Uri.decodeComponent(
        path.substring('/chat/'.length).split('/').first,
      );
      return peer == parts[1] || peer == parts[2];
    case 'gdm':
      return parts.length >= 2 &&
          (path == '/g/${parts[1]}' || path.startsWith('/g/${parts[1]}/'));
    case 'forum':
      return parts.length >= 3 && path == '/s/${parts[1]}/f/${parts[2]}';
    case 'chan':
      return parts.length >= 3 &&
          (path == '/s/${parts[1]}/c/${parts[2]}' ||
              path == '/ch/${parts[1]}/${parts[2]}');
    case 'post':
      return parts.length >= 3 && path == '/post/${parts[2]}';
    default:
      return false;
  }
}

class _Banner extends ConsumerWidget {
  const _Banner({required this.a, required this.router});
  final Alert a;
  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    return Material(
      color: p.surface,
      elevation: 8,
      shadowColor: Colors.black45,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        onTap: a.route == null
            ? null
            : () {
                e.dismissAlert(a.id);
                router.push(a.route!);
              },
        borderRadius: BorderRadius.circular(Radii.md),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              Icon(switch (a.kind) {
                'xfer' => Icons.swap_horiz_rounded,
                'invite' => Icons.group_add_outlined,
                'file' => Icons.attach_file_rounded,
                _ => Icons.notifications_none_rounded,
              }, color: p.ink),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.title, style: Txt.bodyStrong(p.ink)),
                    Text(
                      a.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Txt.small(p.muted),
                    ),
                    if (a.progress != null) ...[
                      const SizedBox(height: 6),
                      ProgressMeter(progress: a.progress!, bps: a.bps ?? 0),
                    ],
                  ],
                ),
              ),
              if (a.cancelId != null)
                TextButton(
                  onPressed: () => e.cancelTransfer(a.cancelId!),
                  child: Text('Stop', style: Txt.small(p.danger)),
                ),
              IconBtn(
                Icons.close_rounded,
                size: 18,
                color: p.muted,
                onTap: () => e.dismissAlert(a.id),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
