import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/diagnostics.dart';
import '../../net/engine_net.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';
import 'privacy_screen.dart';

/// Everything the iroh node knows about this network, in plain words first
/// and raw numbers underneath.
class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key, this.tab});

  /// overview | connections | node | privacy
  final String? tab;

  static const _tabs = ['overview', 'connections', 'node', 'privacy'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    final async = ref.watch(diagnosticsProvider);
    final status = ref.watch(netStatusProvider).value;
    final d = async.value;

    Widget waiting() => e == null
        ? const Loading()
        : !e.hasDiagnostics
            ? const EmptyState(
                icon: Icons.portable_wifi_off_rounded,
                title: 'No network library',
                body: 'This build runs without the iroh node, so there is nothing to measure.',
              )
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(Space.xl),
                  child: Text(
                    _measuringText(loading: async.isLoading, running: status?.running == true),
                    style: Txt.small(p.muted),
                    textAlign: TextAlign.center,
                  ),
                ),
              );

    return DefaultTabController(
      length: _tabs.length,
      initialIndex: _tabs.indexOf(tab ?? 'overview').clamp(0, _tabs.length - 1),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Network diagnostics'),
          actions: [
            IconBtn(Icons.refresh_rounded, tooltip: 'Re-check network', onTap: () {
              e?.networkChanged();
              ref.invalidate(diagnosticsProvider);
              toast(context, 'Asked iroh to re-probe the network');
            }),
            IconBtn(Icons.ios_share_rounded, tooltip: 'Share report', onTap: () async {
              if (e == null) return;
              final report = await e.diagnosticsReport();
              await SharePlus.instance.share(ShareParams(text: report, subject: 'Mentos network report'));
            }),
            const SizedBox(width: 8),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [Tab(text: 'Overview'), Tab(text: 'Connections'), Tab(text: 'This node'), Tab(text: 'Privacy')],
          ),
        ),
        body: TabBarView(
          children: [
            d == null
                ? waiting()
                : ListView(
                    padding: const EdgeInsets.only(bottom: Space.xxl),
                    children: [
                      _Summary(d: d),
                      SectionLabel('Reachability'),
                      _ReachGrid(d: d),
                      SectionLabel('Relays', trailing: Text('latency', style: Txt.mono(p.faint, size: 10))),
                      _RelayBars(d: d),
                    ],
                  ),
            d == null
                ? waiting()
                : d.connections.isEmpty
                    ? const EmptyState(icon: Icons.link_off_rounded, title: 'No open connections', body: 'QUIC connections appear here while peers are linked.')
                    : ListView(
                        padding: const EdgeInsets.only(top: Space.sm, bottom: Space.xxl),
                        children: [for (final c in d.connections) _ConnTile(c: c)],
                      ),
            ListView(
              padding: const EdgeInsets.only(bottom: Space.xxl),
              children: [
                SectionLabel('Identity'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                  child: TechRows([
                    ('node id', status?.nodeId ?? e?.me.id ?? '—', copy: true),
                    ('engine', status?.engine ?? 'offline', copy: false),
                    ('encryption', 'QUIC · TLS 1.3 · Ed25519', copy: false),
                  ]),
                ),
                SectionLabel('Addresses'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                  child: TechRows([
                    ('home relay', status?.relayUrl ?? 'none yet', copy: status?.relayUrl != null),
                    ('relays', (status?.relays ?? const []).isEmpty ? '—' : status!.relays.join('\n'), copy: false),
                    ('advertised', status == null || status.directAddrs.isEmpty ? 'no IP addresses' : status.directAddrs.join('\n'), copy: false),
                    if (d != null) ('sockets', d.bound.isEmpty ? 'none bound (no IP transport)' : d.bound.join('\n'), copy: false),
                  ]),
                ),
                SectionLabel('Transport'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                  child: TechRows([
                    if (d != null) ('privacy', _privacyLabel(d.privacy), copy: false),
                    if (d?.proxy != null) ('proxy', d!.proxy!, copy: true),
                    ('topics', '${d?.topics ?? status?.topics ?? 0} gossip topics, one per space and person you follow', copy: false),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.travel_explore_rounded, size: 18),
                    label: const Text('Open the network atlas'),
                    onPressed: () => context.push('/atlas'),
                  ),
                ),
              ],
            ),
            const PrivacyPanel(),
          ],
        ),
      ),
    );
  }
}

String _measuringText({required bool loading, required bool running}) {
  if (!running) return 'The node is not running. Connect it from the Network tab.';
  if (loading) return 'Measuring…';
  return 'The measurement did not finish. Tap refresh to try again.';
}

String _privacyLabel(String p) => switch (p) {
      'relay' => 'hide my IP (relay only)',
      'tor' => 'tor (relay only, via proxy)',
      _ => 'standard (direct + relay)',
    };

class _Summary extends StatelessWidget {
  const _Summary({required this.d});
  final NetDiagnostics d;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final lines = explain(d);
    final ok = d.relays.any((r) => r.connected);
    return Container(
      margin: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: ok ? p.accentSoft : p.dangerSoft,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded, size: 20, color: ok ? p.accent : p.danger),
              const SizedBox(width: Space.sm),
              Expanded(child: Text(ok ? 'Reachable through iroh' : 'Not reachable yet', style: Txt.bodyStrong(p.ink))),
            ],
          ),
          const SizedBox(height: Space.sm),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('• $l', style: Txt.small(p.inkSoft)),
            ),
        ],
      ),
    );
  }
}

class _ReachGrid extends StatelessWidget {
  const _ReachGrid({required this.d});
  final NetDiagnostics d;

  @override
  Widget build(BuildContext context) {
    final r = d.report;
    final nat = switch (r?.nat) {
      NatKind.easy => 'easy',
      NatKind.hard => 'hard',
      NatKind.blocked => 'no UDP',
      _ => 'unknown',
    };
    final cells = [
      ('UDP v4', r == null ? '—' : (r.udpV4 ? 'works' : 'blocked'), r?.udpV4 ?? false),
      ('UDP v6', r == null ? '—' : (r.udpV6 ? 'works' : 'blocked'), r?.udpV6 ?? false),
      ('NAT', nat, r?.nat == NatKind.easy),
      ('Portal', r?.captivePortal == null ? '—' : (r!.captivePortal! ? 'maybe' : 'none'), r?.captivePortal == false),
      ('Public v4', r?.globalV4 ?? '—', r?.globalV4 != null),
      ('Public v6', r?.globalV6 ?? '—', r?.globalV6 != null),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
      child: LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - Space.sm) / 2;
        return Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [for (final x in cells) SizedBox(width: w, child: _Cell(label: x.$1, value: x.$2, good: x.$3))],
        );
      }),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.value, required this.good});
  final String label;
  final String value;
  final bool good;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return GestureDetector(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: value));
        toast(context, 'Copied');
      },
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.md), border: Border.all(color: p.line)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: good ? p.accent : p.faint),
                ),
                const SizedBox(width: 6),
                Text(label, style: Txt.mono(p.muted, size: 10.5)),
              ],
            ),
            const SizedBox(height: 4),
            Text(value, style: Txt.mono(p.ink, size: 12, w: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _RelayBars extends StatelessWidget {
  const _RelayBars({required this.d});
  final NetDiagnostics d;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final best = d.report?.bestLatency ?? const <String, double>{};
    final urls = {...best.keys, for (final r in d.relays) r.url}.toList()
      ..sort((a, b) => (best[a] ?? 1e9).compareTo(best[b] ?? 1e9));
    if (urls.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
        child: Text('No relay measurements yet.', style: Txt.small(p.muted)),
      );
    }
    final worst = best.values.isEmpty ? 1.0 : best.values.reduce((a, b) => a > b ? a : b);
    return Column(
      children: [
        for (final u in urls)
          InkWell(
            onTap: () => showRelayTech(context, url: u, home: d.relays.any((r) => r.url == u)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 74,
                    child: Text(relayName(u), style: Txt.mono(p.ink, size: 11.5, w: FontWeight.w500)),
                  ),
                  Expanded(
                    child: LayoutBuilder(builder: (context, c) {
                      final ms = best[u];
                      final frac = ms == null ? 0.0 : (ms / worst).clamp(0.04, 1.0);
                      final home = d.relays.where((r) => r.url == u).firstOrNull;
                      return Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          Container(height: 8, decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(4))),
                          Container(
                            height: 8,
                            width: c.maxWidth * frac,
                            decoration: BoxDecoration(
                              color: home != null ? (home.connected ? p.accent : p.danger) : p.inkSoft,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      );
                    }),
                  ),
                  SizedBox(
                    width: 74,
                    child: Text(
                      best[u] == null ? '—' : '${best[u]!.toStringAsFixed(0)} ms',
                      textAlign: TextAlign.right,
                      style: Txt.mono(p.muted, size: 11),
                    ),
                  ),
                ],
              ),
            ),
          ),
        for (final r in d.relays.where((r) => r.error != null))
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 4, Space.gutter, 0),
            child: Text('${relayName(r.url)}: ${r.error}', style: Txt.mono(p.danger, size: 11)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
          child: Text(
            'Green is your home relay (where others find you). Bars are the best of HTTPS and UDP probes.',
            style: Txt.mono(p.faint, size: 10.5),
          ),
        ),
      ],
    );
  }
}

class _ConnTile extends ConsumerWidget {
  const _ConnTile({required this.c});
  final ConnStats c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final name = ref.watch(peerProvider(c.peer)).value?.name ?? alias(c.peer);
    final sel = c.selected;
    final route = sel == null ? 'no path' : '${sel.kind} · ${sel.rttMs.toStringAsFixed(0)} ms';
    return ListTile(
      leading: Avatar(id: c.peer, size: 34),
      title: Text(name),
      subtitle: Text(
        '$route · ↑${bytes(c.txBytes)} ↓${bytes(c.rxBytes)}${c.lostPackets > 0 ? ' · ${c.lostPackets} lost' : ''}',
        style: Txt.mono(sel?.kind == 'direct' ? p.accent : p.muted, size: 11),
      ),
      trailing: Text(c.alpn.replaceAll('/0', ''), style: Txt.mono(p.faint, size: 10)),
      onTap: () => context.push('/node/${c.peer}'),
    );
  }
}
