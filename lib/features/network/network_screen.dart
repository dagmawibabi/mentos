import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/transport.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';
import 'network_mesh.dart';

class NetworkScreen extends ConsumerWidget {
  const NetworkScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const SizedBox.shrink();
    final status = ref.watch(netStatusProvider).value;
    final grants = ref.watch(grantsProvider).value ?? const <Grant>[];
    ref.watch(peopleProvider);
    final tiers = e.tierCounts();
    final keptBy = e.keptByAuthor();
    final online = e.onlinePeers.toList();
    final links = {for (final l in status?.links ?? const <LinkInfo>[]) l.peer: l};

    final keepers = <String, List<Grant>>{};
    for (final g in grants.where((g) => g.dir == GrantDir.out)) {
      keepers.putIfAbsent(g.peer, () => []).add(g);
    }
    final preserved = e.people().where((x) => x.preserve).toList();
    final custody = grants.where((g) => g.dir == GrantDir.inbound && g.state == GrantState.active).toList();
    final spacesKept = e.spaces().where((s) => s.preserve && s.archive).toList();

    final running = !e.held && (status?.running ?? false);
    final busy = e.connecting;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: Space.gutter,
        title: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: running ? p.accent : p.danger),
            ),
            const SizedBox(width: 8),
            Text(running ? 'Online' : 'Offline', style: Txt.bodyStrong(running ? p.accent : p.ink)),
          ],
        ),
        actions: [
          IconBtn(Icons.hub_outlined, tooltip: 'Iroh network', onTap: () {
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const IrohNetworkPage()));
          }),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: busy ? null : (running ? e.disconnectNode : e.connectNode),
            child: Text(busy ? 'Connecting' : running ? 'Disconnect' : 'Connect'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        color: p.ink,
        onRefresh: e.reconnect,
        child: ListView(
          padding: const EdgeInsets.only(bottom: Space.xxl),
          children: [
            NetworkMesh(
              me: e.me.id,
              peers: online,
              links: links,
              relays: status?.relays ?? const [],
              homeRelay: status?.relayUrl,
              running: status?.running ?? false,
            ),
            _NodeCard(status: status, id: e.me.id),
            SectionLabel('Where data lives on this phone'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Row(
                children: [
                  _Tier(value: tiers.owned, label: 'yours', hint: 'created here', tag: Provenance.mine),
                  const SizedBox(width: Space.sm),
                  _Tier(value: tiers.kept, label: 'kept', hint: 'others\' with consent', tag: Provenance.kept),
                  const SizedBox(width: Space.sm),
                  _Tier(value: tiers.live, label: 'live', hint: 'in memory only', tag: Provenance.live),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
              child: Text(
                'Live items vanish when their author goes offline. Kept items stay until the author revokes '
                'consent or you stop keeping them.',
                style: Txt.mono(p.faint, size: 11),
              ),
            ),
            DefaultTabController(
              length: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TabBar(tabs: [
                    Tab(text: 'Connected now'),
                    Tab(text: 'You keep'),
                    Tab(text: 'Keep you'),
                  ]),
                  SizedBox(
                    height: 320,
                    child: TabBarView(
                      children: [
                        ListView(
                          children: [
                            if (online.isEmpty)
                              _Hint(status?.running ?? false
                                  ? 'No one reachable right now. Contacts connect automatically when they come online.'
                                  : 'Your node isn\'t running, so nobody can reach you.')
                            else
                              for (final id in online)
                                _PeerRow(
                                  id: id,
                                  subtitle: [
                                    _linkLabel(links[id]),
                                    if (e.peerBps(id) > 0) speed(e.peerBps(id)),
                                  ].join(' · '),
                                  live: true,
                                ),
                          ],
                        ),
                        ListView(
                          children: [
                            if (custody.isEmpty && preserved.isEmpty && spacesKept.isEmpty)
                              _Hint('Nothing from anyone else is stored here.')
                            else ...[
                              for (final g in custody)
                                _PeerRow(
                                  id: g.peer,
                                  subtitle: '${_scopeLabel(g.scope, e.me.id)} · ${keptBy[g.peer] ?? 0} items',
                                  action: TextButton(
                                    onPressed: () => e.dropTheirs(g.scope),
                                    child: Text('Stop', style: Txt.small(p.danger)),
                                  ),
                                ),
                              for (final x in preserved)
                                _PeerRow(
                                  id: x.id,
                                  subtitle: 'public posts · ${keptBy[x.id] ?? 0} items',
                                  action: TextButton(
                                    onPressed: () => e.setPreserve(x.id, false),
                                    child: Text('Stop', style: Txt.small(p.danger)),
                                  ),
                                ),
                              for (final s in spacesKept)
                                ListTile(
                                  leading: Icon(Icons.grid_view_rounded, color: p.inkSoft),
                                  title: Text(s.name),
                                  subtitle: Text('space history', style: Txt.mono(p.muted, size: 11)),
                                  onTap: () => context.push('/s/${s.id}/settings'),
                                ),
                            ],
                          ],
                        ),
                        ListView(
                          children: [
                            if (keepers.isEmpty)
                              _Hint('No one. Everything you create exists only on this phone and is visible while you\'re online.')
                            else
                              for (final entry in keepers.entries)
                                _PeerRow(
                                  id: entry.key,
                                  subtitle: entry.value
                                      .map((g) =>
                                          '${_scopeLabel(g.scope, e.me.id)}${g.state == GrantState.pending ? ' (waiting)' : ''}')
                                      .join(' · '),
                                ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SectionLabel('Topics'),
            _Hint('${e.topicCount} gossip topics joined — one per space and per person you follow.'),
          ],
        ),
      ),
    );
  }

  static String _linkLabel(LinkInfo? l) {
    if (l == null) return 'via gossip';
    final kind = switch (l.kind) {
      LinkKind.direct => 'direct',
      LinkKind.relay => 'relayed',
      LinkKind.mixed => 'direct + relay',
      LinkKind.none => 'connecting',
    };
    return l.latencyMs == null ? kind : '$kind · ${l.latencyMs} ms';
  }
}

String _scopeLabel(String scope, String me) {
  final t = Scope.type(scope);
  return switch (t) {
    'dm' => 'chat',
    'feed' => 'posts',
    'story' => 'stories',
    'chan' => 'channel',
    'sfeed' => 'space posts',
    _ => t,
  };
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({required this.status, required this.id});
  final NetStatus? status;
  final String id;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final s = status;
    final running = s?.running ?? false;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Space.gutter),
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: running ? p.accent : p.danger),
              ),
              const SizedBox(width: 8),
              Text(running ? 'Node online' : 'Node offline', style: Txt.bodyStrong(p.ink)),
              const Spacer(),
              Text(s?.engine ?? '—', style: Txt.mono(p.muted, size: 11)),
            ],
          ),
          const SizedBox(height: Space.md),
          _KV('node id', id, copy: true),
          _KV(
            'relays',
            s == null || s.relays.isEmpty
                ? (s?.relayUrl ?? (running ? 'searching n0 relays…' : '—'))
                : s.relays.map((u) => u.replaceAll(RegExp(r'/$'), '').replaceAll(RegExp(r'\.$'), '')).join('\n'),
          ),
          _KV('home', s?.relayUrl ?? '—'),
          _KV('addresses', s == null || s.directAddrs.isEmpty ? '—' : s.directAddrs.take(3).join('\n')),
          _KV('encryption', 'QUIC · TLS 1.3 · Ed25519'),
        ],
      ),
    );
  }
}

class _KV extends StatelessWidget {
  const _KV(this.k, this.v, {this.copy = false});
  final String k;
  final String v;
  final bool copy;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: copy
            ? () {
                Clipboard.setData(ClipboardData(text: v));
                toast(context, 'Copied');
              }
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 86, child: Text(k, style: Txt.mono(p.faint, size: 11))),
            Expanded(
              child: Text(
                copy && v.length > 24 ? '${v.substring(0, 20)}…${v.substring(v.length - 8)}' : v,
                style: Txt.mono(p.ink, size: 11.5),
              ),
            ),
            if (copy) Icon(Icons.copy_rounded, size: 13, color: p.faint),
          ],
        ),
      ),
    );
  }
}

class _Tier extends StatelessWidget {
  const _Tier({required this.value, required this.label, required this.hint, required this.tag});
  final int value;
  final String label;
  final String hint;
  final Provenance tag;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProvenanceTag(tag, compact: true),
            const SizedBox(height: Space.sm),
            Text('$value', style: Txt.title(p.ink)),
            Text(hint, style: Txt.mono(p.muted, size: 10)),
          ],
        ),
      ),
    );
  }
}

class _PeerRow extends ConsumerWidget {
  const _PeerRow({required this.id, required this.subtitle, this.action, this.live = false});
  final String id;
  final String subtitle;
  final Widget? action;
  final bool live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final name = ref.watch(peerProvider(id)).value?.name ?? alias(id);
    return ListTile(
      leading: Avatar(id: id, size: 36),
      title: Text(name),
      subtitle: Text(subtitle, style: Txt.mono(live ? p.accent : p.muted, size: 11)),
      trailing: action,
      onTap: () => showPeerTech(context, id),
      onLongPress: () => context.push('/u/$id'),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 4),
        child: Text(text, style: Txt.small(context.pal.muted)),
      );
}
