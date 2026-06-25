/// An axis-aligned text-line box in pixel coordinates of some image.
///
/// The detector works on axis-aligned boxes only: printed chess-book body text
/// is horizontal, so the rotated min-area rectangles full PP-OCR produces are
/// unnecessary here and a connected-component bounding box is enough.
class TextBox {
  const TextBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final int left;
  final int top;
  final int width;
  final int height;

  int get right => left + width;
  int get bottom => top + height;
  double get centerY => top + height / 2;

  /// This box mapped from detector-input pixels back to source-image pixels.
  /// [sx]/[sy] are source/input scale factors (source = input * scale).
  TextBox scaled(double sx, double sy) => TextBox(
        left: (left * sx).round(),
        top: (top * sy).round(),
        width: (width * sx).round(),
        height: (height * sy).round(),
      );

  /// Grows the box by [padX]/[padY] pixels on each side, clamped to
  /// [0, maxW] × [0, maxH]. Approximates PP-OCR's polygon "unclip": detector
  /// probability maps shrink slightly inside the true glyph extent.
  TextBox padded(int padX, int padY, int maxW, int maxH) {
    final l = (left - padX).clamp(0, maxW);
    final t = (top - padY).clamp(0, maxH);
    final r = (right + padX).clamp(0, maxW);
    final b = (bottom + padY).clamp(0, maxH);
    return TextBox(left: l, top: t, width: r - l, height: b - t);
  }
}

/// A detected text line together with the string the recognizer read from it.
class RecognizedLine {
  const RecognizedLine({required this.box, required this.text});

  final TextBox box;
  final String text;
}
