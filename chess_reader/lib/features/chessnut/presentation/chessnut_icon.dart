import 'package:flutter/material.dart';

/// Original mark for the Chessnut Move feature: a simple hand-drawn pawn
/// silhouette (not any vendor's logo or icon-font glyph) so it always
/// renders in the current theme color, with an optional small status badge.
class ChessnutIcon extends StatelessWidget {
  const ChessnutIcon({super.key, this.size = 20, this.badgeColor});

  final double size;

  /// Small corner badge color indicating connection/sync status; omitted
  /// entirely (no badge) when null, e.g. while fully disconnected.
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _PawnPainter(color),
          ),
          if (badgeColor != null)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: size * 0.4,
                height: size * 0.4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: badgeColor,
                  border: Border.all(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    width: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PawnPainter extends CustomPainter {
  _PawnPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final w = size.width;
    final h = size.height;

    // Head.
    canvas.drawCircle(Offset(w * 0.5, h * 0.22), w * 0.17, paint);

    // Neck.
    canvas.drawRRect(
      RRect.fromLTRBR(
        w * 0.40, h * 0.34, w * 0.60, h * 0.44, Radius.circular(w * 0.03),
      ),
      paint,
    );

    // Body: a trapezoid tapering out from the neck down to the base.
    final body = Path()
      ..moveTo(w * 0.38, h * 0.44)
      ..lineTo(w * 0.62, h * 0.44)
      ..lineTo(w * 0.74, h * 0.78)
      ..lineTo(w * 0.26, h * 0.78)
      ..close();
    canvas.drawPath(body, paint);

    // Base.
    canvas.drawRRect(
      RRect.fromLTRBR(
        w * 0.16, h * 0.78, w * 0.84, h * 0.90, Radius.circular(w * 0.05),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _PawnPainter oldDelegate) =>
      oldDelegate.color != color;
}
