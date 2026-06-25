import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/features/ocr/domain/text_detector.dart';

/// Paints a filled rectangle of 1.0 into a [w]×[h] probability map.
Float32List _mapWith(int w, int h, List<List<int>> rects) {
  final m = Float32List(w * h);
  for (final r in rects) {
    final x0 = r[0], y0 = r[1], x1 = r[2], y1 = r[3];
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        m[y * w + x] = 1.0;
      }
    }
  }
  return m;
}

void main() {
  const detector = TextDetector();

  test('finds one box for one blob, covering it', () {
    final m = _mapWith(40, 40, [
      [10, 10, 25, 18], // a horizontal bar
    ]);
    final boxes = detector.detect(m, 40, 40);
    expect(boxes, hasLength(1));
    final b = boxes.first;
    // Padding grows the box, but it must still contain the original blob.
    expect(b.left, lessThanOrEqualTo(10));
    expect(b.top, lessThanOrEqualTo(10));
    expect(b.right, greaterThanOrEqualTo(25));
    expect(b.bottom, greaterThanOrEqualTo(18));
  });

  test('separates two vertically-stacked blobs into two boxes', () {
    final m = _mapWith(40, 40, [
      [5, 4, 30, 8],
      [5, 24, 30, 28],
    ]);
    final boxes = detector.detect(m, 40, 40);
    expect(boxes, hasLength(2));
  });

  test('rejects speckle below the area/height thresholds', () {
    final m = _mapWith(40, 40, [
      [1, 1, 1, 1], // single pixel
    ]);
    expect(detector.detect(m, 40, 40), isEmpty);
  });

  test('empty map yields no boxes', () {
    expect(detector.detect(Float32List(40 * 40), 40, 40), isEmpty);
  });
}
