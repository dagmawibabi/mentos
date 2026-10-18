import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/atlas.dart';
import '../../net/diagnostics.dart';
import '../../net/transport.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

/// Ticks whenever a beacon arrives.
final atlasTickProvider = StreamProvider.autoDispose<int>((ref) {
  final a = ref.watch(maybeEngineProvider)?.atlas;
  if (a == null) return Stream.value(0);
  var n = 0;
  return Stream.multi((out) {
    out.add(n);
    final sub = a.changes.listen((_) => out.add(++n));
    out.onCancel = sub.cancel;
  });
});

/// Pins new dials to [url] (or clears the pin) and says so.
void useRelay(BuildContext context, WidgetRef ref, String url) {
  final e = ref.read(engineProvider);
  final clear = e.preferredRelay == url;
  e.preferRelay(clear ? null : url);
  toast(context, clear ? 'Back to automatic relay choice' : 'New connections go through ${relayName(url)}');
}

/// Every node and relay this phone has heard of, network wide.
class AtlasScreen extends ConsumerStatefulWidget {
  const AtlasScreen({super.key});

  @override
  ConsumerState<AtlasScreen> createState() => _AtlasScreenState();
}

class _AtlasScreenState extends ConsumerState<AtlasScreen> {
  bool _relays = false;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    ref.watch(atlasTickProvider);
    ref.watch(peopleProvider);
    final status = ref.watch(netStatusProvider).value;
    final diag = ref.watch(diagnosticsProvider).value;
    final atlas = e?.atlas;
    if (e == null || atlas == null) return const Scaffold(body: Loading());
    final links = {for (final l in status?.links ?? const <LinkInfo>[]) l.peer: l};
    final online = e.onlinePeers;
    final beacons = {for (final b in atlas.nodes()) b.id: b};
    // Nodes: everyone who announced, plus contacts and live links.
    final ids = <String>{...beacons.keys, ...e.people().map((x) => x.id), ...online}..remove(e.me.id);
    final q = _q.toLowerCase();
    final nodes = ids.where((id) => q.isEmpty || '${e.nameOf(id)} $id ${beacons[id]?.relay ?? ''}'.toLowerCase().contains(q)).toList()
      ..sort((a, b) {
        final ao = online.contains(a) ? 0 : 1, bo = online.contains(b) ? 0 : 1;
        if (ao != bo) return ao.compareTo(bo);
        return (beacons[b]?.ts ?? 0).compareTo(beacons[a]?.ts ?? 0);
      });
    // Relays: from beacons, this node's status and the latency probes.
    final best = diag?.report?.bestLatency ?? const <String, double>{};
    final byRelay = {for (final r in atlas.relays()) r.url: r};
    final urls = <String>{...byRelay.keys, ...best.keys, ...?status?.relays, if (status?.relayUrl != null) status!.relayUrl!}
        .where((u) => q.isEmpty || u.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => (best[a] ?? 1e9).compareTo(best[b] ?? 1e9));
    final tor = beacons.values.where((b) => b.mode == 'tor').length;
    final hidden = beacons.values.where((b) => b.mode == 'relay').length;

    return Scaffold(
      appBar: AppBar(title: const Text('Network atlas')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            child: Container(
              padding: const EdgeInsets.all(Space.lg),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  colors: p.isDark ? const [Color(0xFF10251D), Color(0xFF0E1211)] : const [Color(0xFF0D1110), Color(0xFF1C2A25)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('MENTOS NETWORK', style: Txt.mono(p.accent, size: 11, w: FontWeight.w500).copyWith(letterSpacing: 1.6)),
                  const SizedBox(height: Space.md),
                  Row(
                    children: [
                      _Big('${beacons.length + 1}', 'nodes heard'),
                      _Big('${urls.length}', 'relays'),
                      _Big('${online.length}', 'linked now'),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    'Nodes announce a signed beacon with their home relay, never an IP address. '
                    '${tor > 0 || hidden > 0 ? '$hidden hide their IP, $tor use Tor. ' : ''}'
                    'Beacons older than a day drop off.',
                    style: Txt.small(Colors.white70),
                  ),
                ],
              ),
            ),
          ),
          SwitchTile(
            icon: Icons.campaign_outlined,
            title: 'Announce this node',
            subtitle: 'Others see your node id and home relay in their atlas',
            value: atlas.announcing,
            onChanged: (v) => setState(() => atlas.announcing = v),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 0),
            child: TextField(
              onChanged: (v) => setState(() => _q = v.trim()),
              decoration: InputDecoration(
                hintText: 'Search by name, id or relay',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: p.raised,
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.sm),
            child: Segmented<bool>(
              value: _relays,
              options: {false: 'Nodes (${nodes.length})', true: 'Relays (${urls.length})'},
              onChanged: (v) => setState(() => _relays = v),
            ),
          ),
          if (!_relays) ...[
            if (nodes.isEmpty)
              const EmptyState(icon: Icons.travel_explore_rounded, title: 'No other nodes yet', body: 'Beacons arrive as your node joins the network.', compact: true),
            for (final id in nodes) _NodeRow(id: id, beacon: beacons[id], link: links[id], online: online.contains(id)),
          ] else ...[
            if (urls.isEmpty)
              const EmptyState(icon: Icons.cell_tower_rounded, title: 'No relays known yet', compact: true),
            for (final u in urls)
              _RelayRow(
                url: u,
                ms: best[u],
                nodes: byRelay[u]?.nodes.length ?? 0,
                home: status?.relayUrl == u,
                pinned: e.preferredRelay == u,
              ),
          ],
        ],
      ),
    );
  }
}

class _Big extends StatelessWidget {
  const _Big(this.value, this.label);
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: Txt.title(Colors.white).copyWith(fontSize: 26)),
        Text(label, style: Txt.small(Colors.white60)),
      ],
    ),
  );
}

class _NodeRow extends ConsumerWidget {
  const _NodeRow({required this.id, required this.beacon, required this.link, required this.online});
  final String id;
  final Beacon? beacon;
  final LinkInfo? link;
  final bool online;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final known = e.db.peer(id) != null;
    final route = switch (link?.kind) {
      LinkKind.direct => 'direct',
      LinkKind.relay => 'relayed',
      LinkKind.mixed => 'direct + relay',
      _ => online ? 'reachable' : null,
    };
    final b = beacon;
    return InkWell(
      onTap: () => context.push('/node/$id'),
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: id));
        toast(context, 'Node id copied');
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 10),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Avatar(id: id, size: 40, presence: false),
                if (online)
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle, border: Border.all(color: p.bg, width: 2)),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          known ? e.nameOf(id) : '${id.substring(0, 8)}…${id.substring(58)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: known ? Txt.bodyStrong(p.ink) : Txt.mono(p.ink, size: 13, w: FontWeight.w500),
                        ),
                      ),
                      if (b != null && b.mode != 'standard') ...[
                        const SizedBox(width: 6),
                        _Tag(b.mode == 'tor' ? 'Tor' : 'IP hidden'),
                      ],
                      if (!known) ...[
                        const SizedBox(width: 6),
                        const _Tag('stranger'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      ?route,
                      if (link?.latencyMs != null) '${link!.latencyMs} ms',
                      if (b != null && b.relay.isNotEmpty) 'via ${relayName(b.relay)}',
                      if (b != null) '${b.links} links',
                      if (b != null) 'heard ${timeAgo(b.ts)}',
                      if (b == null && !online) 'not announcing',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.small(online ? p.inkSoft : p.muted),
                  ),
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

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Text(text, style: Txt.mono(p.muted, size: 10)),
    );
  }
}

/// A relay with its measured latency, how many nodes call it home, and a
/// button to send new connections through it.
class RelayRow extends ConsumerWidget {
  const RelayRow({super.key, required this.url, this.ms, this.nodes = 0, this.home = false, this.pinned = false, this.worst = 0});
  final String url;
  final double? ms;
  final int nodes;
  final bool home;
  final bool pinned;

  /// Slowest latency in the list, to scale the bar. 0 hides the bar.
  final double worst;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final quality = ms == null ? null : (ms! < 80 ? p.accent : (ms! < 200 ? const Color(0xFFF59E0B) : p.danger));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.sm, Space.md),
        decoration: BoxDecoration(
          color: pinned ? p.accentSoft : p.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: pinned ? p.accent.withValues(alpha: .5) : p.line),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.cell_tower_rounded, size: 19, color: home ? p.accent : p.inkSoft),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(relayName(url), maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(p.ink))),
                      if (home) ...[const SizedBox(width: 6), _Tag('home')],
                      if (pinned) ...[const SizedBox(width: 6), _Tag('pinned')],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      Uri.tryParse(url)?.host ?? url,
                      if (nodes > 0) '$nodes ${nodes == 1 ? 'node' : 'nodes'}',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.small(p.muted),
                  ),
                  if (worst > 0 && ms != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.pill),
                      child: LinearProgressIndicator(
                        value: (ms! / worst).clamp(.04, 1).toDouble(),
                        minHeight: 4,
                        color: quality,
                        backgroundColor: p.raised,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: Space.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(ms == null ? '—' : '${ms!.toStringAsFixed(0)} ms', style: Txt.mono(quality ?? p.muted, size: 12, w: FontWeight.w600)),
                const SizedBox(height: 4),
                TextButton(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: const Size(0, 30)),
                  onPressed: () => useRelay(context, ref, url),
                  child: Text(pinned ? 'Unpin' : 'Use'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RelayRow extends StatelessWidget {
  const _RelayRow({required this.url, required this.ms, required this.nodes, required this.home, required this.pinned});
  final String url;
  final double? ms;
  final int nodes;
  final bool home;
  final bool pinned;
  @override
  Widget build(BuildContext context) => RelayRow(url: url, ms: ms, nodes: nodes, home: home, pinned: pinned);
}
