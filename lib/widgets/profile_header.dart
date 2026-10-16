import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../data/models.dart';
import 'avatar.dart';
import 'ui.dart';

class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    super.key,
    required this.id,
    required this.name,
    required this.bio,
    required this.stats,
    this.status,
    this.online = false,
    this.onEdit,
  });
  final String id;
  final String name;
  final String bio;
  final String? status;
  final bool online;
  final List<(int, String, VoidCallback?)> stats;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Avatar(id: id, size: 72, presence: false),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.display(p.ink).copyWith(fontSize: 22, height: 1.15)),
                        ),
                        if (onEdit != null)
                          IconBtn(Icons.edit_outlined, size: 18, color: p.muted, tooltip: 'Edit profile', onTap: onEdit),
                      ],
                    ),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: id));
                        toast(context, 'Key copied');
                      },
                      child: Text(shortId(id), style: Txt.mono(p.muted)),
                    ),
                    if (status != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: online ? p.accent : p.danger),
                          ),
                          const SizedBox(width: 6),
                          Flexible(child: Text(status!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.mono(online ? p.accent : p.muted, size: 11))),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: Space.lg),
            Row(
              children: [
                for (final s in stats)
                  Expanded(
                    child: GestureDetector(
                      onTap: s.$3,
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(compact(s.$1), style: Txt.heading(p.ink)),
                          Text(s.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.mono(p.muted, size: 11)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (bio.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            Text(bio, style: Txt.body(p.inkSoft)),
          ],
        ],
      ),
    );
  }
}
