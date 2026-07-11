import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../domain/board_locator.dart';
import '../domain/board_slicer.dart';

/// Sendable scan input: raw page pixels (BGRA from pdfrx).
class ExtractRequest {
  const ExtractRequest({
    required this.bgra,
    required this.width,
    required this.height,
  });

  final Uint8List bgra;
  final int width;
  final int height;
}

/// One located board with its 64 preprocessed cells (row-major, each
/// [kCellSize]² floats) ready for the model, plus a PNG crop of the board
/// region (for the HTML reading view). Sendable across isolates.
class ExtractedBoard {
  const ExtractedBoard({
    required this.left,
    required this.top,
    required this.size,
    required this.cells,
    required this.segInput,
    required this.cropPng,
  });

  final int left;
  final int top;
  final int size;
  final Float32List cells;

  /// The whole inside-frame board, grayscale [kSegSize]², for the arrow
  /// segmenter (the mask it produces is sliced into per-cell channels).
  final Float32List segInput;

  /// PNG encoding of the located board region, cropped from the source image.
  final Uint8List cropPng;
}

List<ExtractedBoard> _extractFromImage(img.Image page) {
  const locator = ConnectedComponentBoardLocator();
  const cellLen = kCellSize * kCellSize;

  final boards = <ExtractedBoard>[];
  for (final board in locator.locate(page)) {
    final inner = cropInsideFrame(page, board);
    final cells = sliceInner(inner);
    final packed = Float32List(64 * cellLen);
    for (var i = 0; i < 64; i++) {
      packed.setRange(i * cellLen, (i + 1) * cellLen, preprocessCell(cells[i]));
    }
    final segInput = preprocessSegInput(inner);
    // Crop the board region (clamped to the image) and encode as PNG.
    final cw = (board.left + board.size > page.width)
        ? page.width - board.left
        : board.size;
    final ch = (board.top + board.size > page.height)
        ? page.height - board.top
        : board.size;
    final crop = img.copyCrop(
      page,
      x: board.left,
      y: board.top,
      width: cw,
      height: ch,
    );
    boards.add(ExtractedBoard(
      left: board.left,
      top: board.top,
      size: board.size,
      cells: packed,
      segInput: segInput,
      cropPng: img.encodePng(crop),
    ));
  }
  return boards;
}

List<ExtractedBoard> _extract(ExtractRequest request) {
  final page = img.Image.fromBytes(
    width: request.width,
    height: request.height,
    bytes: request.bgra.buffer,
    bytesOffset: request.bgra.offsetInBytes,
    order: img.ChannelOrder.bgra,
  );
  return _extractFromImage(page);
}

List<ExtractedBoard> _extractEncoded(Uint8List bytes) {
  final page = img.decodeImage(bytes);
  if (page == null) return const [];
  return _extractFromImage(page);
}

/// Locates diagrams and preprocesses their cells off the UI thread. The
/// returned tensors are classified by the ONNX model on the main isolate.
Future<List<ExtractedBoard>> extractBoardsInIsolate(ExtractRequest request) =>
    compute(_extract, request);

/// Same as [extractBoardsInIsolate] but for an encoded image (PNG/JPEG/GIF),
/// e.g. an EPUB `<img>` — decoded inside the isolate.
Future<List<ExtractedBoard>> extractBoardsFromEncodedInIsolate(
        Uint8List bytes) =>
    compute(_extractEncoded, bytes);
