import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/market/market.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import '../market/market_kit.dart';

/// Public spaces anywhere on the network, from signed directory entries.
class DiscoverSpacesScreen extends ConsumerStatefulWidget {
  const DiscoverSpacesScreen({super.key});

  @override
  ConsumerState<DiscoverSpacesScreen> createState() => _DiscoverSpacesScreenState();
}

class _DiscoverSpacesScreenState extends ConsumerState<DiscoverSpacesScreen> {
  final _q = TextEditingController();
  final _joining = <String>{};

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final m = ref.watch(marketProvider);
    ref.watch(marketTickProvider);
    final e = ref.watch(engineProvider);
    final q = _q.text.trim().toLowerCase();
    final spaces = (m?.publicSpaces() ?? const <Listing>[])
        .where((l) => q.isEmpty || l.haystack.contains(q))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Discover spaces')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.md),
            child: TextField(
              controller: _q,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search public spaces',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: p.raised,
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Text(
              'Owners list a space here by making it public. Entries are signed by the owner and travel '
              'from phone to phone, so you can find spaces nobody you know is in.',
              style: Txt.small(p.muted),
            ),
          ),
          const SizedBox(height: Space.md),
          if (spaces.isEmpty)
            const EmptyState(
              icon: Icons.travel_explore_rounded,
              title: 'No public spaces yet',
              body: 'Make one of yours public in its settings and it shows up here for everyone.',
              compact: true,
            ),
          for (final l in spaces)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.md),
              child: MCard(
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(14)),
                      child: Text(
                        l.title.trim().split(RegExp(r'\s+')).take(2).map((w) => w.isEmpty ? '' : w[0].toUpperCase()).join(),
                        style: Txt.heading(p.accent),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l.title, style: Txt.bodyStrong(p.ink)),
                          if (l.about.isNotEmpty)
                            Text(l.about, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.small(p.inkSoft)),
                          const SizedBox(height: 2),
                          Text('${l.body['members'] ?? 0} members · by ${e.nameOf(l.author)}', style: Txt.mono(p.muted, size: 11)),
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    e.db.space('${l.body['space']}') != null
                        ? OutlinedButton(onPressed: () => context.push('/s/${l.body['space']}'), child: const Text('Open'))
                        : FilledButton(
                            onPressed: _joining.contains(l.id) ? null : () => _join(l),
                            child: Text(_joining.contains(l.id) ? 'Joining…' : 'Join'),
                          ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _join(Listing l) async {
    setState(() => _joining.add(l.id));
    final e = ref.read(engineProvider);
    try {
      final r = await e.openTicket('${l.body['invite']}');
      if (!mounted) return;
      if (r == null) {
        toast(context, 'That invite is no longer valid');
      } else {
        context.push('/s/${r.$2}');
      }
    } catch (err) {
      if (mounted) toast(context, friendly(err));
    } finally {
      if (mounted) setState(() => _joining.remove(l.id));
    }
  }
}
