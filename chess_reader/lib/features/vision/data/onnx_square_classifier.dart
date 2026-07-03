import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../../../core/onnx/onnx_asset_loader.dart';
import '../../../core/onnx/onnx_session_options.dart';
import '../domain/board_slicer.dart';
import '../domain/square_classifier.dart';

/// Class order MUST match `CLASSES` in tool/vision_train/model.py. Shares the
/// [squareLabels] contract used by the template classifier.
const List<String> kModelClasses = squareLabels;

/// The arrow segmenter (whole board → per-pixel annotation mask) and the
/// 2-channel square classifier that reads each cell from [grayscale, mask] so
/// drawn arrows/boxes are ignored rather than hallucinated into pieces.
const String kArrowSegAsset = 'assets/models/arrow_seg.onnx';
const String kSquareModelAsset = 'assets/models/square_classifier2.onnx';

/// Below this contrast (std-dev of a cell's normalized pixels) a cell is forced
/// to empty regardless of the CNN, so the blank squares of an empty/sparse
/// board don't get hallucinated pieces. Mirrors `TemplateSquareClassifier`'s
/// emptiness gate (its grayscale std-dev 10 ≈ 10/127.5 here, as cells are
/// normalized to [-1, 1] by `preprocessCell`).
const double _emptyStdDev = 0.08;

/// A classified board: 64 FEN labels (row-major) plus, per cell, the model's
/// top-class probability — used to reject non-board regions read with low
/// confidence (see `isPlausibleDiagram`).
class BoardClassification {
  const BoardClassification(this.labels, this.confidences, [this.classProbs]);

  final List<String> labels;
  final List<double> confidences;

  /// Per-cell softmax over [kModelClasses] (64 rows of [kModelClasses].length,
  /// same row-major order as [labels]). Null on the template path. Used only by
  /// legality repair (`repairToLegal`), which redistributes a misread square to
  /// its next-best class.
  final List<Float32List>? classProbs;
}

/// Runs the arrow segmenter then the per-square CNN over a board's 64 cells.
/// The segmenter sees the whole board (multi-square context a per-cell model
/// can't have) and marks annotation strokes; the mask becomes a second input
/// channel so the classifier reads the piece under an arrow, or empty.
///
/// Platform-channel based (flutter_onnxruntime) — must NOT be constructed
/// inside a `compute()` isolate; the heavy cell preprocessing happens there
/// instead and the resulting tensors are classified here.
class OnnxSquareClassifier {
  OnnxSquareClassifier._(this._seg, this._segInput, this._cls, this._clsInput);

  final OrtSession _seg;
  final String _segInput;
  final OrtSession _cls;
  final String _clsInput;

  static Future<OnnxSquareClassifier?> tryLoad() async {
    try {
      final rt = OnnxRuntime();
      final opts = acceleratedSessionOptions();
      // NOT rt.createSessionFromAsset: it reuses a stale temp copy of a model
      // when an update ships new bytes under the same filename (see
      // createOnnxSessionFromAssetVersioned), which kept loading the old
      // classifier and misreading retrained diagrams.
      final seg =
          await createOnnxSessionFromAssetVersioned(rt, kArrowSegAsset, options: opts);
      final cls = await createOnnxSessionFromAssetVersioned(rt, kSquareModelAsset,
          options: opts);
      final segIn = seg.inputNames.isNotEmpty ? seg.inputNames.first : 'board';
      final clsIn = cls.inputNames.isNotEmpty ? cls.inputNames.first : 'cells';
      return OnnxSquareClassifier._(seg, segIn, cls, clsIn);
    } catch (_) {
      // Model assets absent or runtime unavailable: caller falls back.
      return null;
    }
  }

  /// [cells64] holds 64 preprocessed grayscale cells (row-major) concatenated,
  /// each [kCellSize]²; [segInput] is the whole inside-frame board as a
  /// [kSegSize]² grayscale tensor. Returns 64 FEN labels and per-cell data.
  Future<BoardClassification> classifyBoard(
      Float32List cells64, Float32List segInput) async {
    const cellLen = kCellSize * kCellSize;
    assert(cells64.length == 64 * cellLen);
    final mask = await _segmentMask(segInput);

    // Pack the 2-channel classifier input [64, 2, 32, 32]: channel 0 grayscale,
    // channel 1 the arrow mask nearest-upsampled from the segmenter output.
    const seg = kSegSize;
    const segCell = seg ~/ 8; // 24
    final twoCh = Float32List(64 * 2 * cellLen);
    for (var cell = 0; cell < 64; cell++) {
      final r = cell ~/ 8, f = cell % 8;
      final base = cell * 2 * cellLen;
      twoCh.setRange(base, base + cellLen, cells64, cell * cellLen);
      for (var y = 0; y < kCellSize; y++) {
        final sy = r * segCell + (y * segCell) ~/ kCellSize;
        for (var x = 0; x < kCellSize; x++) {
          final sx = f * segCell + (x * segCell) ~/ kCellSize;
          twoCh[base + cellLen + y * kCellSize + x] = mask[sy * seg + sx];
        }
      }
    }

    final input =
        await OrtValue.fromList(twoCh, [64, 2, kCellSize, kCellSize]);
    try {
      final outputs = await _cls.run({_clsInput: input});
      final logitsValue = outputs.values.first;
      final flat = (await logitsValue.asFlattenedList()).cast<num>();
      for (final v in outputs.values) {
        await v.dispose();
      }
      final labels = <String>[];
      final confidences = <double>[];
      final classProbs = <Float32List>[];
      final n = kModelClasses.length;
      for (var cell = 0; cell < 64; cell++) {
        var best = 0;
        var bestVal = flat[cell * n].toDouble();
        for (var c = 1; c < n; c++) {
          final v = flat[cell * n + c].toDouble();
          if (v > bestVal) {
            bestVal = v;
            best = c;
          }
        }
        var sumExp = 0.0;
        for (var c = 0; c < n; c++) {
          sumExp += math.exp(flat[cell * n + c].toDouble() - bestVal);
        }
        final invSum = 1.0 / sumExp;
        final probs = Float32List(n);
        for (var c = 0; c < n; c++) {
          probs[c] = math.exp(flat[cell * n + c].toDouble() - bestVal) * invSum;
        }
        classProbs.add(probs);

        final start = cell * cellLen;
        // Only the low-contrast gate forces empty. The old central-dark-mass
        // gate also swallowed faintly printed white pieces (their ink can be
        // lighter than the gate's dark threshold entirely); since the model is
        // trained on real hatched/bled-through empty cells it distinguishes
        // hatching from pieces on its own.
        final empty = _cellStdDev(cells64, start, cellLen) < _emptyStdDev;
        labels.add(empty ? '' : kModelClasses[best]);
        confidences.add(invSum); // softmax of the winning class
      }
      return BoardClassification(labels, confidences, classProbs);
    } finally {
      await input.dispose();
    }
  }

  /// Runs the segmenter and returns a [kSegSize]² mask in [0, 1] (sigmoid).
  Future<Float32List> _segmentMask(Float32List segInput) async {
    final input =
        await OrtValue.fromList(segInput, [1, 1, kSegSize, kSegSize]);
    try {
      final outputs = await _seg.run({_segInput: input});
      final out = outputs.values.first;
      final flat = (await out.asFlattenedList()).cast<num>();
      for (final v in outputs.values) {
        await v.dispose();
      }
      final mask = Float32List(kSegSize * kSegSize);
      for (var i = 0; i < mask.length; i++) {
        mask[i] = 1.0 / (1.0 + math.exp(-flat[i].toDouble()));
      }
      return mask;
    } finally {
      await input.dispose();
    }
  }

  /// Standard deviation of one cell's normalized pixels in [cells64].
  static double _cellStdDev(Float32List cells64, int start, int len) {
    var mean = 0.0;
    for (var i = 0; i < len; i++) {
      mean += cells64[start + i];
    }
    mean /= len;
    var sumSq = 0.0;
    for (var i = 0; i < len; i++) {
      final d = cells64[start + i] - mean;
      sumSq += d * d;
    }
    return math.sqrt(sumSq / len);
  }

  Future<void> dispose() async {
    await _seg.close();
    await _cls.close();
  }
}
