import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crypto/crypto.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../data/models.dart';
import '../state/providers.dart';

/// A deterministic glyph drawn from someone's key: a 5×5 mirrored grid.
/// Same key, same sigil, on every device, without any server.
class Sigil extends StatelessWidget {
  const Sigil({super.key, required this.id, this.size = 40});
  final String id;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return CustomPaint(size: Size.square(size), painter: _SigilPainter(id, p));
  }
}

class _SigilPainter extends CustomPainter {
  _SigilPainter(this.id, this.p);
  final String id;
  final Palette p;

  @override
  void paint(Canvas canvas, Size size) {
    final bytes = id.length >= 64 ? fromHex(id.substring(0, 32)) : sha256(id.codeUnits);
    final r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.width * .3));
    canvas.clipRRect(r);
    canvas.drawRect(Offset.zero & size, Paint()..color = p.raised);

    // a quiet tint per key: lightness band of the ink, never a hue
    final shade = 0.55 + (bytes[15] % 30) / 100;
    final ink = Color.lerp(p.raised, p.ink, shade)!;
    final paint = Paint()..color = ink;

    const n = 5;
    final pad = size.width * .2;
    final cell = (size.width - pad * 2) / n;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < 3; x++) {
        final bit = (bytes[(y * 3 + x) % 16] >> ((x + y) % 8)) & 1;
        if (bit == 0) continue;
        for (final xx in {x, n - 1 - x}) {
          final rect = Rect.fromLTWH(pad + xx * cell, pad + y * cell, cell, cell).deflate(cell * .08);
          canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(cell * .28)), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_SigilPainter old) => old.id != id || old.p != p;
}

/// Avatar with profile photo when available, sigil otherwise, and an
/// emerald ring + dot when the person is reachable right now.
class Avatar extends ConsumerWidget {
  const Avatar({super.key, required this.id, this.size = 40, this.presence = true, this.ring = false});
  final String id;
  final double size;
  final bool presence;
  final bool ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final peer = ref.watch(peerProvider(id)).value;
    final online = presence && (ref.watch(onlineProvider(id)).value ?? false);
    final avatar = peer?.profile?.avatar;

    Widget face = avatar == null ? Sigil(id: id, size: size) : _Photo(ref: avatar, owner: id, size: size);
    if (ring) {
      face = Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.rectangle,
          borderRadius: BorderRadius.circular(size * .36),
          border: Border.all(color: p.accent, width: 2),
        ),
        child: face,
      );
    }
    final me = ref.watch(maybeEngineProvider)?.me.id;
    if (me == null || id == me || !presence) return face;
    final dot = (size * .28).clamp(8.0, 14.0);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        face,
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              color: online ? p.accent : p.danger,
              shape: BoxShape.circle,
              border: Border.all(color: p.bg, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

class _Photo extends ConsumerStatefulWidget {
  const _Photo({required this.ref, required this.owner, required this.size});
  final MediaRef ref;
  final String owner;
  final double size;

  @override
  ConsumerState<_Photo> createState() => _PhotoState();
}

class _PhotoState extends ConsumerState<_Photo> {
  Future<File?>? _f;

  @override
  void didUpdateWidget(covariant _Photo old) {
    super.didUpdateWidget(old);
    if (old.ref.hash != widget.ref.hash) _f = null;
  }

  @override
  Widget build(BuildContext context) {
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return SizedBox(width: widget.size, height: widget.size);
    _f ??= e.media.open(widget.ref, sources: [widget.owner]);
    return FutureBuilder<File?>(
      future: _f,
      builder: (context, snap) {
        final f = snap.data;
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.size * .3),
          child: f == null
              ? Sigil(id: widget.owner, size: widget.size)
              : Image.file(f, width: widget.size, height: widget.size, fit: BoxFit.cover, gaplessPlayback: true),
        );
      },
    );
  }
}
