/// Repairs structurally-illegal board readings by reusing the square CNN's own
/// per-cell class distribution — the information `OnnxSquareClassifier` already
/// computes and would otherwise throw away.
///
/// The per-square classifier reads each cell independently and greedily, so a
/// real diagram misread on a square or two routinely produces a FEN that no
/// engine can analyse: three kings, a pawn on the back rank, nine pawns. A
/// per-square model can never prevent this — "one king per side" is a *global*
/// constraint it never sees. So we enforce the hard constraints here, after the
/// fact, by demoting the *lowest-confidence offending* squares to their
/// next-best class until the board is structurally legal.
///
/// This is deterministic, runs in microseconds, and is model-agnostic: it works
/// on whatever softmax the classifier emits today and keeps working if the model
/// is retrained or swapped. It only ever *demotes* a misread square — it never
/// invents a piece — so a genuinely king-less reading stays king-less and is
/// handled downstream by the display-only fallback (`tryLoadFen`).
library;

import 'dart:typed_data';

import 'square_classifier.dart';

/// Label → class index, the single source of truth being [squareLabels]
/// (which mirrors `CLASSES` in tool/vision_train/model.py).
final Map<String, int> _labelIndex = {
  for (var i = 0; i < squareLabels.length; i++) squareLabels[i]: i,
};

final int _emptyIndex = _labelIndex['']!;
final int _whiteKing = _labelIndex['K']!;
final int _blackKing = _labelIndex['k']!;
final int _whitePawn = _labelIndex['P']!;
final int _blackPawn = _labelIndex['p']!;

/// The non-king, non-pawn pieces ("officers") of each side and the count each
/// side starts with. A side can only exceed these by promoting its own pawns,
/// and every promotion costs one pawn — so the surplus officers a reading may
/// hold is bounded by that side's missing pawns (8 − pawns on the board). A
/// board with three rooks and all eight pawns is therefore materially
/// impossible, however the per-square model labelled it.
const _whiteOfficers = ['Q', 'R', 'B', 'N'];
const _blackOfficers = ['q', 'r', 'b', 'n'];
const _officerStdMax = {
  'Q': 1, 'R': 2, 'B': 2, 'N': 2, //
  'q': 1, 'r': 2, 'b': 2, 'n': 2, //
};

/// A class a misread square may be demoted to: never a king or a pawn. Because
/// every demotion lands on a king/pawn-free class (Q/R/B/N or empty), repair can
/// never *create* a king or pawn — so the king, back-rank and pawn-count rules
/// can't feed one another. (A square the model reads most-confidently as a king
/// or pawn is never genuinely the *other*, so excluding both costs nothing in
/// practice.) The material cap adds its own no-new-surplus guard (see
/// [_capPromotedMaterial]), so the fixed-point loop still settles in a pass or
/// two.
bool _demotable(int c) =>
    c != _whiteKing &&
    c != _blackKing &&
    c != _whitePawn &&
    c != _blackPawn;

/// Returns a NEW 64-label list (rank 8 → rank 1, file a → h) in which the hard
/// structural constraints below hold. Never mutates [labels].
///
/// Returns [labels] unchanged when [classProbs] is absent or malformed — repair
/// needs the per-cell distribution to choose a next-best class. [classProbs]
/// must be 64 rows, each a softmax over [squareLabels] (see
/// `BoardClassification.classProbs`).
///
/// Constraints enforced, each by demoting the lowest-confidence offenders:
///  * at most one white king and one black king;
///  * no pawn on rank 1 (row 7) or rank 8 (row 0);
///  * at most eight white pawns and eight black pawns;
///  * no more surplus officers (queens/rooks/bishops/knights beyond the
///    starting count) per side than that side's missing pawns could have
///    promoted into — see [_officerStdMax].
///
/// Keys off the post-emptiness-gate [labels], not `argmax(classProbs)`: a cell
/// the classifier forced to empty carries `''` here even though its prob row may
/// peak on a piece, and must be treated as empty rather than an offender.
List<String> repairToLegal(List<String> labels, List<Float32List>? classProbs) {
  assert(labels.length == 64);
  if (classProbs == null || classProbs.length != 64) return labels;

  final out = List<String>.of(labels);

  // Every demotion lands on a king/pawn-free class (see [_demotable]), so no
  // pass can create work for another: this converges in a single pass. The loop
  // and bound are a cheap safety net that also absorbs the final no-op pass.
  var iterations = 0;
  bool changed;
  do {
    changed = false;
    changed |= _capKings(out, classProbs, 'K');
    changed |= _capKings(out, classProbs, 'k');
    changed |= _clearBackRankPawns(out, classProbs);
    changed |= _capPawns(out, classProbs, 'P');
    changed |= _capPawns(out, classProbs, 'p');
    // Pawn counts must be final before the material cap reads them (its budget
    // is 8 − pawns), so this runs after the pawn passes.
    changed |= _capPromotedMaterial(out, classProbs, _whiteOfficers, 'P');
    changed |= _capPromotedMaterial(out, classProbs, _blackOfficers, 'p');
  } while (changed && ++iterations < 6);

  return out;
}

/// Keeps the single highest-confidence [king] cell and resolves the rest.
/// Returns whether anything changed.
///
/// Two surplus-king patterns dominate on old-print scans and get targeted
/// fixes instead of a blind next-best demotion (which manufactures a phantom
/// officer on a square that really holds a king or nothing):
///  * the *other* side has no king at all — almost always a colour misread
///    (faint ink turns a white king black or vice versa), so one surplus king
///    is flipped to the missing colour rather than demoted;
///  * a surplus king *adjacent* to the kept king — the kept king's ink bled
///    into the neighbouring cell (castled kings on tight grids do this
///    constantly), so the cell is really empty and is cleared outright.
bool _capKings(List<String> out, List<Float32List> probs, String king) {
  final kingIdx = _labelIndex[king]!;
  final other = king == 'K' ? 'k' : 'K';
  final otherIdx = _labelIndex[other]!;
  final cells = _cellsLabelled(out, king);
  if (cells.length <= 1) return false;
  _sortByConfidenceAsc(cells, probs, kingIdx);
  final keep = cells.removeLast(); // the most-confident king stays

  if (_cellsLabelled(out, other).isEmpty) {
    // Flip the surplus cell that most resembles the missing-colour king.
    var flip = cells.first;
    for (final cell in cells) {
      if (probs[cell][otherIdx] > probs[flip][otherIdx]) flip = cell;
    }
    out[flip] = other;
    cells.remove(flip);
  }

  for (final cell in cells) {
    if (_adjacentCells(cell, keep)) {
      out[cell] = '';
    } else {
      _demote(out, probs, cell, _demotable);
    }
  }
  return true;
}

/// Whether two row-major cell indices touch (8-neighbourhood).
bool _adjacentCells(int a, int b) =>
    (a ~/ 8 - b ~/ 8).abs() <= 1 && (a % 8 - b % 8).abs() <= 1;

/// Demotes every pawn sitting on the first or last rank (always illegal).
bool _clearBackRankPawns(List<String> out, List<Float32List> probs) {
  var changed = false;
  for (var i = 0; i < 64; i++) {
    final onBackRank = i < 8 || i >= 56; // row 0 (rank 8) or row 7 (rank 1)
    if (!onBackRank) continue;
    if (out[i] == 'P' || out[i] == 'p') {
      _demote(out, probs, i, _demotable);
      changed = true;
    }
  }
  return changed;
}

/// Keeps the eight highest-confidence [pawn] cells, demoting any beyond eight.
bool _capPawns(List<String> out, List<Float32List> probs, String pawn) {
  final pawnIdx = _labelIndex[pawn]!;
  final cells = _cellsLabelled(out, pawn);
  if (cells.length <= 8) return false;
  _sortByConfidenceAsc(cells, probs, pawnIdx);
  final demoteCount = cells.length - 8; // the lowest-confidence surplus
  for (var k = 0; k < demoteCount; k++) {
    _demote(out, probs, cells[k], _demotable);
  }
  return true;
}

/// Demotes surplus officers (queens/rooks/bishops/knights beyond the starting
/// count) that exceed what [pawn]-promotions could account for. The side may
/// keep `8 − pawns` promoted officers; any further surplus is materially
/// impossible, so its lowest-confidence members are demoted lowest-first.
///
/// A demotion never lands on a king/pawn, never recreates the same officer, and
/// never lands on a piece already at its own [_officerStdMax] (which would just
/// relocate the impossibility) — so no pass can manufacture a new surplus and
/// the outer fixed-point loop settles quickly.
bool _capPromotedMaterial(
  List<String> out,
  List<Float32List> probs,
  List<String> ownOfficers,
  String pawn,
) {
  var budget = 8 - _cellsLabelled(out, pawn).length;
  if (budget < 0) budget = 0;

  // The promotion-only surplus: per type, the lowest-confidence cells beyond
  // its starting count (the highest-confidence ones are kept).
  final surplus = <int>[];
  for (final officer in ownOfficers) {
    final cells = _cellsLabelled(out, officer);
    final std = _officerStdMax[officer]!;
    if (cells.length <= std) continue;
    _sortByConfidenceAsc(cells, probs, _labelIndex[officer]!);
    surplus.addAll(cells.take(cells.length - std));
  }
  if (surplus.length <= budget) return false;

  // Globally lowest-confidence surplus first, so the least-certain reads go.
  surplus.sort((a, b) {
    final c = probs[a][_labelIndex[out[a]]!].compareTo(probs[b][_labelIndex[out[b]]!]);
    return c != 0 ? c : a.compareTo(b);
  });

  final demoteCount = surplus.length - budget;
  for (var k = 0; k < demoteCount; k++) {
    final cell = surplus[k];
    final typeIdx = _labelIndex[out[cell]]!;
    // `_roomy` reads the live [out], which we mutate as we go, so a target that
    // fills up mid-loop stops being offered.
    _demote(out, probs, cell,
        (c) => _demotable(c) && c != typeIdx && _roomy(out, c));
  }
  return true;
}

/// Whether class [c] has room for one more piece without itself exceeding
/// [_officerStdMax]. Non-officers (only empty reaches here, post-[_demotable])
/// always have room.
bool _roomy(List<String> out, int c) {
  final label = squareLabels[c];
  final std = _officerStdMax[label];
  if (std == null) return true;
  return _cellsLabelled(out, label).length < std;
}

List<int> _cellsLabelled(List<String> out, String label) {
  final cells = <int>[];
  for (var i = 0; i < 64; i++) {
    if (out[i] == label) cells.add(i);
  }
  return cells;
}

/// Ascending by the cell's confidence in [classIdx]; ties broken by cell index
/// for deterministic output.
void _sortByConfidenceAsc(List<int> cells, List<Float32List> probs, int classIdx) {
  cells.sort((a, b) {
    final c = probs[a][classIdx].compareTo(probs[b][classIdx]);
    return c != 0 ? c : a.compareTo(b);
  });
}

/// Reassigns [cell] to its highest-probability class that passes [allowed],
/// with empty as the guaranteed terminal fallback, so the result always differs
/// from the offending class.
void _demote(
  List<String> out,
  List<Float32List> probs,
  int cell,
  bool Function(int c) allowed,
) {
  out[cell] = squareLabels[_nextBest(probs[cell], allowed)];
}

int _nextBest(Float32List p, bool Function(int c) allowed) {
  var bestIdx = _emptyIndex;
  var bestVal = -1.0;
  for (var c = 0; c < p.length; c++) {
    if (c == _emptyIndex || !allowed(c)) continue;
    if (p[c] > bestVal) {
      bestVal = p[c];
      bestIdx = c;
    }
  }
  if (allowed(_emptyIndex) && p[_emptyIndex] > bestVal) return _emptyIndex;
  return bestIdx;
}
