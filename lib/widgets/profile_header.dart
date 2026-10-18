import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../data/models.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../state/providers.dart';
import 'avatar.dart';
import 'ui.dart';

/// A profile's header image, or a soft gradient when there is none.
class ProfileCover extends ConsumerStatefulWidget {
  const ProfileCover({super.key, required this.id, required this.cover});
  final String id;
  final MediaRef? cover;

  @override
  ConsumerState<ProfileCover> createState() => _ProfileCoverState();
}

class _ProfileCoverState extends ConsumerState<ProfileCover> {
  Future<File?>? _f;

  @override
  void didUpdateWidget(covariant ProfileCover old) {
    super.didUpdateWidget(old);
    if (old.cover?.hash != widget.cover?.hash) _f = null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.accentSoft, Color.lerp(p.accentSoft, const Color(0xFF3B82F6), .25)!, p.raised],
        ),
      ),
      child: const SizedBox.expand(),
    );
    final cover = widget.cover;
    final e = ref.watch(maybeEngineProvider);
    if (cover == null || e == null) return fallback;
    _f ??= e.media.open(cover, sources: [widget.id]);
    return FutureBuilder<File?>(
      future: _f,
      builder: (context, snap) => snap.data == null
          ? fallback
          : Image.file(snap.data!, fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true),
    );
  }
}

/// The avatar with a story ring: accent while there is a story to see,
/// muted once every story was seen.
class StoryAvatar extends StatelessWidget {
  const StoryAvatar({super.key, required this.id, this.size = 72, this.story = false, this.seen = false, this.onTap});
  final String id;
  final double size;
  final bool story;
  final bool seen;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final radius = size * .36 + 5;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: story && !seen
              ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [p.accent, Color.lerp(p.accent, const Color(0xFF3B82F6), .55)!])
              : null,
          color: story && seen ? p.line : (story ? null : Colors.transparent),
        ),
        child: Container(
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(radius - 3)),
          child: Avatar(id: id, size: size, presence: false),
        ),
      ),
    );
  }
}

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
    this.story = false,
    this.storySeen = false,
    this.onAvatar,
  });
  final String id;
  final String name;
  final String bio;
  final String? status;
  final bool online;
  final List<(int, String, VoidCallback?)> stats;
  final VoidCallback? onEdit;
  final bool story;
  final bool storySeen;
  final VoidCallback? onAvatar;

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
              StoryAvatar(id: id, story: story, seen: storySeen, onTap: onAvatar),
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
