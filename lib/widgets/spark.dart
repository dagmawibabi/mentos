import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

class SparkLine extends StatelessWidget {
  const SparkLine({super.key, required this.points, this.height = 148});
  final List<double> points;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _SparkPainter(points, p.ink, p.line)),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.pts, this.ink, this.grid);
  final List<double> pts;
  final Color ink;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final data = pts.isEmpty ? const [0.0] : pts;
    final maxV = math.max(1.0, data.reduce(math.max));
    final padL = 28.0;
    final padB = 18.0;
    final w = size.width - padL;
    final h = size.height - padB;
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i < 3; i++) {
      final y = h * i / 2;
      canvas.drawLine(Offset(padL, y), Offset(size.width, y), gridPaint);
    }
    if (data.length == 1) {
      canvas.drawCircle(Offset(padL, h), 3, Paint()..color = ink);
      return;
    }
    final path = Path();
    final fill = Path();
    for (var i = 0; i < data.length; i++) {
      final x = padL + w * i / (data.length - 1);
      final y = h - (data[i] / maxV) * h * .92;
      if (i == 0) {
        path.moveTo(x, y);
        fill.moveTo(x, h);
        fill.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fill.lineTo(x, y);
      }
    }
    fill.lineTo(padL + w, h);
    fill.close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [ink.withValues(alpha: .18), ink.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, h)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.pts != pts || old.ink != ink;
}
