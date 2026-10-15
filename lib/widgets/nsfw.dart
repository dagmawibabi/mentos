import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../state/providers.dart';

/// Blurs any child until the person taps to reveal it.
class NsfwGate extends ConsumerStatefulWidget {
  const NsfwGate({super.key, required this.nsfw, required this.child});
  final bool nsfw;
  final Widget child;

  @override
  ConsumerState<NsfwGate> createState() => _NsfwGateState();
}

class _NsfwGateState extends ConsumerState<NsfwGate> {
  bool _open = false;

  @override
  void didUpdateWidget(covariant NsfwGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nsfw && !widget.nsfw) _open = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.nsfw || _open) return widget.child;
    final p = context.pal;
    if (ref.watch(settingsProvider).hideNsfw) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(
          color: p.raised,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: p.line),
        ),
        child: Text('NSFW hidden', style: Txt.mono(p.muted, size: 12, w: FontWeight.w600)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.md),
      child: Stack(
        alignment: Alignment.center,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: IgnorePointer(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 88),
                child: widget.child,
              ),
            ),
          ),
          Positioned.fill(child: ColoredBox(color: p.bg.withValues(alpha: .45))),
          GestureDetector(
            onTap: () => setState(() => _open = true),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: p.surface.withValues(alpha: .92),
                borderRadius: BorderRadius.circular(Radii.pill),
                border: Border.all(color: p.line),
              ),
              child: Text('NSFW · tap to show', style: Txt.mono(p.ink, size: 12, w: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}
