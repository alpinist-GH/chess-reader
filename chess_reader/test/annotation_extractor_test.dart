import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/features/vision/domain/annotation_extractor.dart';
import 'package:chess_reader/features/vision/domain/board_annotations.dart';
import 'package:chess_reader/features/vision/domain/board_slicer.dart';

/// Paints a thick line segment into [mask] (values 1.0), optionally dashed.
void _line(Float32List mask, int x0, int y0, int x1, int y1,
    {int width = 2, int dashOn = 0, int dashOff = 0}) {
  final steps = math.max((x1 - x0).abs(), (y1 - y0).abs());
  for (var s = 0; s <= steps; s++) {
    if (dashOn > 0 && (s % (dashOn + dashOff)) >= dashOn) continue;
    final x = x0 + ((x1 - x0) * s / steps).round();
    final y = y0 + ((y1 - y0) * s / steps).round();
    for (var dy = -width ~/ 2; dy <= width ~/ 2; dy++) {
      for (var dx = -width ~/ 2; dx <= width ~/ 2; dx++) {
        final px = x + dx, py = y + dy;
        if (px >= 0 && px < kSegSize && py >= 0 && py < kSegSize) {
          mask[py * kSegSize + px] = 1.0;
        }
      }
    }
  }
}

/// Paints a filled disc (an arrowhead's ink blob) at ([cx], [cy]).
void _disc(Float32List mask, int cx, int cy, int r) {
  for (var y = cy - r; y <= cy + r; y++) {
    for (var x = cx - r; x <= cx + r; x++) {
      if (x < 0 || x >= kSegSize || y < 0 || y >= kSegSize) continue;
      if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) {
        mask[y * kSegSize + x] = 1.0;
      }
    }
  }
}

void main() {
  test('recovers a solid arrow with its direction (head = dest)', () {
    // Shaft from the middle of b2 (36, 156) to g7 (156, 36) with a dense
    // arrowhead blob at the g7 end, like the segmenter returns for the
    // Fischer bishop-covers-the-flight-square arrows.
    final mask = Float32List(kSegSize * kSegSize);
    _line(mask, 36, 156, 156, 36);
    _disc(mask, 156, 36, 5);

    final ex = extractAnnotations(mask);
    expect(ex.arrows, hasLength(1));
    expect(ex.arrows.single.kind, BoardAnnotationKind.arrow);
    expect(encodeAnnotations(ex.arrows), 'Ab2g7');
    // Cells the shaft crosses carry ink coverage; far corners carry none.
    expect(ex.cellCoverage[49], greaterThan(kAnnotationInkCoverage));
    expect(ex.cellCoverage[14], greaterThan(kAnnotationInkCoverage));
    expect(ex.cellCoverage[0], 0);
    expect(ex.cellCoverage[63], 0);
  });

  test('merges a dashed arrow into one component', () {
    // Vertical dashes (2px gaps) from e4 up to e7 — the broken pawn-path
    // arrows. The 3x3 dilation bridges the gaps, so one arrow comes back.
    final mask = Float32List(kSegSize * kSegSize);
    _line(mask, 108, 108, 108, 36, dashOn: 6, dashOff: 2);
    _disc(mask, 108, 36, 5);

    final ex = extractAnnotations(mask);
    expect(ex.arrows, hasLength(1));
    expect(encodeAnnotations(ex.arrows), 'Ae4e7');
  });

  test('ignores compact blobs and speckle', () {
    final mask = Float32List(kSegSize * kSegSize);
    // A compact 10x10 blob (a printed letter box) and a 2px speck.
    for (var y = 60; y < 70; y++) {
      for (var x = 60; x < 70; x++) {
        mask[y * kSegSize + x] = 1.0;
      }
    }
    mask[100 * kSegSize + 100] = 1.0;
    mask[100 * kSegSize + 101] = 1.0;
    expect(extractAnnotations(mask).arrows, isEmpty);
  });

  test('ignores board-frame slivers along the image border', () {
    // A full-height 2px column at x=0 — elongated like an arrow, but it is
    // leftover frame ink (seen on real Fischer crops).
    final mask = Float32List(kSegSize * kSegSize);
    for (var y = 0; y < kSegSize; y++) {
      mask[y * kSegSize] = 1.0;
      mask[y * kSegSize + 1] = 1.0;
    }
    expect(extractAnnotations(mask).arrows, isEmpty);
  });

  test('extracts nothing from a diffusely noisy mask (old-print scans)', () {
    // Hatched/engraved sample-book boards light 3.7%+ of the mask; a real
    // arrow (which would otherwise be found) must not be fitted to that noise.
    final mask = Float32List(kSegSize * kSegSize);
    _line(mask, 36, 156, 156, 36);
    _disc(mask, 156, 36, 5);
    var speckle = 0;
    for (var i = 7; i < mask.length && speckle < 1400; i += 26) {
      if (mask[i] == 0) {
        mask[i] = 1.0;
        speckle++;
      }
    }
    expect(extractAnnotations(mask).arrows, isEmpty);
  });

  test('drops an arrow whose endpoints share a cell', () {
    // Elongated but short: fits inside one 24px cell after mapping.
    final mask = Float32List(kSegSize * kSegSize);
    _line(mask, 50, 50, 68, 68, width: 1);
    expect(extractAnnotations(mask).arrows, isEmpty);
  });

  group('orientArrows', () {
    const arrow = BoardAnnotationKind.arrow;
    final labels = List<String>.filled(64, '')
      ..[10] = 'K'
      ..[20] = 'Q';

    test('flips an arrow that points from an empty square into a piece', () {
      // The Fischer king-flees arrows: the ink test picked the empty flight
      // square as origin, but the piece end must be the origin.
      expect(orientArrows([const BoardAnnotation(arrow, 30, 10)], labels),
          [const BoardAnnotation(arrow, 10, 30)]);
    });

    test('keeps piece → empty and ambiguous arrows unchanged', () {
      expect(
          orientArrows([
            const BoardAnnotation(arrow, 10, 30), // piece → empty
            const BoardAnnotation(arrow, 10, 20), // piece → piece
            const BoardAnnotation(arrow, 40, 50), // empty → empty
          ], labels),
          [
            const BoardAnnotation(arrow, 10, 30),
            const BoardAnnotation(arrow, 10, 20),
            const BoardAnnotation(arrow, 40, 50),
          ]);
    });
  });

  group('encode/decode', () {
    test('round-trips all kinds', () {
      final anns = [
        const BoardAnnotation(BoardAnnotationKind.arrow, 49, 14),
        const BoardAnnotation(BoardAnnotationKind.dashedArrow, 36, 12),
        const BoardAnnotation.mark(0),
        const BoardAnnotation.mark(63),
      ];
      final encoded = encodeAnnotations(anns);
      expect(encoded, 'Ab2g7;De4e7;Xa8;Xh1');
      expect(decodeAnnotations(encoded), anns);
    });

    test('drops malformed tokens instead of throwing', () {
      expect(decodeAnnotations('Ab2g7;;Zx9;Ae2e2;Xj9;Xd5'),
          [const BoardAnnotation(BoardAnnotationKind.arrow, 49, 14),
           const BoardAnnotation.mark(27)]);
    });
  });
}
