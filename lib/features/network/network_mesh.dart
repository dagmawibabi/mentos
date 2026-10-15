import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/transport.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/tech.dart';

class NetworkMesh extends StatelessWidget {
  const NetworkMesh({
    super.key,
    required this.me,
    required this.peers,
    required this.links,
    required this.relays,
    required this.homeRelay,
    required this.running,
    this.height = 240,
    this.interactive = false,
  });

  final String me;
  final List<String> peers;
  final Map<String, LinkInfo> links;
  final List<String> relays;
  final String? homeRelay;
  final bool running;
  final double height;
  final bool interactive;

  void _openFull(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NetworkMeshPage(
        me: me,
        peers: peers,
        links: links,
        relays: relays,
        homeRelay: homeRelay,
        running: running,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final child = _MeshCanvas(
      me: me,
      peers: peers,
      links: links,
      relays: relays,
      homeRelay: homeRelay,
      running: running,
      interactive: interactive,
    );
    if (interactive) {
      return InteractiveViewer(
        minScale: 0.6,
        maxScale: 4,
        boundaryMargin: const EdgeInsets.all(200),
        child: SizedBox(width: 720, height: 720, child: child),
      );
    }
    return GestureDetector(
      onTap: () => _openFull(context),
      child: Stack(
        children: [
          SizedBox(height: height, child: child),
        ],
      ),
    );
  }
}

class NetworkMeshPage extends ConsumerWidget {
  const NetworkMeshPage({
    super.key,
    required this.me,
    required this.peers,
    required this.links,
    required this.relays,
    required this.homeRelay,
    required this.running,
  });

  final String me;
  final List<String> peers;
  final Map<String, LinkInfo> links;
  final List<String> relays;
  final String? homeRelay;
  final bool running;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final status = ref.watch(netStatusProvider).value;
    final online = e.onlinePeers.toList();
    final liveLinks = {for (final l in status?.links ?? const <LinkInfo>[]) l.peer: l};
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        title: const Text('Mesh'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const IrohNetworkPage())),
            child: const Text('Iroh'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
            child: Text('Pinch to zoom. Drag to pan. Tap a node for its paths. Relays sit on the inner ring.', style: Txt.mono(p.faint, size: 11)),
          ),
          Expanded(
            child: NetworkMesh(
              me: me,
              peers: online.isEmpty ? peers : online,
              links: liveLinks.isEmpty ? links : liveLinks,
              relays: status?.relays ?? relays,
              homeRelay: status?.relayUrl ?? homeRelay,
              running: status?.running ?? running,
              interactive: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _MeshCanvas extends StatefulWidget {
  const _MeshCanvas({
    required this.me,
    required this.peers,
    required this.links,
    required this.relays,
    required this.homeRelay,
    required this.running,
    required this.interactive,
  });

  final String me;
  final List<String> peers;
  final Map<String, LinkInfo> links;
  final List<String> relays;
  final String? homeRelay;
  final bool running;
  final bool interactive;

  @override
  State<_MeshCanvas> createState() => _MeshCanvasState();
}

class _MeshCanvasState extends State<_MeshCanvas> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 4));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final shown = widget.peers.take(widget.interactive ? 24 : 10).toList();
    final relays = widget.relays.take(8).toList();
    return LayoutBuilder(builder: (context, c) {
      final center = Offset(c.maxWidth / 2, c.maxHeight / 2);
      final peerR = math.min(c.maxWidth, c.maxHeight) * 0.38;
      final relayR = peerR * 0.52;
      final peerPos = <String, Offset>{};
      for (var i = 0; i < shown.length; i++) {
        final a = -math.pi / 2 + i * 2 * math.pi / math.max(shown.length, 1);
        peerPos[shown[i]] = center + Offset(math.cos(a) * peerR, math.sin(a) * peerR);
      }
      final relayPos = <String, Offset>{};
      for (var i = 0; i < relays.length; i++) {
        final a = -math.pi / 2 + math.pi / 8 + i * 2 * math.pi / math.max(relays.length, 1);
        relayPos[relays[i]] = center + Offset(math.cos(a) * relayR, math.sin(a) * relayR);
      }
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, _) => CustomPaint(
                painter: _MeshPainter(
                  center: center,
                  peers: peerPos,
                  relays: relayPos,
                  home: widget.homeRelay,
                  links: widget.links,
                  p: p,
                  t: _c.value,
                  running: widget.running,
                ),
              ),
            ),
          ),
          Positioned(
            left: center.dx - 24,
            top: center.dy - 24,
            child: Avatar(id: widget.me, size: 48, presence: false),
          ),
          for (final e in relayPos.entries)
            Positioned(
              left: e.value.dx - 16,
              top: e.value.dy - 16,
              child: GestureDetector(
                onTap: () => showRelayTech(context, url: e.key, home: e.key == widget.homeRelay),
                child: _RelayDot(url: e.key, home: e.key == widget.homeRelay),
              ),
            ),
          for (final e in peerPos.entries)
            Positioned(
              left: e.value.dx - 17,
              top: e.value.dy - 17,
              child: GestureDetector(
                onTap: () => showPeerTech(context, e.key),
                onLongPress: () => context.push('/u/${e.key}'),
                child: Avatar(id: e.key, size: 34),
              ),
            ),
          if (shown.isEmpty && relays.isEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 14,
              child: Text(
                widget.running ? 'waiting for peers' : 'node offline',
                textAlign: TextAlign.center,
                style: Txt.mono(p.faint, size: 11),
              ),
            ),
        ],
      );
    });
  }
}

class _RelayDot extends StatelessWidget {
  const _RelayDot({required this.url, required this.home});
  final String url;
  final bool home;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final host = Uri.tryParse(url)?.host.replaceAll(RegExp(r'\.$'), '') ?? url;
    return Tooltip(
      message: host,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: home ? p.accent : p.surface,
          shape: BoxShape.circle,
          border: Border.all(color: home ? p.accent : p.line, width: 1.4),
        ),
        child: Icon(Icons.hub_outlined, size: 15, color: home ? p.bg : p.inkSoft),
      ),
    );
  }
}

class _MeshPainter extends CustomPainter {
  _MeshPainter({
    required this.center,
    required this.peers,
    required this.relays,
    required this.home,
    required this.links,
    required this.p,
    required this.t,
    required this.running,
  });

  final Offset center;
  final Map<String, Offset> peers;
  final Map<String, Offset> relays;
  final String? home;
  final Map<String, LinkInfo> links;
  final Palette p;
  final double t;
  final bool running;

  @override
  void paint(Canvas canvas, Size size) {
    final guide = Paint()
      ..color = p.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rPeer = peers.isEmpty ? 88.0 : (peers.values.first - center).distance;
    final rRelay = relays.isEmpty ? 50.0 : (relays.values.first - center).distance;
    canvas.drawCircle(center, rPeer, guide);
    canvas.drawCircle(center, rRelay, guide);

    if (running) {
      final pulse = Paint()
        ..color = p.accent.withValues(alpha: (1 - t) * .35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(center, 26 + t * 70, pulse);
    }

    final homePos = home != null ? relays[home!] : (relays.isEmpty ? null : relays.values.first);

    for (final e in peers.entries) {
      final l = links[e.key];
      final direct = l?.kind == LinkKind.direct || l?.kind == LinkKind.mixed;
      final paint = Paint()
        ..color = l == null ? p.faint : p.accent
        ..strokeWidth = direct ? 1.6 : 1.2;
      if (direct) {
        _line(canvas, center, e.value, paint);
      } else if (homePos != null) {
        _dashed(canvas, center, homePos, paint);
        _dashed(canvas, homePos, e.value, paint);
      } else {
        _dashed(canvas, center, e.value, paint);
      }
      final k = (t + (e.key.isEmpty ? 0 : e.key.codeUnitAt(0)) / 255) % 1;
      final along = direct || homePos == null
          ? Offset.lerp(center, e.value, k)!
          : k < 0.5
              ? Offset.lerp(center, homePos, k * 2)!
              : Offset.lerp(homePos, e.value, (k - 0.5) * 2)!;
      canvas.drawCircle(along, 2.2, Paint()..color = l == null ? p.faint : p.accent);
    }
  }

  void _line(Canvas canvas, Offset a, Offset b, Paint paint) {
    if ((b - a).distance < 1) return;
    canvas.drawLine(a, b, paint);
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final d = (b - a).distance;
    if (d < 1) return;
    final dir = (b - a) / d;
    for (var s = 0.0; s < d; s += 8) {
      canvas.drawLine(a + dir * s, a + dir * math.min(s + 4, d), paint);
    }
  }

  @override
  bool shouldRepaint(_MeshPainter old) => true;
}

/// Relays and people this node can actually see. There is no public directory.
class IrohNetworkPage extends ConsumerWidget {
  const IrohNetworkPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const SizedBox.shrink();
    final status = ref.watch(netStatusProvider).value;
    final people = ref.watch(peopleProvider).value ?? const [];
    final links = {for (final l in status?.links ?? const <LinkInfo>[]) l.peer: l};
    final online = e.onlinePeers;
    final known = {
      for (final person in people) person.id: person,
    };
    final ids = <String>{
      ...known.keys,
      ...online,
      ...links.keys,
    }..remove(e.me.id);

    return Scaffold(
      appBar: AppBar(title: const Text('Iroh network')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, 32),
        children: [
          Text('This node', style: Txt.heading(p.ink)),
          const SizedBox(height: 6),
          Text(
            'Relays forward encrypted packets when two phones cannot open a direct path. They do not store chats or posts. The list below is everyone this phone has met, plus anyone reachable right now.',
            style: Txt.small(p.muted),
          ),
          const SizedBox(height: 12),
          _CopyLine(label: 'node id', value: status?.nodeId ?? e.me.id),
          _CopyLine(label: 'home relay', value: status?.relayUrl ?? 'none'),
          _CopyLine(label: 'engine', value: status?.engine ?? 'offline'),
          for (final addr in status?.directAddrs ?? const <String>[]) _CopyLine(label: 'direct', value: addr),
          if ((status?.directAddrs ?? const []).isEmpty) _CopyLine(label: 'direct', value: 'no address yet'),
          const SizedBox(height: 22),
          Text('Relays', style: Txt.heading(p.ink)),
          const SizedBox(height: 6),
          if ((status?.relays ?? const []).isEmpty)
            Text('No relay is listed yet. Connect, then pull to refresh the network tab.', style: Txt.small(p.muted))
          else
            for (final relay in status!.relays) _CopyLine(label: 'relay', value: relay),
          const SizedBox(height: 22),
          Text('People', style: Txt.heading(p.ink)),
          const SizedBox(height: 6),
          if (ids.isEmpty)
            Text('Nobody else is known yet.', style: Txt.small(p.muted))
          else
            for (final id in ids.toList()..sort((a, b) {
                final ao = online.contains(a) ? 0 : 1;
                final bo = online.contains(b) ? 0 : 1;
                if (ao != bo) return ao.compareTo(bo);
                return e.nameOf(a).toLowerCase().compareTo(e.nameOf(b).toLowerCase());
              }))
              _PeerLine(
                id: id,
                name: known[id]?.name ?? e.nameOf(id),
                online: online.contains(id),
                kind: links[id]?.kind,
              ),
        ],
      ),
    );
  }
}

class _CopyLine extends StatelessWidget {
  const _CopyLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 88, child: Text(label, style: Txt.mono(p.faint, size: 11))),
            Expanded(child: Text(value, style: Txt.mono(p.ink, size: 12))),
          ],
        ),
      ),
    );
  }
}

class _PeerLine extends StatelessWidget {
  const _PeerLine({required this.id, required this.name, required this.online, required this.kind});
  final String id;
  final String name;
  final bool online;
  final LinkKind? kind;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final how = switch (kind) {
      LinkKind.direct => 'direct',
      LinkKind.relay => 'relay',
      LinkKind.mixed => 'direct + relay',
      LinkKind.none || null => online ? 'reachable' : 'known',
    };
    return InkWell(
      onTap: () => showPeerTech(context, id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Avatar(id: id, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(p.ink)),
                  Text(how, style: Txt.mono(online ? p.accent : p.muted, size: 11)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: p.faint),
          ],
        ),
      ),
    );
  }
}
