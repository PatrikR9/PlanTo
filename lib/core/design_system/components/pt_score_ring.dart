import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/tokens.dart';

/// The app's signature element: a 0-100 score as an animated arc.
///
/// Used for weather quality and overall date score. Wrapped in a
/// RepaintBoundary because it animates inside scrolling lists.
///
/// Accessibility: the numeric score alone is meaningless to a screen reader,
/// so [semanticLabel] should carry the band word too ("Počasí 84 ze 100,
/// dobré"). Colour is never the only signal.
class PtScoreRing extends StatelessWidget {
  const PtScoreRing({
    required this.score,
    required this.semanticLabel,
    this.size = 56,
    this.strokeWidth = 5,
    this.caption,
    super.key,
  }) : assert(score >= 0 && score <= 100, 'score must be 0..100');

  final int score;
  final String semanticLabel;
  final double size;
  final double strokeWidth;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final Color colour = context.planto.weatherForScore(score);

    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: RepaintBoundary(
        child: SizedBox(
          width: size,
          height: size,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: score / 100),
            duration: Motion.emphasised,
            curve: Motion.emphasis,
            builder: (BuildContext context, double value, _) {
              return CustomPaint(
                painter: _RingPainter(
                  progress: value,
                  colour: colour,
                  track: context.planto.availabilityNone,
                  strokeWidth: strokeWidth,
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        '$score',
                        style: context.texts.labelLarge?.copyWith(
                          fontSize: size * 0.3,
                          color: colour,
                        ),
                      ),
                      if (caption != null)
                        Text(
                          caption!,
                          style: context.texts.labelSmall?.copyWith(
                            fontSize: size * 0.15,
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.colour,
    required this.track,
    required this.strokeWidth,
  });

  final double progress;
  final Color colour;
  final Color track;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset centre = size.center(Offset.zero);
    final double radius = (size.shortestSide - strokeWidth) / 2;

    final Paint trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = track;

    final Paint arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = colour;

    canvas.drawCircle(centre, radius, trackPaint);
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.colour != colour;
}
