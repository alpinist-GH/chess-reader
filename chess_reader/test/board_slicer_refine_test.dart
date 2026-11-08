import 'dart:typed_data';

import 'package:chess_reader/features/vision/domain/board_slicer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A 8x8 checkerboard (dark squares 60, light 240) of [cell] px squares,
  // surrounded by [pad] px of frame area: dark line, white gap, thin dark line.
  Uint8List board({required int cell, required int pad}) {
    final side = cell * 8 + pad * 2;
    final px = Uint8List(side * side)..fillRange(0, side * side, 240);
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final bx = x - pad, by = y - pad;
        if (bx >= 0 && by >= 0 && bx < cell * 8 && by < cell * 8) {
          px[y * side + x] = ((bx ~/ cell) + (by ~/ cell)).isEven ? 240 : 60;
        } else if (x == pad - 3 || y == pad - 3 || x == side - pad + 2 ||
            y == side - pad + 2) {
          px[y * side + x] = 30; // thin inner frame line past a white gap
        }
      }
    }
    return px;
  }

  test('refineGridRect trims the frame gap to the true 8x8 lattice', () {
    const cell = 40, pad = 14;
    final side = cell * 8 + pad * 2;
    final r = refineGridRect(board(cell: cell, pad: pad), side, side);
    // Search step is 2px, so allow that much slack around the true edges.
    expect(r.left, closeTo(pad, 2));
    expect(r.top, closeTo(pad, 2));
    expect(r.right, closeTo(side - pad, 2));
    expect(r.bottom, closeTo(side - pad, 2));
  });

  test('refineGridRect leaves an already-tight board alone', () {
    const cell = 40;
    final side = cell * 8;
    final r = refineGridRect(board(cell: cell, pad: 0), side, side);
    expect(r.left, 0);
    expect(r.top, 0);
    expect(r.right, side);
    expect(r.bottom, side);
  });
}
