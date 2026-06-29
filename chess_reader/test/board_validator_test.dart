import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/features/vision/domain/board_validator.dart';

/// Builds 64 labels from a FEN board-placement field (rank 8 → rank 1).
List<String> _labels(String placement) {
  final out = <String>[];
  for (final rank in placement.split('/')) {
    for (final ch in rank.split('')) {
      final skip = int.tryParse(ch);
      if (skip != null) {
        out.addAll(List.filled(skip, ''));
      } else {
        out.add(ch);
      }
    }
  }
  assert(out.length == 64, 'got ${out.length}');
  return out;
}

void main() {
  test('accepts a real starting position', () {
    expect(
      isPlausibleDiagram(
          _labels('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR')),
      isTrue,
    );
  });

  test('accepts a sparse endgame above the piece floor', () {
    // 4 men (k, P, R, K): a real, deliberately sparse endgame.
    expect(isPlausibleDiagram(_labels('4k3/8/8/8/8/8/4P3/3RK3')), isTrue);
  });

  // The square model misreads a few squares on real book diagrams (e.g. a
  // bishop as a king), so a genuine position routinely comes back with extra
  // kings and 33+ pieces. These MUST be accepted — dropping them was the
  // regression. Cases mirror real reads measured from a real opening book.
  test('accepts a real board misread with multiple kings per side', () {
    expect(
      isPlausibleDiagram(
          _labels('rnkqkknr/pppppppp/8/8/8/8/PPPPPPPP/RNKQKKNR')),
      isTrue,
    );
  });

  test('accepts a populated board with more than 32 pieces', () {
    // 33 pieces (a misread turned one empty square into a piece): still a board.
    final labels = _labels('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR');
    labels[35] = 'N';
    expect(labels.where((l) => l.isNotEmpty).length, 33);
    expect(isPlausibleDiagram(labels), isTrue);
  });

  test('rejects an empty board', () {
    expect(isPlausibleDiagram(_labels('8/8/8/8/8/8/8/8')), isFalse);
  });

  test('rejects a near-empty grid below the piece floor', () {
    // A couple of stray misreads on a blank region (3 men) — not a diagram.
    expect(isPlausibleDiagram(_labels('4k3/8/8/8/8/8/4P3/4K3')), isFalse);
    expect(isPlausibleDiagram(_labels('4k3/8/8/8/8/8/8/8')), isFalse);
  });

  test('rejects a grid with no king', () {
    expect(isPlausibleDiagram(_labels('rnbq1bnr/pppppppp/8/8/8/8/8/8')),
        isFalse);
  });

  test('rejects a wall of pieces (every square read as a piece)', () {
    // The template classifier on an unfamiliar font reads all 64 squares as
    // pieces; no real board does. The max-pieces cap rejects it.
    expect(isPlausibleDiagram(List.filled(64, 'N')..[0] = 'K'), isFalse);
  });

  test('rejects a move-illustration diagram (wall of identical "x" marks)', () {
    // Teaching books mark every square a piece can reach with an "x"; the CNN
    // reads each as the same phantom piece. Mirrors a real read of the queen
    // move-illustration in Bobby Fischer Teaches Chess (~18 "kings", one queen).
    final labels = List.filled(64, '');
    for (var i = 0; i < 18; i++) {
      labels[i] = 'K';
    }
    labels[36] = 'Q';
    expect(isPlausibleDiagram(labels), isFalse);
  });

  test('still accepts a full board of 8 pawns per side', () {
    // The per-class cap must not reject legitimate pawn counts.
    expect(
      isPlausibleDiagram(
          _labels('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR')),
      isTrue,
    );
  });

  test('rejects a board read with low mean confidence', () {
    final labels = _labels('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR');
    expect(
      isPlausibleDiagram(labels,
          confidences: List.filled(64, 0.2)),
      isFalse,
    );
    expect(
      isPlausibleDiagram(labels,
          confidences: List.filled(64, 0.95)),
      isTrue,
    );
  });
}
