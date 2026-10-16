import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import 'broadcast_screen.dart';

/// Every channel this device knows about: yours, the ones you subscribed
/// to, and channels from people you follow that you could join.
class ChannelsScreen extends ConsumerWidget {
  const ChannelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const Scaffold(body: Loading());
    final all = ref.watch(broadcastsProvider).value ?? const <Bcast>[];
    final mine = all.where((c) => c.owner == e.me.id).toList();
    final subscribed = all.where((c) => c.owner != e.me.id && e.isSubscribed(c.owner, c.id)).toList();
    final discover = all.where((c) => c.owner != e.me.id && !e.isSubscribed(c.owner, c.id)).toList();

    Widget row(Bcast c, {Widget? trailing}) {
      final n = e.subscribers(c).length;
      return ListTile(
        leading: CircleAvatar(backgroundColor: p.raised, child: Icon(Icons.campaign_outlined, color: p.inkSoft, size: 20)),
        title: Text(c.name),
        subtitle: Text(
          [
            if (c.owner != e.me.id) e.nameOf(c.owner),
            if (n > 0) '${compact(n)} subscriber${n == 1 ? '' : 's'}',
            if (c.about.isNotEmpty) c.about,
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Txt.mono(p.muted, size: 11),
        ),
        trailing: trailing,
        onTap: () => context.push('/ch/${c.owner}/${c.id}'),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Channels'),
        actions: [
          IconBtn(Icons.add_rounded, tooltip: 'New channel', onTap: () => CreateBroadcastSheet.open(context, ref)),
          const SizedBox(width: 8),
        ],
      ),
      body: all.isEmpty
          ? EmptyState(
              icon: Icons.campaign_outlined,
              title: 'No channels yet',
              body: 'A channel is one voice to many: you post, subscribers read, react and comment. '
                  'Channels from people you follow show up here.',
              action: FilledButton(onPressed: () => CreateBroadcastSheet.open(context, ref), child: const Text('Start a channel')),
            )
          : ListView(
              children: [
                if (mine.isNotEmpty) ...[SectionLabel('Yours'), for (final c in mine) row(c)],
                if (subscribed.isNotEmpty) ...[SectionLabel('Subscribed'), for (final c in subscribed) row(c)],
                if (discover.isNotEmpty) ...[
                  SectionLabel('From people you follow'),
                  for (final c in discover)
                    row(c, trailing: TextButton(onPressed: () => e.subscribe(c, true), child: const Text('Subscribe'))),
                ],
                Padding(
                  padding: const EdgeInsets.all(Space.gutter),
                  child: Text(
                    'Channels live on their owner\'s phone. Posts reach subscribers over the owner\'s gossip topic, '
                    'and each subscription is a signed message the owner can count.',
                    style: Txt.mono(p.faint, size: 11),
                  ),
                ),
              ],
            ),
    );
  }
}
