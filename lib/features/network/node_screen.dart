import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/diagnostics.dart';
import '../../net/engine.dart';
import '../../net/engine_net.dart';
import '../../net/pay/coin.dart';
import '../../net/transport.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/spark.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';

/// Everything this device knows about one node: who it is to you, how the
/// two of you are connected right now, and what data flows between you.
class NodeScreen extends ConsumerStatefulWidget {
  const NodeScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<NodeScreen> createState() => _NodeScreenState();
}

class _NodeScreenState extends ConsumerState<NodeScreen> {
  bool _pinging = false;

  Future<void> _ping() async {
    final e = ref.read(maybeEngineProvider);
    if (e == null || _pinging) return;
    setState(() => _pinging = true);
    final ms = await e.ping(widget.id);
    if (!mounted) return;
    setState(() => _pinging = false);
    toast(context, ms == null ? 'No answer' : 'Round trip ${ms.toStringAsFixed(1)} ms');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final id = widget.id;
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const Scaffold(body: Loading());
    final peer = ref.watch(peerProvider(id)).value ?? Peer(id: id);
    final online = ref.watch(onlineProvider(id)).value ?? false;
    final status = ref.watch(netStatusProvider).value;
    final diag = ref.watch(diagnosticsProvider).value;
    final grants = ref.watch(grantsProvider).value ?? const <Grant>[];
    final link = status?.links.where((l) => l.peer == id).firstOrNull;
    final conn = diag?.connection(id);
    final pings = e.pingHistory(id);
    final labels = e.topicLabels();
    final shared = [
      for (final t in e.neighbors.entries)
        if (t.value.contains(id)) labels[t.key] ?? 'topic ${shortId(t.key)}',
    ];
    final theyKeep = grants.where((g) => g.peer == id && g.dir == GrantDir.out).toList();
    final iKeep = grants.where((g) => g.peer == id && g.dir == GrantDir.inbound).toList();
    final isMe = id == e.me.id;
    final heard = e.lastHeardFrom(id);

    return Scaffold(
      appBar: AppBar(
        title: Text(isMe ? 'This node' : 'Node'),
        actions: [
          if (!isMe)
            IconBtn(Icons.person_outline_rounded, tooltip: 'Profile', onTap: () => context.push('/u/$id')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: Row(
              children: [
                Avatar(id: id, size: 56),
                const SizedBox(width: Space.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isMe ? 'You' : peer.name, style: Txt.title(p.ink)),
                      const SizedBox(height: 2),
                      Text(alias(id), style: Txt.mono(p.muted, size: 11)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 4, children: [
                        _Chip(online ? 'online' : lastSeen(peer.lastSeen), on: online),
                        if (peer.iFollow) const _Chip('following'),
                        if (peer.followsMe) const _Chip('follows you'),
                        if (peer.blocked) const _Chip('blocked', danger: true),
                        if (peer.preserve) const _Chip('you keep their posts'),
                      ]),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SectionLabel('Route'),
          _RouteCard(link: link, conn: conn),
          if (!isMe) ...[
            SectionLabel(
              'Latency',
              trailing: TextButton.icon(
                onPressed: _pinging ? null : _ping,
                icon: _pinging
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_ping_rounded, size: 16),
                label: Text(_pinging ? 'Pinging' : 'Ping'),
              ),
            ),
            _PingChart(pings: pings),
          ],
          if (conn != null) ...[
            SectionLabel('Traffic on this connection'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: TechRows([
                ('sent', '${bytes(conn.txBytes)} in ${compact(conn.txDatagrams)} datagrams', copy: false),
                ('received', '${bytes(conn.rxBytes)} in ${compact(conn.rxDatagrams)} datagrams', copy: false),
                ('lost', '${conn.lostPackets} packets · ${bytes(conn.lostBytes)} (${(conn.lossRate * 100).toStringAsFixed(2)}%)', copy: false),
                ('opened by', conn.side == 'client' ? 'you dialed' : 'they dialed', copy: false),
                ('protocol', conn.alpn.isEmpty ? '—' : conn.alpn, copy: false),
                ('paths', '${conn.paths.length}', copy: false),
                ('known addrs', '${conn.knownAddrs.length}', copy: false),
                for (final a in conn.knownAddrs)
                  (a.active ? 'addr (active)' : 'addr', '${a.kind} · ${a.address}', copy: true),
              ]),
            ),
          ],
          SectionLabel('Ledger'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: TechRows(_ledgerRows(e, id, isMe)),
          ),
          SectionLabel('Profile'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: TechRows([
              ('name', isMe ? e.myProfile.displayName : peer.name, copy: false),
              if (peer.nickname != null && peer.nickname!.isNotEmpty) ('nickname', peer.nickname!, copy: false),
              ('bio', (isMe ? e.myProfile.bio : peer.profile?.bio ?? '').isEmpty ? '—' : (isMe ? e.myProfile.bio : peer.profile!.bio), copy: false),
              ('discoverable', (isMe ? e.myProfile.discoverable : peer.profile?.discoverable == true) ? 'yes' : 'no', copy: false),
              ('keep posts', (isMe ? e.myProfile.keepPosts : peer.profile?.keepPosts == true) ? 'followers may keep' : 'off', copy: false),
              ('profile signed', peer.profile == null && !isMe ? 'not on this phone' : timeAgo(isMe ? e.myProfile.ts : peer.profile!.ts), copy: false),
              ('blocked', peer.blocked ? 'yes' : 'no', copy: false),
            ]),
          ),
          SectionLabel('Where you meet'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: TechRows([
              ('gossip topics', shared.isEmpty ? 'none' : '${shared.length}', copy: false),
              for (final t in e.neighbors.entries)
                if (t.value.contains(id))
                  (labels[t.key] ?? 'topic', t.key, copy: true),
              for (final g in e.db.groups().where((g) => g.owner == id || g.members.contains(id)))
                ('group', g.name, copy: false),
              for (final s in e.spaces().where((s) => s.owner == id || s.roles.containsKey(id)))
                ('space', '${s.name}${s.public ? ' · public' : ''}', copy: false),
            ]),
          ),
          if (!isMe) ...[
            SectionLabel('From them, in memory'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: _Recent(items: e.liveItems().where((i) => i.author == id).take(6).toList()),
            ),
          ],
          SectionLabel('Data between you'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: TechRows([
              ('live here', '${e.liveItemsFrom(id)} items in memory (gone when they leave)', copy: false),
              ('kept here', '${e.keptByAuthor()[id] ?? 0} items stored with consent', copy: false),
              ('they keep', theyKeep.isEmpty ? 'nothing of yours' : theyKeep.map((g) => _scopeName(g.scope)).join(', '), copy: false),
              ('you keep', iKeep.isEmpty ? 'nothing of theirs' : iKeep.map((g) => _scopeName(g.scope)).join(', '), copy: false),
              ('last heard', heard == 0 ? 'not this session' : timeAgo(heard), copy: false),
              ('gossip', shared.isEmpty ? 'no shared topics' : shared.join('\n'), copy: false),
            ]),
          ),
          SectionLabel('Identity'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: TechRows([
              ('node id', id, copy: true),
              ('key', 'Ed25519 public key, 32 bytes', copy: false),
              ('encoding', 'lowercase hex, 64 characters', copy: false),
              if (isMe) ('home relay', e.preferredRelay ?? status?.relayUrl ?? 'none pinned', copy: true),
              if (isMe) ('topics joined', '${e.topicCount}', copy: false),
              if (isMe) ('engine', status?.engine ?? '—', copy: false),
              if (isMe) ('running', status?.running == true ? 'yes' : 'no', copy: false),
              if (peer.addr != null) ('last ticket', peer.addr!, copy: true),
              if (peer.profile != null) ('profile', 'signed ${timeAgo(peer.profile!.ts)} ago', copy: false),
            ]),
          ),
          if (!isMe)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
              child: Row(
                children: [
                  Expanded(child: OutlinedButton(onPressed: () => context.push('/chat/$id'), child: const Text('Chat'))),
                  const SizedBox(width: Space.sm),
                  Expanded(child: OutlinedButton(onPressed: () => context.push('/transfer/$id'), child: const Text('Send files'))),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        await e.reconnect();
                        if (context.mounted) toast(context, 'Dialing');
                      },
                      child: const Text('Reconnect'),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _scopeName(String scope) => switch (Scope.type(scope)) {
      'dm' => 'chat',
      'feed' => 'posts',
      'story' => 'stories',
      'sfeed' => 'space posts',
      'gdm' => 'group chat',
      final t => t,
    };

List<(String, String, {bool copy})> _ledgerRows(Engine e, String id, bool isMe) {
  final coin = e.coin;
  if (coin == null) return [('ledger', 'not open on this phone', copy: false)];
  final chain = coin.view().chains[id] ?? const [];
  final withMe = coin.history(id).where((t) => !t.isMint && (t.from == e.me.id || t.to == e.me.id)).toList();
  var sent = 0;
  var got = 0;
  for (final t in withMe) {
    if (t.from == e.me.id && t.to == id) sent += t.amount;
    if (t.to == e.me.id && t.from == id) got += t.amount;
  }
  return [
    ('balance', '${Coin.format(coin.balance(id))} Mentos', copy: false),
    ('chain', chain.isEmpty ? 'no payments seen' : '${chain.length} signed ${chain.length == 1 ? 'entry' : 'entries'}', copy: false),
    ('tip', chain.isEmpty ? '—' : chain.last.hash, copy: chain.isNotEmpty),
    if (!isMe) ('you sent them', Coin.format(sent), copy: false),
    if (!isMe) ('they sent you', Coin.format(got), copy: false),
    if (!isMe) ('payments between you', '${withMe.length}', copy: false),
    ('topic', Coin.topicLabel, copy: false),
  ];
}

class _Recent extends StatelessWidget {
  const _Recent({required this.items});
  final List<Item> items;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    if (items.isEmpty) {
      return Text('Nothing of theirs is sitting in memory. Kept items are counted above.', style: Txt.small(p.muted));
    }
    return Column(
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 72, child: Text(item.e.kind, style: Txt.mono(p.faint, size: 11))),
                Expanded(
                  child: Text(
                    _snippet(item),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.mono(p.ink, size: 11.5),
                  ),
                ),
                Text(timeAgo(item.ts), style: Txt.mono(p.muted, size: 11)),
              ],
            ),
          ),
      ],
    );
  }
}

String _snippet(Item item) {
  final text = item.body['text'];
  if (text is String && text.trim().isNotEmpty) return text.trim();
  final name = item.body['name'];
  if (name is String && name.isNotEmpty) return name;
  return item.id;
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {this.on = false, this.danger = false});
  final String text;
  final bool on;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final fg = danger ? p.danger : (on ? p.accent : p.muted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: danger ? p.dangerSoft : (on ? p.accentSoft : p.raised),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(text, style: Txt.mono(fg, size: 10.5, w: FontWeight.w500)),
    );
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({required this.link, required this.conn});
  final LinkInfo? link;
  final ConnStats? conn;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final sel = conn?.selected;
    final kind = sel?.kind ?? switch (link?.kind) {
      LinkKind.direct => 'direct',
      LinkKind.relay => 'relay',
      LinkKind.mixed => 'direct',
      _ => null,
    };
    final paths = conn?.paths ?? const <PathStats>[];
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
              const _End(label: 'you'),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      kind == null ? 'no live path' : (kind == 'direct' ? 'direct QUIC' : 'via relay'),
                      style: Txt.mono(kind == 'direct' ? p.accent : p.muted, size: 11, w: FontWeight.w500),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(child: Container(height: 2, color: kind == null ? p.line : (kind == 'direct' ? p.accent : p.inkSoft))),
                        if (kind == 'relay')
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(border: Border.all(color: p.line), borderRadius: BorderRadius.circular(4)),
                            child: Text(relayName(sel?.address ?? ''), style: Txt.mono(p.muted, size: 9.5)),
                          ),
                        if (kind == 'relay') Expanded(child: Container(height: 2, color: p.inkSoft)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      sel != null ? '${sel.rttMs.toStringAsFixed(1)} ms rtt' : (link?.latencyMs != null ? '${link!.latencyMs} ms rtt' : ' '),
                      style: Txt.mono(p.faint, size: 10.5),
                    ),
                  ],
                ),
              ),
              const _End(label: 'them'),
            ],
          ),
          if (paths.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            for (final path in paths)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(path.selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                        size: 13, color: path.selected ? p.accent : p.faint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('${path.kind} · ${path.address}', style: Txt.mono(p.ink, size: 10.5), overflow: TextOverflow.ellipsis),
                    ),
                    Text('${path.rttMs.toStringAsFixed(0)} ms · cwnd ${bytes(path.cwnd)}', style: Txt.mono(p.muted, size: 10)),
                  ],
                ),
              ),
          ] else if (link != null)
            for (final path in link!.paths)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${path.selected ? '● ' : '○ '}${path.kind.name} · ${path.address}', style: Txt.mono(p.ink, size: 10.5)),
              ),
        ],
      ),
    );
  }
}

class _End extends StatelessWidget {
  const _End({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: p.line), color: p.raised),
      child: Text(label, style: Txt.mono(p.inkSoft, size: 10)),
    );
  }
}

class _PingChart extends StatelessWidget {
  const _PingChart({required this.pings});
  final List<({int at, double? ms})> pings;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final ok = [for (final x in pings) ?x.ms];
    if (pings.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
        child: Text('Ping measures a fresh round trip over the path in use.', style: Txt.small(p.muted)),
      );
    }
    final lost = pings.length - ok.length;
    final avg = ok.isEmpty ? 0.0 : ok.reduce((a, b) => a + b) / ok.length;
    final min = ok.isEmpty ? 0.0 : ok.reduce((a, b) => a < b ? a : b);
    final max = ok.isEmpty ? 0.0 : ok.reduce((a, b) => a > b ? a : b);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (ok.length >= 2) SparkLine(points: ok, height: 72),
          const SizedBox(height: Space.sm),
          Text(
            ok.isEmpty
                ? '${pings.length} pings, none answered'
                : 'last ${ok.last.toStringAsFixed(1)} · avg ${avg.toStringAsFixed(1)} · min ${min.toStringAsFixed(1)} · max ${max.toStringAsFixed(1)} ms'
                    '${lost > 0 ? ' · $lost lost' : ''}',
            style: Txt.mono(p.muted, size: 11),
          ),
        ],
      ),
    );
  }
}
