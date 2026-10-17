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

class XferTile extends ConsumerWidget {
  const XferTile({super.key, required this.x});
  final FileTransfer x;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final name = e.nameOf(x.peer);
    final label = switch (x.state) {
      XferState.offer =>
        x.dir == XferDir.inbound ? 'waiting for you' : 'waiting for them',
      XferState.queued => 'queued, starts when a slot frees',
      XferState.active => 'moving',
      XferState.done => 'complete',
      XferState.failed => x.error ?? 'failed',
      XferState.declined => 'declined',
      XferState.cancelled => 'cancelled',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, 8),
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: x.state == XferState.active ? p.accent : p.line,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(fileIcon(x.media.mime), size: 20, color: p.inkSoft),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    x.media.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.bodyStrong(p.ink),
                  ),
                ),
                Text(
                  x.dir == XferDir.out ? 'out' : 'in',
                  style: Txt.mono(p.faint, size: 10.5),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '$name · ${bytes(x.media.size)} · $label',
              style: Txt.mono(p.muted, size: 11),
            ),
            const SizedBox(height: Space.sm),
            ProgressMeter(
              progress: x.progress,
              done: x.done,
              total: x.total,
              bps: x.bps,
            ),
            if (x.state == XferState.offer && x.dir == XferDir.inbound)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => e.respondTransfer(x.id, false),
                      child: const Text('Decline'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 34),
                      ),
                      onPressed: () => e.respondTransfer(x.id, true),
                      child: const Text('Receive'),
                    ),
                  ],
                ),
              ),
            if (x.moving)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => e.cancelTransfer(x.id),
                  child: Text('Cancel', style: Txt.small(p.danger)),
                ),
              ),
            if (x.state == XferState.done && x.dir == XferDir.inbound)
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () async {
                        final f = await e.media.saveToDevice(
                          x.media,
                          sources: [x.peer],
                        );
                        if (context.mounted)
                          toast(
                            context,
                            f == null ? 'Could not save' : 'Saved to ${f.path}',
                          );
                      },
                      child: const Text('Save to device'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final f = await e.media.export(
                          x.media,
                          sources: [x.peer],
                        );
                        if (f == null || !context.mounted) return;
                        await showLocalFile(context, f, name: x.media.name, mime: x.media.mime);
                      },
                      child: const Text('Open'),
                    ),
                  ],
                ),
              ),
            if (x.state == XferState.failed || x.state == XferState.cancelled)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => e.retryTransfer(x.id),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Retry'),
                ),
              ),
          ],
        ),
      ),
    );
  }
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
