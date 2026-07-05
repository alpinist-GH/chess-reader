/// Decides whether a classified 8x8 grid is a real, populated chess diagram
/// worth emitting — or a false positive (an empty board grid, a photo/figure,
/// or any large square dark blob the locator picked up) that should be dropped.
///
/// The board locator accepts any large square-ish dark region, and the square
/// classifier always forces every cell to *some* class. Without this gate an
/// empty board surfaces as a diagram full of random pieces.
///
/// Crucially, this is NOT a chess-legality check. The square CNN misreads a few
/// squares on real book diagrams (e.g. it reads a bishop as a king, so a real
/// position routinely comes back with two or three "kings" per side and 33+
/// "pieces"). Rejecting those would throw away genuine, only-slightly-wrong
/// diagrams — which is exactly the regression we must avoid. So we only
/// distinguish *populated board* from *empty / noise*: enough men, at least one
/// king, not a wall of pieces, and (on the ONNX path) decent mean confidence.
library;

/// Minimum non-empty squares for a grid to count as a populated diagram.
/// Teaching books print genuinely tiny positions — Capablanca's Chess
/// Fundamentals opens with three-man basic mates (K+R vs K) and even a
/// two-man knight-vs-bishop comparison diagram — so the floor only rejects
/// empty/one-mark grids; [kSparseMinMeanConfidence] guards the sparse range.
const int kMinPieces = 2;

/// Boards in the sparse/king-less range ([kMinPieces]..3 pieces, or no king)
/// are accepted only when the classifier read them this confidently. Real
/// sparse teaching diagrams measure 0.95+ mean top-class probability; noise
/// regions the locator picked up read far lower. Without confidences (the
/// template path) such boards stay rejected, as before.
const double kSparseMinMeanConfidence = 0.85;

/// Piece count below which a board counts as "sparse" and must pass
/// [kSparseMinMeanConfidence] rather than being taken structurally.
const int kSparsePieces = 4;

/// A real position has at most 32 men. The square model misreads a few squares
/// on real diagrams, so we allow generous slack above 32; the cap only rejects
/// "wall of pieces" noise regions where nearly every square reads as a piece
/// (e.g. the template classifier on an unfamiliar font, or a photo/figure).
const int kMaxPieces = 40;

/// A real position can't hold more than this many of any single piece class
/// (8 pawns per colour is the natural max; the model's misreads add a little —
/// real boards top out around 9). Far beyond it means a wall of identical
/// marks: the move-illustration diagrams in teaching books (e.g. Bobby Fischer
/// Teaches Chess) tag every reachable square with an "x", which the CNN reads as
/// a row of identical phantom pieces (~18 "kings"). Those aren't game positions,
/// so the whole board is dropped rather than emitted full of phantoms.
const int kMaxSameClass = 12;

/// Below this mean top-class probability the grid is almost certainly not a
/// board (the model is guessing). Real diagrams score ~0.95. Only applied when
/// confidences are supplied (the ONNX path); the template classifier reports
/// none, so it relies on the structural checks alone.
const double kMinMeanConfidence = 0.5;

/// Whether [labels] (64 FEN letters, '' for empty) describe a plausible,
/// populated diagram. When [confidences] (64 per-cell top-class probabilities)
/// is given, also requires a decent mean — what rejects low-confidence
/// non-board regions.
bool isPlausibleDiagram(List<String> labels, {List<double>? confidences}) {
  assert(labels.length == 64);

  var pieces = 0;
  var kings = 0;
  final counts = <String, int>{};
  for (final label in labels) {
    if (label.isEmpty) continue;
    pieces++;
    if (label == 'K' || label == 'k') kings++;
    final n = (counts[label] ?? 0) + 1;
    counts[label] = n;
    // A single class repeated far past any legal count: a wall of identical
    // marks (move-illustration "x"s), not a position.
    if (n > kMaxSameClass) return false;
  }

  if (pieces < kMinPieces || pieces > kMaxPieces) return false;

  final mean = (confidences != null && confidences.isNotEmpty)
      ? confidences.reduce((a, b) => a + b) / confidences.length
      : null;

  // Sparse and king-less boards are common in teaching books (basic-mate and
  // pawn-structure diagrams), so they aren't rejected structurally — but they
  // are also what a few stray misreads on a noise region look like, so they
  // must be read with high confidence. We deliberately do NOT cap kings per
  // side: the model over-detects kings on real boards, and dropping those
  // would lose genuine diagrams.
  if (kings == 0 || pieces < kSparsePieces) {
    if (mean == null || mean < kSparseMinMeanConfidence) return false;
  }

  if (mean != null && mean < kMinMeanConfidence) return false;

  return true;
}

/// Minimum squares a K/P confusion partner must hold before it is swept up
/// with an x-mark wall (see [clearAnnotatedPhantoms]) — a single K or P next
/// to a wall may be a real piece and is left alone.
const int kMinWallPartner = 2;

/// If any class repeats past [kMaxSameClass] — a wall of identical phantom
/// pieces minted from printed training marks (the "x"s of move-illustration
/// diagrams) — clears those squares to empty and reports them, so the diagram
/// can be emitted with visible ✕ annotations instead of dropped by
/// [isPlausibleDiagram]'s same-class cap.
///
/// Measured on the Fischer scans at the conversion's 200 dpi, an x-wall never
/// reads as one clean class: the "x" glyph splits between white KING and PAWN
/// (21×K + 6×P on one board, 13×P + 10×K on the next). So a wall in either of
/// those two classes also clears the other when it holds at least
/// [kMinWallPartner] squares — otherwise half the wall survives as phantoms.
///
/// Any other board comes back unchanged with nothing cleared: ordinary books
/// never repeat a class past the cap (it was added *for* these teaching
/// diagrams), so Lasker/Bird-class books can't enter the branch. Callers
/// re-run the unchanged [isPlausibleDiagram] on the cleaned labels; whether a
/// cleared square is rendered as a printed ✕ or was just arrow ink is decided
/// by the caller from the segmenter mask (`kAnnotationInkCoverage`).
({List<String> labels, List<int> cleared}) clearAnnotatedPhantoms(
    List<String> labels) {
  assert(labels.length == 64);
  final counts = <String, int>{};
  for (final label in labels) {
    if (label.isEmpty) continue;
    counts[label] = (counts[label] ?? 0) + 1;
  }
  final walls = <String>{
    for (final e in counts.entries)
      if (e.value > kMaxSameClass) e.key,
  };
  if (walls.isEmpty) return (labels: labels, cleared: const []);
  if (walls.contains('K') || walls.contains('P')) {
    for (final partner in const ['K', 'P']) {
      if ((counts[partner] ?? 0) >= kMinWallPartner) walls.add(partner);
    }
  }

  final cleaned = List.of(labels);
  final cleared = <int>[];
  for (var i = 0; i < 64; i++) {
    if (walls.contains(cleaned[i])) {
      cleaned[i] = '';
      cleared.add(i);
    }
  }
  return (labels: cleaned, cleared: cleared);
}
