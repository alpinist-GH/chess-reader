import 'dart:typed_data';

import 'ocr_box.dart';

/// Turns a DBNet probability map into axis-aligned text-line boxes.
///
/// PP-OCR's detector emits a per-pixel "is this text" probability map at the
/// detector-input resolution. Full PP-OCR then traces contours, fits rotated
/// rectangles and polygon-unclips them. For horizontal printed body text we
/// take a simpler, deterministic path: threshold the map, label connected
/// components (8-connectivity), and take each component's bounding box, padded
/// slightly to recover the glyph extent the probability map under-covers.
class TextDetector {
  const TextDetector({
    this.binThreshold = 0.3,
    this.minBoxArea = 16,
    this.minBoxHeight = 4,
  });

  /// Probability above which a pixel counts as text.
  final double binThreshold;

  /// Reject components smaller than this (pixels) — speckle from the map.
  final int minBoxArea;

  /// Reject components shorter than this (pixels) — sub-glyph noise.
  final int minBoxHeight;

  /// [prob] is a flat `[h, w]` map in [0, 1]. Returns boxes in the map's own
  /// pixel space (caller scales them back to the source image).
  List<TextBox> detect(Float32List prob, int w, int h) {
    assert(prob.length == w * h);
    final labels = Int32List(w * h); // 0 = unvisited/background
    final boxes = <TextBox>[];
    final stack = <int>[];

    for (var start = 0; start < prob.length; start++) {
      if (labels[start] != 0 || prob[start] < binThreshold) continue;
      // Flood-fill this component, tracking its bounding box.
      labels[start] = 1;
      stack
        ..clear()
        ..add(start);
      var minX = w, minY = h, maxX = 0, maxY = 0, area = 0;
      while (stack.isNotEmpty) {
        final idx = stack.removeLast();
        final x = idx % w;
        final y = idx ~/ w;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
        area++;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = y + dy;
          if (ny < 0 || ny >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            if (nx < 0 || nx >= w) continue;
            final n = ny * w + nx;
            if (labels[n] != 0 || prob[n] < binThreshold) continue;
            labels[n] = 1;
            stack.add(n);
          }
        }
      }
      final bw = maxX - minX + 1;
      final bh = maxY - minY + 1;
      if (area < minBoxArea || bh < minBoxHeight) continue;
      // Pad by ~30% of the line height to recover the under-covered extent.
      final pad = (bh * 0.3).round().clamp(1, bh);
      boxes.add(TextBox(left: minX, top: minY, width: bw, height: bh)
          .padded(pad, (pad / 2).round().clamp(1, bh), w, h));
    }
    return boxes;
  }
}
