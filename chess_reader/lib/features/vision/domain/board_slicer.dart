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

  return img.copyCrop(
    page,
    x: board.left + left,
    y: board.top + top,
    width: right - left + 1,
    height: bottom - top + 1,
  );
}
