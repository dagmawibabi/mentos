import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

/// Pick people to send a post to. Sends a quote, not a copy of the original.
Future<void> showShareSheet(BuildContext context, WidgetRef ref, PostView post) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ShareSheet(post: post),
  );
}

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.post});
  final PostView post;

  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  final _picked = <String>{};
  final _note = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final people = (ref.watch(peopleProvider).value ?? const <Peer>[])
        .where((x) => !x.blocked && x.id != e.me.id)
        .toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * .7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.md),
            child: Text('Send to', style: Txt.heading(p.ink)),
          ),
          Expanded(
            child: people.isEmpty
                ? const EmptyState(
                    icon: Icons.people_outline_rounded,
                    title: 'No contacts yet',
                    body: 'Add someone with their QR code first.',
                    compact: true,
                  )
                : ListView.builder(
                    itemCount: people.length,
                    itemBuilder: (_, i) {
                      final x = people[i];
                      final on = _picked.contains(x.id);
                      return ListTile(
                        leading: Avatar(id: x.id, size: 36),
                        title: Text(x.name),
                        trailing: AnimatedContainer(
                          duration: Motion.fast,
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: on ? p.ink : Colors.transparent,
                            border: Border.all(color: on ? p.ink : p.faint, width: 1.5),
                          ),
                          child: on ? Icon(Icons.check_rounded, size: 14, color: p.bg) : null,
                        ),
                        onTap: () => setState(() => on ? _picked.remove(x.id) : _picked.add(x.id)),
                      );
                    },
                  ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                Space.gutter, Space.sm, Space.gutter, Space.lg + MediaQuery.of(context).viewInsets.bottom),
            child: Row(
              children: [
                Expanded(
                  child: TextField(controller: _note, decoration: const InputDecoration(hintText: 'Add a note')),
                ),
                const SizedBox(width: Space.sm),
                FilledButton(
                  onPressed: _picked.isEmpty
                      ? null
                      : () async {
                          final post = widget.post;
                          final quote = post.text.length > 280 ? '${post.text.substring(0, 280)}…' : post.text;
                          for (final id in _picked) {
                            await e.sendMessage(
                              Scope.dm(e.me.id, id),
                              text: [if (_note.text.trim().isNotEmpty) _note.text.trim(), '“$quote”\n— ${e.nameOf(post.author)}']
                                  .join('\n\n'),
                              forwarded: true,
                            );
                          }
                          if (context.mounted) {
                            Navigator.pop(context);
                            toast(context, 'Sent to ${_picked.length}');
                          }
                        },
                  child: const Text('Send'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
