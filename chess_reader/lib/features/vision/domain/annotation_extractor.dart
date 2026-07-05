/// Recovers drawn-arrow geometry from the arrow segmenter's per-pixel mask.
///
/// The segmenter (see `OnnxSquareClassifier`) marks annotation strokes over
/// the whole board; until now that mask was only used as the classifier's
/// second input channel and then discarded. Teaching books (Bobby Fischer
/// Teaches Chess) draw arrows the reader wants to SEE, so this walks the mask
/// once more and turns each elongated connected component into a
/// [BoardAnnotation] arrow (from-square → to-square).
///
/// Typographic "x" marks do NOT reach the mask (verified on the Fischer scans:
/// the segmenter ignores them; they surface as runaway phantom-piece labels
/// instead — see `clearAnnotatedPhantoms`), so only arrows are extracted here.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'board_annotations.dart';
import 'board_slicer.dart';

/// Mask probability above which a pixel counts as annotation ink.
const double _maskThreshold = 0.5;

/// Components smaller than this many (pre-dilation) pixels are speckle.
const int _minComponentPx = 12;

/// An arrow must span at least this many cells' worth of pixels end to end.
/// Deliberately under one cell: the Fischer covers-the-flight-square arrows
/// run as short as 22 px (~0.9 cells) into the adjacent square, and the
/// endpoints-share-a-cell drop below is what actually rejects sub-cell blobs.
const double _minArrowLengthCells = 0.8;

/// Minimum PCA elongation (sqrt of the eigenvalue ratio) for a component to
/// count as a line-like arrow rather than a compact blob.
const double _minElongation = 3.0;

/// Components whose every pixel sits within this many pixels of one image
/// border are leftover board-frame ink, not annotations (the segmenter
/// sometimes lights the frame slivers that survive `cropInsideFrame`).
const int _borderBand = 3;

/// Old-print scans (hatched squares, engraving bleed-through) light the mask
/// diffusely across the whole board: measured 3.7–12% positive pixels on the
/// Chess Fundamentals / Lasker EPUB boards, versus ≤ 2% on real Fischer arrow
/// diagrams. Above this fraction the mask is print noise, and line-fitting it
/// would hang phantom arrows on every old-print diagram — so arrow extraction
/// is skipped entirely (per-cell coverage is still reported).
const double _maxMaskNoiseFraction = 0.028;

/// A cleared phantom square whose cell holds at least this fraction of mask
/// ink was minted by a drawn arrow crossing it, not by a printed "x" (x-marks
/// leave the mask dark), so it must not be rendered as a ✕.
const double kAnnotationInkCoverage = 0.05;

/// Arrows recovered from the segmenter mask plus, per cell, the fraction of
/// annotation-ink pixels — what tells an arrow-phantom square (ink under it)
/// from a printed-x square (none) when phantom walls are cleared.
class ExtractedAnnotations {
  const ExtractedAnnotations(this.arrows, this.cellCoverage);

  final List<BoardAnnotation> arrows;

  /// 64 fractions in [0, 1], row-major from a8 like the classifier labels.
  final List<double> cellCoverage;
}

/// Extracts arrow annotations from a [kSegSize]² sigmoid [mask].
///
/// Dashed arrows come back as [BoardAnnotationKind.arrow] too: the segmenter
/// fills the gaps between dashes, so dash-vs-solid isn't recoverable from the
/// mask alone (the encoding reserves a dashed kind for a future image-based
/// check).
ExtractedAnnotations extractAnnotations(Float32List mask,
    {int size = kSegSize}) {
  assert(mask.length == size * size);
  final binary = Uint8List(size * size);
  var positive = 0;
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] > _maskThreshold) {
      binary[i] = 1;
      positive++;
    }
  }

  final cellPx = size ~/ 8;
  final coverage = List<double>.filled(64, 0);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (binary[y * size + x] != 0) {
        coverage[math.min(y ~/ cellPx, 7) * 8 + math.min(x ~/ cellPx, 7)]++;
      }
    }
  }
  for (var i = 0; i < 64; i++) {
    coverage[i] /= cellPx * cellPx;
  }
  if (positive > _maxMaskNoiseFraction * size * size) {
    return ExtractedAnnotations(const [], coverage);
  }

  // 3×3 dilation so the segments of a dashed arrow merge into one component.
  final dilated = Uint8List(size * size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (binary[y * size + x] == 0) continue;
      final y0 = math.max(0, y - 1), y1 = math.min(size - 1, y + 1);
      final x0 = math.max(0, x - 1), x1 = math.min(size - 1, x + 1);
      for (var yy = y0; yy <= y1; yy++) {
        for (var xx = x0; xx <= x1; xx++) {
          dilated[yy * size + xx] = 1;
        }
      }
    }
  }

  // Connected components over the dilated mask (union-find, 8-connectivity —
  // covered by the left/up/up-left/up-right neighbours in a single pass).
  final labels = Int32List(size * size);
  final parent = <int>[0];
  int find(int a) {
    var root = a;
    while (parent[root] != root) {
      root = parent[root];
    }
    while (parent[a] != root) {
      final next = parent[a];
      parent[a] = root;
      a = next;
    }
    return root;
  }

  void union(int a, int b) {
    final ra = find(a), rb = find(b);
    if (ra != rb) parent[rb] = ra;
  }

  var nextLabel = 1;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (dilated[y * size + x] == 0) continue;
      var label = 0;
      void merge(int nx, int ny) {
        if (nx < 0 || nx >= size || ny < 0) return;
        final n = labels[ny * size + nx];
        if (n == 0) return;
        if (label == 0) {
          label = n;
        } else if (label != n) {
          union(label, n);
        }
      }

      merge(x - 1, y);
      merge(x - 1, y - 1);
      merge(x, y - 1);
      merge(x + 1, y - 1);
      if (label == 0) {
        label = nextLabel++;
        parent.add(label);
      }
      labels[y * size + x] = label;
    }
  }

  // Gather ONLY the pre-dilation pixels per component: dilation exists to
  // connect dashes, but geometry (PCA, endpoints, head density) is cleaner on
  // the raw stroke pixels.
  final pixelsByRoot = <int, List<int>>{};
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final i = y * size + x;
      if (binary[i] == 0) continue;
      (pixelsByRoot[find(labels[i])] ??= <int>[]).add(i);
    }
  }

  final cell = size / 8;
  final out = <BoardAnnotation>[];
  for (final pixels in pixelsByRoot.values) {
    if (pixels.length < _minComponentPx) continue;

    var minX = size, maxX = 0, minY = size, maxY = 0;
    var mx = 0.0, my = 0.0;
    for (final i in pixels) {
      final x = i % size, y = i ~/ size;
      mx += x;
      my += y;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    // Board-frame slivers: everything inside a thin band along one border.
    if (maxX < _borderBand ||
        minX >= size - _borderBand ||
        maxY < _borderBand ||
        minY >= size - _borderBand) {
      continue;
    }
    mx /= pixels.length;
    my /= pixels.length;

    // PCA over the 2×2 pixel covariance.
    var sxx = 0.0, sxy = 0.0, syy = 0.0;
    for (final i in pixels) {
      final dx = i % size - mx, dy = i ~/ size - my;
      sxx += dx * dx;
      sxy += dx * dy;
      syy += dy * dy;
    }
    sxx /= pixels.length;
    sxy /= pixels.length;
    syy /= pixels.length;
    final trHalf = (sxx + syy) / 2;
    final det = math.sqrt(math.pow((sxx - syy) / 2, 2) + sxy * sxy);
    final l1 = trHalf + det, l2 = math.max(trHalf - det, 1e-6);
    final elongation = math.sqrt(l1 / l2);
    if (elongation < _minElongation) continue;

    // Principal axis unit vector.
    double ax, ay;
    if (sxy.abs() > 1e-9) {
      ax = l1 - syy;
      ay = sxy;
    } else {
      ax = sxx >= syy ? 1 : 0;
      ay = sxx >= syy ? 0 : 1;
    }
    final norm = math.sqrt(ax * ax + ay * ay);
    ax /= norm;
    ay /= norm;

    // Extreme pixels along the axis = the two endpoints.
    var minProj = double.infinity, maxProj = double.negativeInfinity;
    var p0x = 0, p0y = 0, p1x = 0, p1y = 0;
    for (final i in pixels) {
      final x = i % size, y = i ~/ size;
      final proj = (x - mx) * ax + (y - my) * ay;
      if (proj < minProj) {
        minProj = proj;
        p0x = x;
        p0y = y;
      }
      if (proj > maxProj) {
        maxProj = proj;
        p1x = x;
        p1y = y;
      }
    }
    if (maxProj - minProj < _minArrowLengthCells * cell) continue;

    // The arrowhead is a filled triangle: its end of the shaft holds more ink
    // than the tail end within the same radius.
    final headRadius = cell / 3;
    var mass0 = 0, mass1 = 0;
    for (final i in pixels) {
      final x = i % size, y = i ~/ size;
      if (_dist2(x, y, p0x, p0y) <= headRadius * headRadius) mass0++;
      if (_dist2(x, y, p1x, p1y) <= headRadius * headRadius) mass1++;
    }
    final headFirst = mass0 > mass1;
    final fromCell = _cellAt(headFirst ? p1x : p0x, headFirst ? p1y : p0y, cell);
    final toCell = _cellAt(headFirst ? p0x : p1x, headFirst ? p0y : p1y, cell);
    if (fromCell == toCell) continue;
    out.add(BoardAnnotation(BoardAnnotationKind.arrow, fromCell, toCell));
  }
  return ExtractedAnnotations(out, coverage);
}

/// Reorients [arrows] so each one points from a piece to its target square.
///
/// The head-vs-tail ink test above is unreliable on short arrows (the
/// segmenter renders head and shaft at nearly uniform width), but the book's
/// arrows always run from a piece toward a square — so when exactly one
/// endpoint cell holds a piece in [labels] (the cleaned 64-label read), that
/// end must be the origin. Arrows between two pieces or two empty squares
/// keep the ink-based direction.
List<BoardAnnotation> orientArrows(
    List<BoardAnnotation> arrows, List<String> labels) {
  assert(labels.length == 64);
  return [
    for (final a in arrows)
      if (a.kind == BoardAnnotationKind.mark ||
          labels[a.from].isNotEmpty ||
          labels[a.to].isEmpty)
        a
      else
        BoardAnnotation(a.kind, a.to, a.from),
  ];
}

int _dist2(int x0, int y0, int x1, int y1) =>
    (x0 - x1) * (x0 - x1) + (y0 - y1) * (y0 - y1);

int _cellAt(int x, int y, double cell) {
  final f = (x / cell).floor().clamp(0, 7);
  final r = (y / cell).floor().clamp(0, 7);
  return r * 8 + f;
}
