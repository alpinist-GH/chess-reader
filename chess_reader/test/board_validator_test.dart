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

  test('sparse boards need high confidence (basic-mate teaching diagrams)', () {
    // K+P vs K — Chess Fundamentals Fig5. Real sparse diagrams read at ~0.95+
    // mean confidence and must be kept; the same 3 marks on a noise region
    // read much lower (or come from the template path with no confidences)
    // and stay rejected.
    final threeMen = _labels('4k3/8/8/8/8/8/4P3/4K3');
    expect(isPlausibleDiagram(threeMen), isFalse);
    expect(
        isPlausibleDiagram(threeMen, confidences: List.filled(64, 0.7)),
        isFalse);
    expect(
        isPlausibleDiagram(threeMen, confidences: List.filled(64, 0.95)),
        isTrue);
    // A lone king is below the absolute floor no matter how confident.
    expect(
        isPlausibleDiagram(_labels('4k3/8/8/8/8/8/8/8'),
            confidences: List.filled(64, 0.99)),
        isFalse);
  });

  test('king-less boards need high confidence (pawn-structure diagrams)', () {
    // Chess Fundamentals Fig90: a deliberate king-less pawn skeleton.
    final pawnSkeleton = _labels('8/ppp2ppp/4p3/3pP3/3P4/8/PPP2PPP/8');
    expect(isPlausibleDiagram(pawnSkeleton), isFalse);
    expect(
        isPlausibleDiagram(pawnSkeleton, confidences: List.filled(64, 0.7)),
        isFalse);
    expect(
        isPlausibleDiagram(pawnSkeleton, confidences: List.filled(64, 0.95)),
        isTrue);
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

  group('clearAnnotatedPhantoms', () {
    test('clears an x-mark wall into cleared squares (Fischer p13 pattern)', () {
      // On the real scans an x-wall reads as a K/P mix (21 kings + 6 pawns on
      // p13): both classes are cleared, the real queen survives, and the
      // cleaned board (with real confidences) passes the unchanged gate.
      final labels = List.filled(64, '');
      final xSquares = [for (var i = 0; i < 18; i++) i * 3];
      // The x-squares split between K and P like the real read does.
      for (final i in xSquares) {
        labels[i] = i.isEven ? 'K' : 'P';
      }
      // More x-squares reading K, pushing K past the cap; P stays below it
      // and is only swept up as the confusion partner.
      for (var i = 55; i < 62; i++) {
        labels[i] = 'K';
      }
      labels[35] = 'Q';
      labels[7] = 'k'; // a real black king, not a wall class

      final wall = clearAnnotatedPhantoms(labels);
      expect(wall.labels[35], 'Q');
      expect(wall.labels[7], 'k');
      expect(wall.labels.where((l) => l == 'K' || l == 'P'), isEmpty,
          reason: 'the x glyph reads as K or P — both must go');
      expect(wall.labels.where((l) => l.isNotEmpty).length, 2);
      expect(isPlausibleDiagram(labels), isFalse);
      expect(
          isPlausibleDiagram(wall.labels,
              confidences: List.filled(64, 0.95)),
          isTrue);
    });

    test('is the identity on ordinary boards (no >cap repeats)', () {
      final labels =
          _labels('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR');
      final wall = clearAnnotatedPhantoms(labels);
      expect(wall.cleared, isEmpty);
      expect(identical(wall.labels, labels), isTrue);
    });

    test('a lone K next to a P wall is kept (may be a real king)', () {
      final labels = List.filled(64, '');
      for (var i = 0; i < 13; i++) {
        labels[i * 2] = 'P';
      }
      labels[60] = 'K';
      labels[35] = 'R';
      final wall = clearAnnotatedPhantoms(labels);
      expect(wall.labels[60], 'K');
      expect(wall.labels[35], 'R');
      expect(wall.cleared.length, 13);
    });

    test('clears every class past the cap (arrow-phantom rook walls)', () {
      final labels = List.filled(64, '');
      for (var i = 0; i < 14; i++) {
        labels[i] = 'R';
      }
      for (var i = 20; i < 36; i++) {
        labels[i] = 'B';
      }
      final wall = clearAnnotatedPhantoms(labels);
      expect(wall.cleared.length, 30);
      expect(wall.labels.where((l) => l.isNotEmpty), isEmpty);
    });
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
