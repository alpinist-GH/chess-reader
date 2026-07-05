import 'dart:typed_data';

import '../domain/annotation_extractor.dart';
import '../domain/board_annotations.dart';
import '../domain/board_repair.dart';
import '../domain/board_validator.dart';
import '../domain/fen_assembler.dart';
import 'onnx_square_classifier.dart';
import 'vision_isolate.dart';

/// A diagram recognized in an image: where it sits (raster pixels of the
/// source image), the assembled FEN, and a PNG crop of the board region.
class RecognizedDiagram {
  const RecognizedDiagram({
    required this.left,
    required this.top,
    required this.size,
    required this.fen,
    required this.cropPng,
    this.annotations = '',
  });

  final int left;
  final int top;
  final int size;

  /// Empty means "training diagram we could not reconstruct": the reader shows
  /// [cropPng] as printed instead of a rebuilt board.
  final String fen;
  final Uint8List cropPng;

  /// Training annotations (arrows, marked squares) recovered alongside the
  /// position, encoded per `encodeAnnotations`; empty when there are none.
  final String annotations;
}

/// Finds printed chess diagrams in page rasters (PDF) or encoded images
/// (EPUB `<img>`) and assembles a FEN for each. Reuses the shared pipeline:
/// CV board location + cell preprocessing in an isolate, ONNX square
/// classification on the main isolate.
///
/// Holds one lazily-loaded classifier; create one per conversion run and
/// [dispose] it when done.
class DiagramRecognizer {
  OnnxSquareClassifier? _classifier;

  /// Memoized load so concurrent pages (the conversion runs several at once)
  /// share a single classifier instead of each loading the model.
  Future<OnnxSquareClassifier?>? _loadFuture;

  /// Serializes ONNX inference: locating runs in parallel isolates, but the
  /// single ORT session must not have overlapping `run` calls.
  Future<void> _classifyGate = Future.value();

  Future<OnnxSquareClassifier?> _ensureClassifier() {
    return _loadFuture ??= () async {
      _classifier = await OnnxSquareClassifier.tryLoad();
      return _classifier;
    }();
  }

  /// Runs [action] with exclusive access to the ORT session.
  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _classifyGate.then((_) => action());
    // Keep the gate alive regardless of success/failure; swallow here so a
    // failed call doesn't poison the chain (the caller still sees the error).
    _classifyGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Recognizes diagrams in a rendered page (BGRA pixels, e.g. from pdfrx).
  Future<List<RecognizedDiagram>> recognizePage({
    required Uint8List bgra,
    required int width,
    required int height,
  }) async {
    final boards = await extractBoardsInIsolate(
      ExtractRequest(bgra: bgra, width: width, height: height),
    );
    return _classify(boards);
  }

  /// Recognizes diagrams in an encoded image (PNG/JPEG/GIF).
  Future<List<RecognizedDiagram>> recognizeEncoded(Uint8List bytes) async {
    final boards = await extractBoardsFromEncodedInIsolate(bytes);
    return _classify(boards);
  }

  Future<List<RecognizedDiagram>> _classify(
      List<ExtractedBoard> boards) async {
    if (boards.isEmpty) return const [];
    final classifier = await _ensureClassifier();
    if (classifier == null) return const [];
    final out = <RecognizedDiagram>[];
    for (final b in boards) {
      final result =
          await _locked(() => classifier.classifyBoard(b.cells, b.segInput));
      // Training diagrams: a wall of printed "x" marks reads as a runaway class
      // of phantom pieces — clear those squares into ✕ annotations instead of
      // letting the same-class cap drop the board. Drawn arrows are recovered
      // from the segmenter mask so the reader can show them.
      final wall = clearAnnotatedPhantoms(result.labels);
      final ex = result.segMask == null
          ? null
          : extractAnnotations(result.segMask!);
      final arrows = ex == null
          ? const <BoardAnnotation>[]
          : orientArrows(ex.arrows, wall.labels);
      // A cleared square only becomes a printed ✕ when the segmenter saw no
      // ink there: phantom pieces minted under a drawn arrow (the mask lights
      // up) are cleared silently, printed x's (which the mask ignores) marked.
      final marks = [
        for (final c in wall.cleared)
          if ((ex?.cellCoverage[c] ?? 0) < kAnnotationInkCoverage) c,
      ];
      // Drop empty grids, photos/figures and other non-board regions the
      // locator picked up: only emit confidently-read, populated positions.
      final plausible =
          isPlausibleDiagram(wall.labels, confidences: result.confidences);
      if (plausible && isReconstructiblePosition(wall.labels)) {
        // A clean, legal-ish position: rebuild it as an interactive board.
        // Gate on the raw labels (repair must not smuggle noise past the gate),
        // then fix structural illegalities so the FEN is engine-analysable.
        // Repair also corrects castling inference, since a phantom king on
        // e1/e8 no longer survives into assembleFen.
        final repaired = repairToLegal(wall.labels, result.classProbs);
        out.add(RecognizedDiagram(
          left: b.left,
          top: b.top,
          size: b.size,
          fen: assembleFen(repaired),
          cropPng: b.cropPng,
          annotations: encodeAnnotations([
            ...arrows,
            for (final m in marks) BoardAnnotation.mark(m),
          ]),
        ));
      } else if (plausible || _isTrainingBoard(wall, arrows)) {
        // A populated board we can't reconstruct as a real position — a
        // move-illustration teaching diagram (one piece + a fan of "x" marks
        // the CNN reads as phantom pieces), or a training diagram with arrows /
        // letter labels. Keep the printed crop as-is instead of rebuilding it
        // into a nonsensical board (or dropping it). Restricted to plausible or
        // training-evidenced grids so photos/noise don't spam junk crops.
        out.add(RecognizedDiagram(
          left: b.left,
          top: b.top,
          size: b.size,
          fen: '',
          cropPng: b.cropPng,
        ));
      }
    }
    return out;
  }

  /// Whether a gate-rejected board still carries training-diagram evidence
  /// worth showing as a printed crop: a cleared x-mark wall, or at least one
  /// drawn arrow over a populated (not wall-of-noise) grid.
  static bool _isTrainingBoard(
      ({List<String> labels, List<int> cleared}) wall,
      List<BoardAnnotation> arrows) {
    if (wall.cleared.isNotEmpty) return true;
    if (arrows.isEmpty) return false;
    final pieces = wall.labels.where((l) => l.isNotEmpty).length;
    return pieces >= kMinPieces && pieces <= kMaxPieces;
  }

  Future<void> dispose() async {
    // Wait for any in-flight load so we dispose the real session, not null.
    await _loadFuture;
    await _classifier?.dispose();
    _classifier = null;
    _loadFuture = null;
  }
}
