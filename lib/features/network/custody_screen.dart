import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

/// Where data lives: what this phone keeps for other people, and who keeps
/// copies of yours. Copies only exist with consent, and either side can end them.
class CustodyScreen extends ConsumerWidget {
  const CustodyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const Scaffold(body: Loading());
    final grants = ref.watch(grantsProvider).value ?? const <Grant>[];
    ref.watch(peopleProvider);
    final tiers = e.tierCounts();
    final keptBy = e.keptByAuthor();

    final keepers = <String, List<Grant>>{};
    for (final g in grants.where((g) => g.dir == GrantDir.out)) {
      keepers.putIfAbsent(g.peer, () => []).add(g);
    }
    final preserved = e.people().where((x) => x.preserve).toList();
    final custody = grants.where((g) => g.dir == GrantDir.inbound && g.state == GrantState.active).toList();
    final spacesKept = e.spaces().where((s) => s.preserve && s.archive).toList();
    final youKeep = custody.length + preserved.length + spacesKept.length;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Who holds what'),
          bottom: TabBar(tabs: [
            Tab(text: 'You keep${youKeep == 0 ? '' : ' ($youKeep)'}'),
            Tab(text: 'Keep yours${keepers.isEmpty ? '' : ' (${keepers.length})'}'),
          ]),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
              child: Row(
                children: [
                  _Tier(value: tiers.owned, hint: 'created here', tag: Provenance.mine),
                  const SizedBox(width: Space.sm),
                  _Tier(value: tiers.kept, hint: 'others\' with consent', tag: Provenance.kept),
                  const SizedBox(width: Space.sm),
                  _Tier(value: tiers.live, hint: 'in memory only', tag: Provenance.live),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.sm),
              child: Text(
                'Live items vanish when their author goes offline. Kept items stay until the author revokes consent or you stop keeping them.',
                style: Txt.small(p.muted),
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  ListView(
                    children: [
                      if (youKeep == 0)
                        const EmptyState(icon: Icons.inventory_2_outlined, title: 'Nothing from anyone else is stored here', compact: true),
                      for (final g in custody)
                        _PeerRow(
                          id: g.peer,
                          subtitle: '${_scopeLabel(g.scope)} · ${keptBy[g.peer] ?? 0} items',
                          action: TextButton(onPressed: () => e.dropTheirs(g.scope), child: Text('Stop', style: Txt.small(p.danger))),
                        ),
                      for (final x in preserved)
                        _PeerRow(
                          id: x.id,
                          subtitle: 'public posts · ${keptBy[x.id] ?? 0} items',
                          action: TextButton(onPressed: () => e.setPreserve(x.id, false), child: Text('Stop', style: Txt.small(p.danger))),
                        ),
                      for (final s in spacesKept)
                        ListTile(
                          leading: CircleAvatar(backgroundColor: p.raised, child: Icon(Icons.grid_view_rounded, color: p.inkSoft, size: 18)),
                          title: Text(s.name),
                          subtitle: Text('space history', style: Txt.small(p.muted)),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => context.push('/s/${s.id}/settings'),
                        ),
                    ],
                  ),
                  ListView(
                    children: [
                      if (keepers.isEmpty)
                        const EmptyState(
                          icon: Icons.cloud_off_outlined,
                          title: 'No one keeps your data',
                          body: 'Everything you create exists only on this phone and is visible while you\'re online.',
                          compact: true,
                        )
                      else
                        for (final entry in keepers.entries)
                          _PeerRow(
                            id: entry.key,
                            subtitle: entry.value
                                .map((g) => '${_scopeLabel(g.scope)}${g.state == GrantState.pending ? ' (waiting)' : ''}')
                                .join(' · '),
                          ),
                      Padding(
                        padding: const EdgeInsets.all(Space.gutter),
                        child: OutlinedButton.icon(
                          onPressed: () => context.push('/settings'),
                          icon: const Icon(Icons.tune_rounded, size: 18),
                          label: const Text('Choose what others may keep'),
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
    );
  }
}

String _scopeLabel(String scope) => switch (Scope.type(scope)) {
  'dm' => 'chat',
  'feed' => 'posts',
  'story' => 'stories',
  'chan' => 'channel',
  'sfeed' => 'space posts',
  final t => t,
};

class _Tier extends StatelessWidget {
  const _Tier({required this.value, required this.hint, required this.tag});
  final int value;
  final String hint;
  final Provenance tag;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: p.line)),
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
  const _PeerRow({required this.id, required this.subtitle, this.action});
  final String id;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final name = ref.watch(peerProvider(id)).value?.name ?? alias(id);
    return ListTile(
      leading: Avatar(id: id, size: 38),
      title: Text(name),
      subtitle: Text(subtitle, style: Txt.small(p.muted)),
      trailing: action,
      onTap: () => context.push('/node/$id'),
    );
  }
}
