import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'board_locator.dart';

/// Side length, in pixels, of one preprocessed cell fed to the model.
/// MUST match `CELL` in tool/vision_train/model.py.
const int kCellSize = 32;

/// Side length of the board image fed to the arrow segmenter.
/// MUST match `SEG_SIZE` in tool/vision_train/seg_model.py.
const int kSegSize = 192;

/// Crops [board] from [page] to the area inside its printed frame, then slices
/// it into 64 cell images in row-major order (rank 8 → rank 1, file a → h).
///
/// Frame removal matters: a few pixels of grid-line drift puts a
/// high-contrast sliver of the neighbouring square into every cell and wrecks
/// classification. Edge rows/cols that are almost entirely dark (the frame
/// line) are peeled before slicing.
List<img.Image> sliceBoardCells(img.Image page, LocatedBoard board) =>
    sliceInner(cropInsideFrame(page, board));

/// Slices the already frame-cropped [inner] board into 64 cell images.
List<img.Image> sliceInner(img.Image inner) {
  final cell = inner.width / 8;
  final cells = <img.Image>[];
  for (var r = 0; r < 8; r++) {
    for (var f = 0; f < 8; f++) {
      cells.add(img.copyCrop(
        inner,
        x: (f * cell).round(),
        y: (r * cell).round(),
        width: cell.round(),
        height: cell.round(),
      ));
    }
  }
  return cells;
}

/// Grayscale → [kSegSize]² → normalize to [-1, 1]. The whole inside-frame board
/// fed to the arrow segmenter (which was trained on frame-free boards, so it
/// sees the same content). Replicates the training preprocessing.
Float32List preprocessSegInput(img.Image inner) {
  final small = img.copyResize(
    img.grayscale(img.Image.from(inner)),
    width: kSegSize,
    height: kSegSize,
    // Area averaging — see preprocessCell. (Big downscale here too.)
    interpolation: img.Interpolation.average,
  );
  final out = Float32List(kSegSize * kSegSize);
  var i = 0;
  for (final p in small) {
    out[i++] = (p.r / 255.0 - 0.5) / 0.5;
  }
  return out;
}

/// Grayscale → [kCellSize]² → normalize to [-1, 1].
///
/// This must replicate the training preprocessing exactly
/// (tool/vision_train/dataset.py): `(gray/255 - 0.5) / 0.5`.
Float32List preprocessCell(img.Image cell) {
  // Downsample each ~4×-larger cell with AREA averaging. The classifier is a
  // tiny (~150k-param) CNN that is sensitive to the downsample method: cells
  // built with copyResize's default (nearest) or a plain (non-antialiased)
  // bilinear alias on this 4× reduction and misread engraving-font glyphs
  // (white queen → black, pawn → bishop, rook colour flips). PIL's antialiased
  // BILINEAR used to make the training cells behaves like an area filter, which
  // `Interpolation.average` matches — and which reads these correctly.
  final small = img.copyResize(
    img.grayscale(img.Image.from(cell)),
    width: kCellSize,
    height: kCellSize,
    interpolation: img.Interpolation.average,
  );
  final out = Float32List(kCellSize * kCellSize);
  var i = 0;
  for (final p in small) {
    out[i++] = (p.r / 255.0 - 0.5) / 0.5;
  }
  return out;
}

img.Image cropInsideFrame(img.Image page, LocatedBoard board) {
  final gray = img.grayscale(img.copyCrop(
    page,
    x: board.left,
    y: board.top,
    width: board.size,
    height: board.size,
  ));
  final n = gray.width;
  final maxPeel = n ~/ 8;

  double rowDarkness(int y) {
    var dark = 0;
    for (var x = 0; x < n; x++) {
      if (gray.getPixel(x, y).r < 128) dark++;
    }
    return dark / n;
  }

  double colDarkness(int x) {
    var dark = 0;
    for (var y = 0; y < gray.height; y++) {
      if (gray.getPixel(x, y).r < 128) dark++;
    }
    return dark / gray.height;
  }

  var top = 0, bottom = gray.height - 1, left = 0, right = n - 1;
  while (top < maxPeel && rowDarkness(top) > 0.8) {
    top++;
  }
  while (bottom > gray.height - maxPeel && rowDarkness(bottom) > 0.8) {
    bottom--;
  }
  while (left < maxPeel && colDarkness(left) > 0.8) {
    left++;
  }
  while (right > n - maxPeel && colDarkness(right) > 0.8) {
    right--;
  }

  // The dark-edge peel stops at a white gap, so a frame drawn as thick line +
  // gap + thin inner line leaves the grid offset by up to ~half a cell. Fit the
  // 8x8 lattice to the checkerboard to trim what is left.
  final pw = right - left + 1, ph = bottom - top + 1;
  final px = Uint8List(pw * ph);
  for (var y = 0; y < ph; y++) {
    for (var x = 0; x < pw; x++) {
      px[y * pw + x] = gray.getPixel(left + x, top + y).r.toInt();
    }
  }
  final rect = refineGridRect(px, pw, ph);

  return img.copyCrop(
    page,
    x: board.left + left + rect.left,
    y: board.top + top + rect.top,
    width: rect.right - rect.left,
    height: rect.bottom - rect.top,
  );
}

/// Sub-rectangle `(left, top, right, bottom)` (right/bottom exclusive) of a
/// frame-peeled board [gray] (row-major, [w]x[h]) whose 8x8 cell means best fit
/// an alternating light/dark checkerboard. Hatched or filled dark squares are
/// always darker than light ones; pieces only perturb a few cells.
///
/// MUST mirror `refine_rect_scaled` in tool/vision_train/grid_refine.py: the
/// search runs on a block-mean copy no larger than ~352px, then maps back.
({int left, int top, int right, int bottom}) refineGridRect(
    Uint8List gray, int w, int h) {
  const maxTrim = 0.6, step = 2, searchSide = 352;
  final k = math.max(1, (math.min(w, h) / searchSide).round());
  final sw = w ~/ k, sh = h ~/ k;
  // Block-mean downscale.
  final small = Float64List(sw * sh);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      var sum = 0;
      for (var dy = 0; dy < k; dy++) {
        final row = (y * k + dy) * w + x * k;
        for (var dx = 0; dx < k; dx++) {
          sum += gray[row + dx];
        }
      }
      small[y * sw + x] = (sum / (k * k)).floorToDouble();
    }
  }
  // Integral image, (sh+1) x (sw+1).
  final iw = sw + 1;
  final ii = Float64List(iw * (sh + 1));
  for (var y = 0; y < sh; y++) {
    var rowSum = 0.0;
    for (var x = 0; x < sw; x++) {
      rowSum += small[y * sw + x];
      ii[(y + 1) * iw + x + 1] = ii[y * iw + x + 1] + rowSum;
    }
  }
  double box(int x0, int y0, int x1, int y1) =>
      ii[y1 * iw + x1] - ii[y0 * iw + x1] - ii[y1 * iw + x0] + ii[y0 * iw + x0];

  final mx = (sw / 8 * maxTrim).floor(), my = (sh / 8 * maxTrim).floor();
  var best = -1.0;
  var bx0 = 0, by0 = 0, bx1 = sw, by1 = sh;
  final xs = List<int>.filled(9, 0), ys = List<int>.filled(9, 0);
  for (var x0 = 0; x0 <= mx; x0 += step) {
    for (var x1 = sw - mx; x1 <= sw; x1 += step) {
      for (var i = 0; i < 9; i++) {
        xs[i] = (x0 + (x1 - x0) * i / 8).round();
      }
      for (var y0 = 0; y0 <= my; y0 += step) {
        for (var y1 = sh - my; y1 <= sh; y1 += step) {
          for (var i = 0; i < 9; i++) {
            ys[i] = (y0 + (y1 - y0) * i / 8).round();
          }
          var score = 0.0;
          for (var r = 0; r < 8; r++) {
            for (var f = 0; f < 8; f++) {
              final area = (xs[f + 1] - xs[f]) * (ys[r + 1] - ys[r]);
              if (area <= 0) continue;
              final m = box(xs[f], ys[r], xs[f + 1], ys[r + 1]) / area;
              score += (r + f).isEven ? m : -m;
            }
          }
          score = score.abs();
          if (score > best) {
            best = score;
            bx0 = x0;
            by0 = y0;
            bx1 = x1;
            by1 = y1;
          }
        }
      }
    }
  }
  return (
    left: bx0 * k,
    top: by0 * k,
    right: math.min(w, bx1 * k),
    bottom: math.min(h, by1 * k),
  );
}
