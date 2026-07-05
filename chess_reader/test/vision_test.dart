import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:chess_reader/features/vision/data/vision_service.dart';
import 'package:chess_reader/features/vision/domain/board_locator.dart';
import 'package:chess_reader/features/vision/domain/fen_assembler.dart';
import 'package:chess_reader/features/vision/domain/square_classifier.dart';

/// Locates the chessground package in the pub cache to read piece PNGs
/// (tests cannot use rootBundle for package assets).
Directory _chessgroundDir() {
  final env = Platform.environment;
  final cache = env['PUB_CACHE'] ??
      (Platform.isWindows
          ? p.join(env['LOCALAPPDATA'] ?? '', 'Pub', 'Cache')
          : p.join(env['HOME'] ?? '', '.pub-cache'));
  final hosted = Directory(p.join(cache, 'hosted', 'pub.dev'));
  final candidates = hosted
      .listSync()
      .whereType<Directory>()
      .where((d) => p.basename(d.path).startsWith('chessground-'))
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  return candidates.first;
}

Future<Uint8List> _loadPiece(String id) async {
  final base = _chessgroundDir().path;
  for (final rel in [
    p.join('assets', 'piece_sets', 'merida', '$id.png'),
    p.join('lib', 'piece_sets', 'merida', '$id.png'),
  ]) {
    final f = File(p.join(base, rel));
    if (f.existsSync()) return f.readAsBytes();
  }
  fail('merida piece $id.png not found under $base');
}

const _lightSquare = 0xF0D9B5;
const _darkSquare = 0xB58863;

img.Color _rgb(int rgb) =>
    img.ColorRgb8((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);

/// Draws a chess diagram for [placement] (FEN board field) onto [page].
Future<void> _drawDiagram(
  img.Image page,
  String placement, {
  required int left,
  required int top,
  required int size,
}) async {
  // Frame.
  img.fillRect(page,
      x1: left - 2,
      y1: top - 2,
      x2: left + size + 1,
      y2: top + size + 1,
      color: _rgb(0x000000));
  final cell = size ~/ 8;
  final ranks = placement.split('/');
  for (var r = 0; r < 8; r++) {
    var f = 0;
    final cells = <String?>[];
    for (final ch in ranks[r].split('')) {
      final skip = int.tryParse(ch);
      if (skip != null) {
        cells.addAll(List.filled(skip, null));
      } else {
        cells.add(ch);
      }
    }
    for (f = 0; f < 8; f++) {
      final x = left + f * cell, y = top + r * cell;
      img.fillRect(page,
          x1: x,
          y1: y,
          x2: x + cell - 1,
          y2: y + cell - 1,
          color: _rgb((r + f).isEven ? _lightSquare : _darkSquare));
      final piece = cells[f];
      if (piece != null) {
        final id =
            (piece.toUpperCase() == piece ? 'w' : 'b') + piece.toUpperCase();
        final png = img.decodePng(await _loadPiece(id))!;
        final resized = img.copyResize(png, width: cell, height: cell);
        img.compositeImage(page, resized, dstX: x, dstY: y);
      }
    }
  }
}

void main() {
  test('assembleFen builds placement, castling and side', () {
    final labels = List<String>.filled(64, '');
    labels[0 * 8 + 4] = 'k'; // e8
    labels[7 * 8 + 4] = 'K'; // e1
    labels[7 * 8 + 0] = 'R'; // a1
    labels[7 * 8 + 7] = 'R'; // h1
    expect(assembleFen(labels, whiteToMove: false),
        '4k3/8/8/8/8/8/8/R3K2R b KQ - 0 1');
  });

  test('full pipeline: synthetic page -> located diagram -> exact FEN',
      () async {
    const placement = 'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R';

    final page = img.Image(width: 800, height: 1000);
    img.fill(page, color: _rgb(0xFFFFFF));
    await _drawDiagram(page, placement, left: 150, top: 200, size: 400);

    final service = VisionService(
      locator: const ConnectedComponentBoardLocator(),
      classifier: TemplateSquareClassifier(_loadPiece),
    );
    final anchors = await service.scanPage(page);

    expect(anchors, hasLength(1));
    expect(anchors.single.board.size, closeTo(404, 8));
    expect(anchors.single.fen, '$placement w KQkq - 0 1');
  });

  test('empty board is rejected, not read as random pieces', () async {
    final page = img.Image(width: 800, height: 1000);
    img.fill(page, color: _rgb(0xFFFFFF));
    // A framed, checkerboarded board with no pieces on it.
    await _drawDiagram(page, '8/8/8/8/8/8/8/8', left: 150, top: 200, size: 400);

    final service = VisionService(
      locator: const ConnectedComponentBoardLocator(),
      classifier: TemplateSquareClassifier(_loadPiece),
    );
    final anchors = await service.scanPage(page);

    expect(anchors, isEmpty);
  });

  test('locates a board whose frame is broken at the corners', () {
    // Chess Fundamentals prints hatched-square diagrams whose four frame edges
    // don't join at the corners, so no single component spans the board. The
    // edges are drawn with a gap at each corner; the locator must still recover
    // the square from the disconnected strips.
    const left = 150, top = 200, size = 400, gap = 12;
    final page = img.Image(width: 800, height: 1000);
    img.fill(page, color: _rgb(0xFFFFFF));
    final black = _rgb(0x000000);
    // A few grey marks inside (stand-ins for pieces) so the luminance histogram
    // isn't a degenerate two-level black/white — real scans always have a grey
    // spread, and Otsu needs one to pick a sensible threshold.
    for (var i = 0; i < 4; i++) {
      final cx = left + 80 + i * 70;
      img.fillRect(page,
          x1: cx, y1: top + 150, x2: cx + 30, y2: top + 190,
          color: _rgb(0x808080));
    }
    // Top and bottom edges, inset by [gap] at both ends.
    img.fillRect(page,
        x1: left + gap, y1: top, x2: left + size - gap, y2: top + 2,
        color: black);
    img.fillRect(page,
        x1: left + gap,
        y1: top + size - 2,
        x2: left + size - gap,
        y2: top + size,
        color: black);
    // Left and right edges, inset by [gap] at both ends.
    img.fillRect(page,
        x1: left, y1: top + gap, x2: left + 2, y2: top + size - gap,
        color: black);
    img.fillRect(page,
        x1: left + size - 2,
        y1: top + gap,
        x2: left + size,
        y2: top + size - gap,
        color: black);

    final boards = const ConnectedComponentBoardLocator().locate(page);
    expect(boards, hasLength(1));
    expect(boards.single.left, closeTo(left, gap + 2));
    expect(boards.single.top, closeTo(top, gap + 2));
    expect(boards.single.size, closeTo(size, 2 * gap + 4));
  });
}
