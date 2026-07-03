import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/core/state/board_loader.dart';
import 'package:chess_reader/features/vision/domain/board_repair.dart';
import 'package:chess_reader/features/vision/domain/fen_assembler.dart';

/// Class index order — mirrors `squareLabels` / model.py `CLASSES`.
const _idx = {
  'K': 0, 'Q': 1, 'R': 2, 'B': 3, 'N': 4, 'P': 5, //
  'k': 6, 'q': 7, 'r': 8, 'b': 9, 'n': 10, 'p': 11, //
  '': 12,
};

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

/// One prob row per cell: [conf] (default 0.95) on the cell's own label, the
/// rest on [nextBest] (default empty). When the label is empty all mass sits on
/// empty, matching the classifier's emptiness gate.
List<Float32List> _probs(
  List<String> labels, {
  Map<int, double> conf = const {},
  Map<int, String> nextBest = const {},
}) {
  return List.generate(64, (i) {
    final row = Float32List(13);
    final top = conf[i] ?? 0.95;
    row[_idx[labels[i]]!] = top;
    row[_idx[nextBest[i] ?? '']!] += 1 - top;
    return row;
  });
}

int _count(List<String> labels, String label) =>
    labels.where((l) => l == label).length;

void main() {
  test('three white kings collapse to the most-confident one', () {
    // White "kings" on c1/c3/e1 (cells 56, 58, 60); only e1 is real.
    final labels = _labels('4k3/8/8/8/8/8/8/K1K1K3');
    final probs = _probs(
      labels,
      conf: {56: 0.6, 58: 0.7, 60: 0.9},
      nextBest: {56: 'Q', 58: 'R'},
    );

    final out = repairToLegal(labels, probs);

    expect(_count(out, 'K'), 1);
    expect(out[60], 'K', reason: 'highest-confidence king is kept');
    expect(out[56], 'Q');
    expect(out[58], 'R');
    expect(out[4], 'k', reason: 'the lone black king is untouched');
  });

  test('three black kings collapse to the most-confident one', () {
    final labels = _labels('k1k1k3/8/8/8/8/8/8/4K3');
    final probs = _probs(
      labels,
      conf: {0: 0.9, 2: 0.7, 4: 0.6},
      nextBest: {2: 'r', 4: 'q'},
    );

    final out = repairToLegal(labels, probs);

    expect(_count(out, 'k'), 1);
    expect(out[0], 'k');
    expect(out[2], 'r');
    expect(out[4], 'q');
  });

  test('pawns on the first and last rank are removed', () {
    // 'P' on a8 (cell 0) and 'p' on h1 (cell 63) — both impossible.
    final labels = _labels('P3k3/8/8/8/8/8/8/4K2p');
    final probs = _probs(labels, nextBest: {63: 'R'});

    final out = repairToLegal(labels, probs);

    expect(out[0], '', reason: 'back-rank pawn falls back to empty');
    expect(out[63], isNot('p'));
    expect(out[63], 'R');
    expect(_count(out, 'P'), 0);
    expect(_count(out, 'p'), 0);
  });

  test('a ninth pawn is demoted, keeping the eight most confident', () {
    // Eight white pawns on rank 6 (cells 16-23) plus a ninth on rank 5 (cell
    // 24), which reads weakest.
    final labels = _labels('4k3/8/PPPPPPPP/P7/8/8/8/4K3');
    final probs = _probs(labels, conf: {24: 0.5});

    final out = repairToLegal(labels, probs);

    expect(_count(out, 'P'), 8);
    expect(out[24], '', reason: 'the lowest-confidence surplus pawn goes');
  });

  test('a legal board is returned unchanged', () {
    for (final placement in [
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR',
      '4k3/8/8/8/8/8/4P3/3RK3',
    ]) {
      final labels = _labels(placement);
      final out = repairToLegal(labels, _probs(labels));
      expect(out, labels, reason: placement);
    }
  });

  test('missing or malformed classProbs is a no-op', () {
    final labels = _labels('4k3/8/8/8/8/8/8/K1K1K3'); // illegal: three kings
    expect(repairToLegal(labels, null), labels);
    expect(repairToLegal(labels, const <Float32List>[]), labels);
  });

  test('an extra king never cascades into an illegal extra pawn', () {
    // White already has its full eight pawns (rank 2, cells 48-55). An extra
    // king on c1 reads next-best as a pawn — repair must NOT turn it into a 9th
    // pawn, because demotions skip pawns entirely.
    final labels = _labels('4k3/8/8/8/8/8/PPPPPPPP/K1K1K3');
    final probs = _probs(
      labels,
      conf: {56: 0.6, 58: 0.7, 60: 0.9},
      nextBest: {56: 'P', 58: 'P'},
    );

    final out = repairToLegal(labels, probs);

    expect(_count(out, 'K'), 1);
    expect(_count(out, 'P'), 8, reason: 'no king became a pawn');
    expect(out[56], isNot('P'));
    expect(out[56], isNot('K'));
  });

  test('a third rook with all eight pawns is materially impossible, so the '
      'weakest rook is demoted', () {
    // White has all eight pawns (rank 2) AND three rooks: a1/h1 are real, a8 is
    // a phantom read inside Black's camp (the "understanding-chess-openings"
    // failure). With no missing pawns, no promotion could explain a 3rd rook.
    final labels = _labels('R3k3/8/8/8/8/8/PPPPPPPP/R3K2R');
    final probs = _probs(
      labels,
      conf: {0: 0.55, 56: 0.95, 63: 0.95},
      nextBest: {0: 'r'},
    );

    final out = repairToLegal(labels, probs);

    expect(_count(out, 'R'), 2, reason: 'the impossible third rook is demoted');
    expect(out[0], 'r', reason: 'lowest-confidence rook falls to its next-best');
    expect(out[56], 'R');
    expect(out[63], 'R');
    expect(tryLoadFen(assembleFen(out))!.legal, isTrue);
  });

  test('a third rook is kept when missing pawns could have promoted into it', () {
    // Only six white pawns, so two pawns are off the board — a promoted rook is
    // materially possible. Repair must NOT touch a legal-if-rare reading.
    final labels = _labels('R3k3/8/8/8/8/8/PPPPPP2/R3K2R');
    final out = repairToLegal(labels, _probs(labels));

    expect(_count(out, 'R'), 3, reason: 'within the promotion budget');
    expect(out, labels);
  });

  test('two same-colour kings with the other colour missing: one flips', () {
    // Old-print white kings are routinely misread as black (and vice versa):
    // the reading has two black kings and no white one. Demoting the weaker
    // to an officer would both invent a phantom piece and leave White
    // king-less; flipping its colour repairs both at once.
    final labels = _labels('k7/8/8/8/8/8/8/6k1');
    final probs = _probs(labels, conf: {0: 0.9, 62: 0.6});
    // The g1 "black king" carries some white-king mass — it IS the white king.
    probs[62][_idx['K']!] = 0.3;

    final out = repairToLegal(labels, probs);

    expect(out[0], 'k', reason: 'the confident black king stays');
    expect(out[62], 'K', reason: 'the weaker one flips to the missing colour');
  });

  test('a surplus king adjacent to the kept king is bleed, not a piece', () {
    // A castled king's ink bleeds into the neighbouring cell on tight old-print
    // grids, reading as a second adjacent king. That cell is really empty —
    // demoting to next-best would print a phantom officer there instead.
    final labels = _labels('4k3/8/8/8/8/8/8/R4KK1');
    final probs = _probs(
      labels,
      conf: {56: 0.95, 61: 0.55, 62: 0.9},
      nextBest: {61: 'R'}, // next-best would hallucinate a rook on f1
    );

    final out = repairToLegal(labels, probs);

    expect(out[62], 'K', reason: 'the real castled king is kept');
    expect(out[61], '', reason: 'the bleed cell is cleared, not demoted');
    expect(_count(out, 'R'), 1, reason: 'no phantom rook appears');
  });

  test('repaired reading becomes engine-analysable end to end', () {
    // A real sparse endgame with one square (a8) misread as a second white king.
    final labels = _labels('4k3/8/8/8/8/8/4P3/3RK3');
    labels[0] = 'K';
    final probs = _probs(labels, conf: {0: 0.6, 60: 0.95});

    // Before repair the FEN has two white kings — not a legal position.
    expect(tryLoadFen(assembleFen(labels))!.legal, isFalse);

    // After repair it loads as a legal position the engine can analyse.
    final repaired = repairToLegal(labels, probs);
    final loaded = tryLoadFen(assembleFen(repaired));
    expect(loaded, isNotNull);
    expect(loaded!.legal, isTrue);
    expect(repaired[0], '', reason: 'the misread second king is gone');
  });
}
