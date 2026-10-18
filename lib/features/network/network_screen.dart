import 'package:flutter/material.dart';
import '../plugins/plugins_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/diagnostics.dart';
import '../../net/transport.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';
import 'atlas_screen.dart';
import 'network_mesh.dart';

/// The live network: who this phone is linked to right now, and the relays
/// it can go through. Custody, node details and privacy live on their own pages.
class NetworkScreen extends ConsumerWidget {
  const NetworkScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const SizedBox.shrink();
    final status = ref.watch(netStatusProvider).value;
    final diag = ref.watch(diagnosticsProvider).value;
    ref.watch(peopleProvider);
    ref.watch(atlasTickProvider);
    final online = e.onlinePeers.toList();
    final links = {for (final l in status?.links ?? const <LinkInfo>[]) l.peer: l};
    final running = !e.held && (status?.running ?? false);
    final busy = e.connecting;
    final direct = links.values.where((l) => l.kind == LinkKind.direct || l.kind == LinkKind.mixed).length;

    final best = diag?.report?.bestLatency ?? const <String, double>{};
    final atlasRelays = {for (final r in e.atlas?.relays() ?? const []) r.url: r};
    final urls = <String>{
      ...best.keys,
      ...?status?.relays,
      if (status?.relayUrl != null) status!.relayUrl!,
      if (e.preferredRelay != null) e.preferredRelay!,
      ...atlasRelays.keys,
    }.toList()
      ..sort((a, b) => (best[a] ?? 1e9).compareTo(best[b] ?? 1e9));
    final worst = best.values.isEmpty ? 0.0 : best.values.reduce((a, b) => a > b ? a : b);

    online.sort((a, b) => (links[a]?.latencyMs ?? 1 << 30).compareTo(links[b]?.latencyMs ?? 1 << 30));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: Space.gutter,
        title: Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(shape: BoxShape.circle, color: running ? p.accent : p.danger),
            ),
            const SizedBox(width: 8),
            Text(busy ? 'Connecting…' : (running ? 'Online' : 'Offline'), style: Txt.title(running ? p.ink : p.muted)),
          ],
        ),
        actions: [
          IconBtn(Icons.travel_explore_rounded, tooltip: 'Network atlas', onTap: () => context.push('/atlas')),
          IconBtn(Icons.monitor_heart_outlined, tooltip: 'Diagnostics', onTap: () => context.push('/diagnostics')),
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 4),
            child: running
                ? OutlinedButton(
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: busy ? null : e.disconnectNode,
                    child: const Text('Disconnect'),
                  )
                : FilledButton(
                    style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: busy ? null : e.connectNode,
                    child: Text(busy ? 'Connecting' : 'Connect'),
                  ),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: p.ink,
        onRefresh: () async {
          ref.invalidate(diagnosticsProvider);
          await e.reconnect();
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: Space.xxl),
          children: [
            const PluginSlotView('network.top'),
            NetworkMesh(
              me: e.me.id,
              peers: online,
              links: links,
              relays: status?.relays ?? const [],
              homeRelay: status?.relayUrl,
              running: status?.running ?? false,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Container(
                decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: p.line)),
                clipBehavior: Clip.antiAlias,
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Stat(Icons.link_rounded, '${online.length}', 'Linked', p.accent),
                      VerticalDivider(width: 1, thickness: 1, color: p.line),
                      _Stat(Icons.bolt_rounded, '$direct', 'Direct', const Color(0xFFE0A100)),
                      VerticalDivider(width: 1, thickness: 1, color: p.line),
                      _Stat(
                        Icons.public_rounded,
                        '${(e.atlas?.nodes().length ?? 0) + 1}',
                        'On network',
                        const Color(0xFF3A7CA5),
                        onTap: () => context.push('/atlas'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SectionLabel('Active connections', trailing: Text('${online.length}', style: Txt.mono(p.muted, size: 11))),
            if (online.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                child: Container(
                  padding: const EdgeInsets.all(Space.lg),
                  decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: p.line)),
                  child: Row(
                    children: [
                      Icon(running ? Icons.hourglass_empty_rounded : Icons.cloud_off_rounded, color: p.muted),
                      const SizedBox(width: Space.md),
                      Expanded(
                        child: Text(
                          running
                              ? 'No one reachable right now. Contacts connect automatically when they come online.'
                              : 'Your node is off, so nobody can reach you. Tap Connect.',
                          style: Txt.small(p.muted),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              for (final id in online) _ConnRow(id: id, link: links[id], bps: e.peerBps(id)),
            SectionLabel(
              'Relays',
              trailing: Text(e.preferredRelay == null ? 'automatic' : 'pinned', style: Txt.mono(p.muted, size: 11)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xs),
              child: Text(
                'Relays introduce phones and carry encrypted traffic when no direct path exists. '
                'Use one to send new connections through it.',
                style: Txt.small(p.muted),
              ),
            ),
            if (urls.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.sm),
                child: Text(running ? 'Measuring relays…' : 'Connect to see relays.', style: Txt.small(p.muted)),
              ),
            for (final u in urls)
              RelayRow(
                url: u,
                ms: best[u],
                nodes: atlasRelays[u]?.nodes.length ?? 0,
                home: status?.relayUrl == u,
                pinned: e.preferredRelay == u,
                worst: worst,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xs, Space.gutter, 0),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.add_link_rounded, size: 18),
                      label: const Text('Add a relay'),
                      onPressed: () => _addRelay(context, ref),
                    ),
                  ),
                  if (e.preferredRelay != null) ...[
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.autorenew_rounded, size: 18),
                        label: const Text('Automatic'),
                        onPressed: () => useRelay(context, ref, e.preferredRelay!),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SectionLabel('More'),
            _Link(Icons.inventory_2_outlined, 'Who holds what', 'Copies you keep for others, and who keeps yours', () => context.push('/custody')),
            _Link(Icons.shield_outlined, 'Privacy and transports', switch (e.settings.privacy) {
              'relay' => 'Hide my IP',
              'tor' => 'Tor',
              _ => 'Standard',
            }, () => context.push('/diagnostics?tab=privacy')),
            _Link(Icons.memory_rounded, 'This node', 'Id, addresses and gossip topics', () => context.push('/diagnostics?tab=node')),
          ],
        ),
      ),
    );
  }

  Future<void> _addRelay(BuildContext context, WidgetRef ref) async {
    final url = await prompt(
      context,
      title: 'Relay',
      body: 'New connections dial this relay. Paste the full address, for example a relay you run yourself.',
      hint: 'https://',
      action: 'Use relay',
      maxLength: 200,
      allowEmpty: false,
      keyboard: TextInputType.url,
      capitalization: TextCapitalization.none,
      validate: (v) {
        final u = Uri.tryParse(v.trim());
        if (u == null || (u.scheme != 'https' && u.scheme != 'http') || u.host.isEmpty) return 'Start with https:// and a host';
        return null;
      },
    );
    if (url == null || url.trim().isEmpty || !context.mounted) return;
    useRelay(context, ref, url.trim());
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.value, this.label, this.tint, {this.onTap});
  final IconData icon;
  final String value;
  final String label;
  final Color tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.sm, Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(color: tint.withValues(alpha: .14), borderRadius: BorderRadius.circular(8)),
                      child: Icon(icon, size: 15, color: tint),
                    ),
                    const Spacer(),
                    if (onTap != null) Icon(Icons.chevron_right_rounded, size: 16, color: p.faint),
                  ],
                ),
                const SizedBox(height: Space.sm),
                Text(value, style: Txt.heading(p.ink).copyWith(fontSize: 22, height: 1.1, fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(height: 2),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted).copyWith(fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnRow extends ConsumerWidget {
  const _ConnRow({required this.id, required this.link, required this.bps});
  final String id;
  final LinkInfo? link;
  final int bps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final name = ref.watch(peerProvider(id)).value?.name ?? alias(id);
    final (route, color) = switch (link?.kind) {
      LinkKind.direct => ('Direct', p.accent),
      LinkKind.mixed => ('Direct + relay', p.accent),
      LinkKind.relay => ('Relayed', const Color(0xFFF59E0B)),
      LinkKind.none => ('Connecting', p.muted),
      null => ('Via gossip', p.muted),
    };
    final relay = link?.paths.where((x) => x.selected && x.kind == LinkKind.relay).firstOrNull;
    return InkWell(
      onTap: () => context.push('/node/$id'),
      onLongPress: () => showPeerTech(context, id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 9),
        child: Row(
          children: [
            Avatar(id: id, size: 40),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(p.ink)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                        decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(Radii.pill)),
                        child: Text(route, style: Txt.mono(color, size: 10.5, w: FontWeight.w500)),
                      ),
                      if (relay != null) ...[
                        const SizedBox(width: 6),
                        Flexible(child: Text(relayName(relay.address), maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted))),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(link?.latencyMs == null ? '—' : '${link!.latencyMs} ms', style: Txt.mono(p.ink, size: 12, w: FontWeight.w500)),
                if (bps > 0) Text(speed(bps), style: Txt.mono(p.muted, size: 10.5)),
              ],
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: p.faint),
          ],
        ),
      ),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link(this.icon, this.title, this.subtitle, this.onTap);
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => RowTile(icon: icon, title: title, subtitle: subtitle, onTap: onTap);
}
