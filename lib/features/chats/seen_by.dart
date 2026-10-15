import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/delivery.dart';

/// Telegram-style "seen by" for a group message: who read it and when, who
/// has it but has not read it, and who has not confirmed yet.
class SeenBy extends StatelessWidget {
  const SeenBy({super.key, required this.recipients, required this.nameOf, this.selected, this.onSelect});
  final List<RecipientDelivery> recipients;
  final String Function(String id) nameOf;
  final String? selected;
  final ValueChanged<String>? onSelect;

  static List<RecipientDelivery> sorted(List<RecipientDelivery> list) {
    int rank(RecipientDelivery r) => switch (r.state) {
          Delivery.read => 0,
          Delivery.delivered => 1,
          _ => 2,
        };
    return [...list]..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        final at = (b.readAt ?? b.deliveredAt ?? 0).compareTo(a.readAt ?? a.deliveredAt ?? 0);
        return at;
      });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final read = recipients.where((r) => r.state == Delivery.read).length;
    final got = recipients.where((r) => r.state == Delivery.delivered).length;
    final waiting = recipients.length - read - got;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.done_all_rounded, size: 16, color: p.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Seen by $read of ${recipients.length}'
                '${got > 0 ? ' · $got delivered' : ''}${waiting > 0 ? ' · $waiting waiting' : ''}',
                style: Txt.small(p.ink).copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final r in sorted(recipients))
          InkWell(
            onTap: onSelect == null ? null : () => onSelect!(r.peer),
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    switch (r.state) {
                      Delivery.read => Icons.visibility_rounded,
                      Delivery.delivered => Icons.done_all_rounded,
                      Delivery.failed => Icons.error_outline_rounded,
                      _ => Icons.schedule_rounded,
                    },
                    size: 15,
                    color: r.state == Delivery.read ? p.accent : (r.state == Delivery.failed ? p.danger : p.muted),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      nameOf(r.peer),
                      overflow: TextOverflow.ellipsis,
                      style: Txt.body(r.peer == selected ? p.accent : p.ink),
                    ),
                  ),
                  Text(
                    switch (r.state) {
                      Delivery.read => r.readAt == null ? 'read' : 'read ${timeAgo(r.readAt!)}',
                      Delivery.delivered => r.deliveredAt == null ? 'delivered' : 'delivered ${timeAgo(r.deliveredAt!)}',
                      _ => r.state.label.toLowerCase(),
                    },
                    style: Txt.mono(p.muted, size: 11),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
