import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';

class SpaceGlyph extends StatelessWidget {
  const SpaceGlyph({super.key, required this.space, this.size = 48});
  final SpaceInfo space;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final letters = space.name.trim().isEmpty
        ? '#'
        : space.name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0].toUpperCase()).join();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(size * .28),
        border: Border.all(color: p.line),
      ),
      child: Text(letters, style: Txt.heading(p.ink).copyWith(fontSize: size * .36, letterSpacing: -0.5)),
    );
  }
}

class SpacesScreen extends ConsumerWidget {
  const SpacesScreen({super.key, this.embedded = false});

  /// Drawn inside the Chats tab, without its own app bar.
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final spaces = ref.watch(spacesProvider).value ?? const <SpaceInfo>[];
    final body = spaces.isEmpty
        ? EmptyState(
            icon: Icons.grid_view_rounded,
            title: 'No spaces yet',
            body: 'A space is a small community with channels and a shared feed. '
                'It exists on its members\' phones — there\'s no server to host it.',
            action: Column(
              children: [
                FilledButton.icon(
                  onPressed: () => context.push('/new-space'),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Create a space'),
                ),
                const SizedBox(height: Space.sm),
                OutlinedButton.icon(
                  onPressed: () => context.push('/communities/discover'),
                  icon: const Icon(Icons.travel_explore_rounded, size: 18),
                  label: const Text('Discover public spaces'),
                ),
                TextButton(
                  onPressed: () => context.push('/connect'),
                  child: Text('I have an invite', style: Txt.bodyStrong(p.muted)),
                ),
              ],
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.only(bottom: Space.xxl),
            itemCount: spaces.length,
            separatorBuilder: (_, _) => const Hairline(indent: Space.gutter + 60),
            itemBuilder: (_, i) => _SpaceRow(space: spaces[i]),
          );
    if (embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Spaces'),
        actions: [
          IconBtn(Icons.travel_explore_rounded, tooltip: 'Discover', onTap: () => context.push('/communities/discover')),
          IconBtn(Icons.link_rounded, tooltip: 'Join with invite', onTap: () => context.push('/connect')),
          IconBtn(Icons.add_rounded, tooltip: 'New space', onTap: () => context.push('/new-space')),
          const SizedBox(width: 8),
        ],
      ),
      body: body,
    );
  }
}

class _SpaceRow extends ConsumerWidget {
  const _SpaceRow({required this.space});
  final SpaceInfo space;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final members = ref.watch(membersProvider(space.id)).value ?? const [];
    final online = members.where((m) => m.online).length;
    final me = ref.read(engineProvider).me.id;
    return InkWell(
      onTap: () => context.push('/s/${space.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 14),
        child: Row(
          children: [
            SpaceGlyph(space: space),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(space.name, style: Txt.bodyStrong(p.ink), overflow: TextOverflow.ellipsis)),
                      if (space.public) ...[
                        const SizedBox(width: 6),
                        Text('public', style: Txt.mono(p.accent, size: 10.5)),
                      ],
                      if (space.owner == me) ...[
                        const SizedBox(width: 6),
                        Text('owner', style: Txt.mono(p.faint, size: 10.5)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: online > 1 ? p.accent : p.faint),
                      ),
                      const SizedBox(width: 6),
                      Text('${members.length} members · $online online · ${space.channels.length} channels',
                          style: Txt.mono(p.muted, size: 11)),
                    ],
                  ),
                ],
              ),
            ),
            if (space.preserve) Icon(Icons.cloud_done_outlined, size: 16, color: p.faint),
          ],
        ),
      ),
    );
  }
}
