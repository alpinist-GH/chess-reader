import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A candidate chess diagram found on a page image, in pixel coordinates.
class LocatedBoard {
  const LocatedBoard({
    required this.left,
    required this.top,
    required this.size,
  });

  final int left;
  final int top;

  /// Boards are square; size is the side length.
  final int size;
}

/// Finds printed chess diagrams on a page raster.
///
/// Classical CV, pure Dart: printed diagrams are axis-aligned, high-contrast
/// squares with a connected dark frame (or dark-square fill), so a connected-
/// component scan over the thresholded image finds them as large, square-ish
/// components. No perspective handling — that's the camera pipeline's job
/// (future), which will replace this stage behind the same interface.
abstract class BoardLocator {
  List<LocatedBoard> locate(img.Image page);
}

class ConnectedComponentBoardLocator implements BoardLocator {
  const ConnectedComponentBoardLocator({
    this.minRelativeSize = 0.18,
    this.maxAspectError = 0.12,
  });

  /// Minimum board side relative to the page's shorter dimension.
  final double minRelativeSize;

  /// Allowed |width-height|/size deviation from a perfect square.
  final double maxAspectError;

  @override
  List<LocatedBoard> locate(img.Image page) {
    // Detection runs at full resolution: printed board frames are only 1–2px
    // wide, so downscaling blends them into the background and the board stops
    // being one connected component (real diagrams get dropped). Speed instead
    // comes from a packed luminance buffer below — getPixel() per pixel is the
    // slow path on multi-megapixel pages.
    final gray = img.grayscale(img.Image.from(page));
    final w = gray.width, h = gray.height;
    // One byte per pixel (red channel == luminance after grayscale).
    final lum = gray.getBytes(order: img.ChannelOrder.red);
    final threshold = _otsu(lum);

    // Two-pass connected-component labeling over dark pixels with union-find.
    final labels = List<int>.filled(w * h, 0);
    final parent = <int>[0];
    int find(int x) {
      var root = x;
      while (parent[root] != root) {
        root = parent[root];
      }
      while (parent[x] != root) {
        final next = parent[x];
        parent[x] = root;
        x = next;
      }
      return root;
    }

    void union(int a, int b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[rb] = ra;
    }

    var nextLabel = 1;
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        if (lum[row + x] >= threshold) continue;
        final left = x > 0 ? labels[row + x - 1] : 0;
        final up = y > 0 ? labels[row - w + x] : 0;
        if (left == 0 && up == 0) {
          labels[row + x] = nextLabel;
          parent.add(nextLabel);
          nextLabel++;
        } else if (left != 0 && up != 0) {
          labels[row + x] = left;
          union(left, up);
        } else {
          labels[row + x] = left != 0 ? left : up;
        }
      }
    }

    // Collect component bounding boxes.
    final minX = <int, int>{}, minY = <int, int>{};
    final maxX = <int, int>{}, maxY = <int, int>{};
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        final raw = labels[row + x];
        if (raw == 0) continue;
        final root = find(raw);
        minX.update(root, (v) => v < x ? v : x, ifAbsent: () => x);
        maxX.update(root, (v) => v > x ? v : x, ifAbsent: () => x);
        minY.update(root, (v) => v < y ? v : y, ifAbsent: () => y);
        maxY.update(root, (v) => v > y ? v : y, ifAbsent: () => y);
      }
    }

    final minSide = (w < h ? w : h) * minRelativeSize;
    final boards = <LocatedBoard>[];
    for (final label in minX.keys) {
      final bw = maxX[label]! - minX[label]! + 1;
      final bh = maxY[label]! - minY[label]! + 1;
      final size = (bw + bh) ~/ 2;
      if (size < minSide) continue;
      if ((bw - bh).abs() / size > maxAspectError) continue;
      boards.add(LocatedBoard(left: minX[label]!, top: minY[label]!, size: size));
    }
    // Largest first; drop boards nested inside another (frame + fill can
    // produce two components for the same diagram).
    boards.sort((a, b) => b.size.compareTo(a.size));
    final result = <LocatedBoard>[];
    for (final b in boards) {
      final nested = result.any((r) =>
          b.left >= r.left - r.size ~/ 16 &&
          b.top >= r.top - r.size ~/ 16 &&
          b.left + b.size <= r.left + r.size + r.size ~/ 16 &&
          b.top + b.size <= r.top + r.size + r.size ~/ 16);
      if (!nested) result.add(b);
    }

    // Broken-frame fallback: some printed frames (e.g. Chess Fundamentals'
    // hatched-square diagrams) are drawn as four edges that don't quite join at
    // the corners, so no single component spans the board and the scan above
    // finds nothing. When that happens, stitch the board back from its frame
    // edges — the long thin strips whose bounding boxes, unioned, recover the
    // square. This runs only when nothing was found, so it can't change the
    // result for any diagram already located.
    if (result.isEmpty) {
      final recovered =
          _recoverBrokenFrame(minX, maxX, minY, maxY, minSide);
      if (recovered != null) result.add(recovered);
    }
    return result;
  }

  /// Recovers a board whose frame is broken into disconnected edge strips: take
  /// every component long enough to be a frame edge (at least [minSide] in one
  /// dimension) and union their bounding boxes. If the union is a large enough
  /// square, that's the board. Returns null when the strips don't form one.
  LocatedBoard? _recoverBrokenFrame(Map<int, int> minX, Map<int, int> maxX,
      Map<int, int> minY, Map<int, int> maxY, double minSide) {
    var x0 = 1 << 30, y0 = 1 << 30, x1 = -1, y1 = -1;
    var found = false;
    for (final label in minX.keys) {
      final bw = maxX[label]! - minX[label]! + 1;
      final bh = maxY[label]! - minY[label]! + 1;
      if (bw < minSide && bh < minSide) continue; // not a frame edge
      found = true;
      if (minX[label]! < x0) x0 = minX[label]!;
      if (minY[label]! < y0) y0 = minY[label]!;
      if (maxX[label]! > x1) x1 = maxX[label]!;
      if (maxY[label]! > y1) y1 = maxY[label]!;
    }
    if (!found) return null;
    final bw = x1 - x0 + 1;
    final bh = y1 - y0 + 1;
    final size = (bw + bh) ~/ 2;
    if (size < minSide) return null;
    if ((bw - bh).abs() / size > maxAspectError) return null;
    return LocatedBoard(left: x0, top: y0, size: size);
  }

  /// Otsu's threshold over the luminance histogram.
  int _otsu(Uint8List lum) {
    final hist = List<int>.filled(256, 0);
    for (var i = 0; i < lum.length; i++) {
      hist[lum[i]]++;
    }
    final total = lum.length;
    var sum = 0.0;
    for (var i = 0; i < 256; i++) {
      sum += i * hist[i];
    }
    var sumB = 0.0, wB = 0, best = 0.0;
    var threshold = 127;
    for (var i = 0; i < 256; i++) {
      wB += hist[i];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += i * hist[i];
      final mB = sumB / wB;
      final mF = (sum - sumB) / wF;
      final between = wB * wF * (mB - mF) * (mB - mF);
      if (between > best) {
        best = between;
        threshold = i;
      }
    }
    return threshold;
  }
}
