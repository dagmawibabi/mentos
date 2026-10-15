import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../data/models.dart';
import '../net/transport.dart';
import '../state/providers.dart';
import 'ui.dart';

void showPeerTech(BuildContext context, String id) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PeerTechSheet(id: id),
  );
}

void showRelayTech(BuildContext context, {required String url, required bool home}) {
  showModalBottomSheet(
    context: context,
    builder: (_) => _RelayTechSheet(url: url, home: home),
  );
}

void showScopeTech(BuildContext context, String scope, {String? peer, String? spaceId, String? groupId}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ScopeTechSheet(scope: scope, peer: peer, spaceId: spaceId, groupId: groupId),
  );
}

class TechRows extends StatelessWidget {
  const TechRows(this.rows, {super.key});
  final List<(String, String, {bool copy})> rows;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Column(
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GestureDetector(
              onTap: r.copy
                  ? () {
                      Clipboard.setData(ClipboardData(text: r.$2));
                      toast(context, 'Copied');
                    }
                  : null,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 92, child: Text(r.$1, style: Txt.mono(p.faint, size: 11))),
                  Expanded(child: Text(r.$2, style: Txt.mono(p.ink, size: 11.5))),
                  if (r.copy) Icon(Icons.copy_rounded, size: 13, color: p.faint),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _PeerTechSheet extends ConsumerWidget {
  const _PeerTechSheet({required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final peer = ref.watch(peerProvider(id)).value;
    final online = ref.watch(onlineProvider(id)).value ?? false;
    final status = ref.watch(netStatusProvider).value;
    final link = status?.links.where((l) => l.peer == id).firstOrNull;
    final live = e.liveItemsFrom(id);
    final kept = e.keptByAuthor()[id] ?? 0;
    final kind = switch (link?.kind) {
      LinkKind.direct => 'direct QUIC',
      LinkKind.relay => 'relayed QUIC',
      LinkKind.mixed => 'direct + relay',
      LinkKind.none => 'dialing',
      null => online ? 'gossip neighbor' : 'offline',
    };
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(peer?.name ?? alias(id), style: Txt.title(p.ink)),
            const SizedBox(height: 4),
            Text(online ? 'reachable now' : 'not on the mesh right now', style: Txt.mono(online ? p.accent : p.muted, size: 11)),
            const SizedBox(height: Space.lg),
            TechRows([
              ('node id', id, copy: true),
              ('link', kind, copy: false),
              ('rtt', link?.latencyMs == null ? '—' : '${link!.latencyMs} ms', copy: false),
              ('last seen', lastSeen(peer?.lastSeen ?? 0), copy: false),
              ('live items', '$live in memory here', copy: false),
              ('kept here', '$kept with consent', copy: false),
              ('follow', peer?.iFollow == true ? 'you follow' : (peer?.followsMe == true ? 'follows you' : 'not following'), copy: false),
              ('follows you', peer?.followsMe == true ? 'yes' : 'no', copy: false),
              ('preserve', peer?.preserve == true ? 'you keep their public posts' : 'off', copy: false),
              ('addr', peer?.addr ?? '—', copy: peer?.addr != null),
              for (final path in link?.paths ?? const <RoutePath>[])
                (
                  path.selected ? 'in use' : 'path',
                  '${path.kind.name} · ${path.address}${path.latencyMs == null ? '' : ' · ${path.latencyMs} ms'}',
                  copy: true,
                ),
            ]),
            Text(
              'A direct path is a QUIC link between the two phones. A relay path is an iroh relay forwarding ciphertext when NAT blocks a direct hole. Relays do not store posts or chats.',
              style: Txt.mono(p.faint, size: 11),
            ),
            const SizedBox(height: Space.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: () => context.push('/node/$id'), child: const Text('Details')),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: OutlinedButton(onPressed: () => context.push('/chat/$id'), child: const Text('Chat')),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: FilledButton(onPressed: () => context.push('/transfer/$id'), child: const Text('Files')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RelayTechSheet extends StatelessWidget {
  const _RelayTechSheet({required this.url, required this.home});
  final String url;
  final bool home;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final host = Uri.tryParse(url)?.host ?? url;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(home ? 'Home relay' : 'Relay', style: Txt.title(p.ink)),
            const SizedBox(height: Space.md),
            TechRows([
              ('host', host, copy: true),
              ('url', url, copy: true),
              ('role', home ? 'your introduction address' : 'alternate path', copy: false),
              ('stores data', 'no — ciphertext only', copy: false),
              ('protocol', 'Iroh DERP / QUIC', copy: false),
            ]),
            Text(
              'A relay is not a Mentos server. It cannot read posts, chats or files. Direct links skip it when both phones can punch through NAT.',
              style: Txt.small(p.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScopeTechSheet extends ConsumerWidget {
  const _ScopeTechSheet({required this.scope, this.peer, this.spaceId, this.groupId});
  final String scope;
  final String? peer;
  final String? spaceId;
  final String? groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final items = e.items(scope);
    final owned = items.where((i) => i.owned).length;
    final kept = items.where((i) => i.kept).length;
    final live = items.where((i) => i.live).length;
    final status = ref.watch(netStatusProvider).value;
    final link = peer == null ? null : status?.links.where((l) => l.peer == peer).firstOrNull;
    final space = spaceId == null ? null : e.space(spaceId!);
    final group = groupId == null ? null : e.group(groupId!);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(peer == null ? 'Technical' : e.nameOf(peer!), style: Txt.title(p.ink)),
            const SizedBox(height: Space.md),
            TechRows([
              ('scope', scope, copy: true),
              ('kind', Scope.type(scope), copy: false),
              ('items', '$owned yours · $kept kept · $live live', copy: false),
              if (peer != null) ('peer', peer!, copy: true),
              if (peer != null)
                (
                  'link',
                  link == null
                      ? 'no live path'
                      : '${link.kind.name}${link.latencyMs == null ? '' : ' · ${link.latencyMs} ms'}',
                  copy: false,
                ),
              if (link != null)
                ('rtt', link.latencyMs == null ? '—' : '${link.latencyMs} ms', copy: false),
              for (final path in link?.paths ?? const <RoutePath>[])
                (
                  path.selected ? 'in use' : 'path',
                  '${path.kind.name} · ${path.address}${path.latencyMs == null ? '' : ' · ${path.latencyMs} ms'}',
                  copy: true,
                ),
              if (space != null) ('space id', space.id, copy: true),
              if (space != null) ('archive', space.archive ? 'members may keep' : 'authors only', copy: false),
              if (space != null) ('this phone', space.preserve ? 'keeping history' : 'live only', copy: false),
              if (group != null) ('group id', group.id, copy: true),
              if (group != null) ('members', '${group.members.length}', copy: false),
              if (group != null) ('sealed', 'XChaCha20-Poly1305 + Ed25519', copy: false),
              ('transport', status?.engine ?? '—', copy: false),
            ]),
            if (peer != null)
              Text(
                'A direct path is a QUIC link between these two phones. A relay path is an iroh relay forwarding ciphertext when NAT blocks a hole. Relays do not store the chat.',
                style: Txt.mono(p.faint, size: 11),
              ),
          ],
        ),
      ),
    );
  }
}
