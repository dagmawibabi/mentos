import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../state/providers.dart';
import 'ui.dart';

final _link = RegExp(r'mentos://[us]/[A-Za-z0-9_\-]+', caseSensitive: false);

/// The first Mentos invite in [text], if any.
String? firstInvite(String text) => _link.firstMatch(text)?.group(0);

/// [text] with Mentos invite links taken out, so a bubble does not show
/// hundreds of base64 characters above the card that replaces them.
String withoutInvites(String text) => text.replaceAll(_link, '').trim();

/// A tappable card for a space or contact invite inside a message or post.
class InviteCard extends ConsumerStatefulWidget {
  const InviteCard({super.key, required this.text, this.fg});
  final String text;
  final Color? fg;

  @override
  ConsumerState<InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends ConsumerState<InviteCard> {
  Future<({String kind, String id, String name, bool known})?>? _peek;
  String? _for;
  bool _busy = false;

  void _arm() {
    final link = firstInvite(widget.text);
    if (link == _for) return;
    _for = link;
    final e = ref.read(maybeEngineProvider);
    _peek = link == null || e == null ? null : e.peekTicket(link);
  }

  @override
  Widget build(BuildContext context) {
    _arm();
    final p = context.pal;
    if (_peek == null) return const SizedBox.shrink();
    return FutureBuilder(
      future: _peek,
      builder: (context, snap) {
        final info = snap.data;
        if (info == null) return const SizedBox.shrink();
        final space = info.kind == 'space';
        return Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(12),
          constraints: const BoxConstraints(maxWidth: 260),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.line),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(12)),
                child: Icon(space ? Icons.grid_view_rounded : Icons.person_add_alt_rounded, color: p.accent, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(space ? 'SPACE INVITE' : 'CONTACT', style: Txt.label(p.muted)),
                    const SizedBox(height: 2),
                    Text(info.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(p.ink)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                onPressed: _busy ? null : () => _open(info),
                child: Text(info.known ? 'Open' : (space ? 'Join' : 'Add')),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _open(({String kind, String id, String name, bool known}) info) async {
    final route = info.kind == 'space' ? '/s/${info.id}' : '/u/${info.id}';
    if (info.known) {
      context.push(route);
      return;
    }
    setState(() => _busy = true);
    try {
      final e = ref.read(engineProvider);
      final r = await e.openTicket(_for!);
      if (!mounted) return;
      if (r == null) {
        toast(context, 'This invite is not valid');
      } else {
        toast(context, info.kind == 'space' ? 'Joined ${info.name}' : 'Added ${info.name}');
        context.push(route);
      }
    } catch (err) {
      if (mounted) toast(context, '$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
