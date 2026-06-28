import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../../../core/onnx/onnx_session_options.dart';
import '../domain/ctc_decoder.dart';
import '../domain/ocr_box.dart';
import '../domain/reading_order.dart';
import '../domain/text_detector.dart';
import '../domain/text_page_recognizer.dart';
import 'ocr_isolate.dart';
import 'ocr_model_locator.dart';

/// PP-OCR mobile detection (v3) + recognition (v4) model file names, exported to
/// ONNX. The v4 recognizer is a drop-in upgrade over v3 — same size and
/// character dictionary, but measurably fewer errors on degraded scans.
///
/// These are bundled on **desktop only** (resolved via [locateOcrModel]); mobile
/// uses the device's native recognizer, so the models are not shipped there.
const String kOcrDetFile = 'ocr_det.onnx';
const String kOcrRecFile = 'ocr_rec.onnx';

/// Recognition character dictionary (one char per line). The full class list is
/// `['<blank>', ...keys, ' ']` — index 0 is the CTC blank, a trailing space is
/// appended, matching PaddleOCR's decoding convention.
const String kOcrKeysFile = 'ocr_keys.txt';

/// Reads the body text of a rendered page with a two-stage ONNX OCR pipeline
/// (DBNet detector → CRNN/SVTR recognizer + greedy CTC decode), entirely on
/// device. Used to give scanned/image-only PDFs a text layer so the reflowed
/// reading view (and search/move resolution) work.
///
/// Constructs cheaply; the ONNX sessions and dictionary load lazily (and once,
/// memoized) on first [recognizePage], so a conversion that hits the cache or
/// has a usable text layer never pays the load cost — mirrors
/// [DiagramRecognizer]. Platform-channel based (flutter_onnxruntime), so it
/// must live on the main isolate; the heavy pixel preprocessing runs in
/// `compute()` isolates (see ocr_isolate.dart).
class OcrTextRecognizer implements TextPageRecognizer {
  OcrTextRecognizer();

  _OcrModels? _models;
  Future<_OcrModels?>? _loadFuture;

  final TextDetector _detector = const TextDetector();

  /// Serializes ONNX inference: preprocessing runs in parallel isolates, but a
  /// single ORT session must not have overlapping `run` calls. Mirrors
  /// `DiagramRecognizer`'s gate.
  Future<void> _gate = Future.value();

  Future<_OcrModels?> _ensure() {
    return _loadFuture ??= () async {
      _models = await _OcrModels.tryLoad();
      return _models;
    }();
  }

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _gate.then((_) => action());
    _gate = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Recognizes the page body text from a rendered page (BGRA pixels, e.g. from
  /// pdfrx). Returns the empty string if the models are unavailable or no text
  /// lines are found.
  @override
  Future<String> recognizePage({
    required Uint8List bgra,
    required int width,
    required int height,
  }) async {
    final models = await _ensure();
    if (models == null) return '';

    // 1. Detection: build input off-thread, run DBNet, post-process to boxes.
    final detInput = await buildDetInputInIsolate(
        OcrDetRequest(bgra: bgra, width: width, height: height));
    final probMap = await _locked(() => models.runDet(detInput));
    final boxes = _detector
        .detect(probMap, detInput.inWidth, detInput.inHeight)
        .map((b) => b.scaled(detInput.scaleX, detInput.scaleY))
        .where((b) => b.width > 0 && b.height > 0)
        .toList();
    if (boxes.isEmpty) return '';

    // 2. Recognition: crop+normalize each line off-thread, run CRNN per strip.
    final inputs = await buildRecInputsInIsolate(
        OcrRecRequest(bgra: bgra, width: width, height: height, boxes: boxes));
    final lines = <RecognizedLine>[];
    for (var i = 0; i < inputs.length; i++) {
      final text = await _locked(() => models.runRec(inputs[i]));
      lines.add(RecognizedLine(box: boxes[i], text: text));
    }
    return linesToPageText(lines);
  }

  @override
  Future<void> dispose() async {
    await _loadFuture; // wait for any in-flight load so we close the real session
    await _models?.dispose();
    _models = null;
    _loadFuture = null;
  }
}

/// The loaded ONNX sessions + decoder. Separated so the public recognizer can
/// construct cheaply and load these lazily.
class _OcrModels {
  _OcrModels(this._det, this._detInput, this._rec, this._recInput, this._decoder);

  final OrtSession _det;
  final String _detInput;
  final OrtSession _rec;
  final String _recInput;
  final CtcDecoder _decoder;

  static Future<_OcrModels?> tryLoad() async {
    try {
      final detPath = locateOcrModel(kOcrDetFile);
      final recPath = locateOcrModel(kOcrRecFile);
      final keysPath = locateOcrModel(kOcrKeysFile);
      if (detPath == null || recPath == null || keysPath == null) return null;
      final rt = OnnxRuntime();
      final opts = acceleratedSessionOptions();
      final det = await rt.createSession(detPath, options: opts);
      final rec = await rt.createSession(recPath, options: opts);
      final detIn = det.inputNames.isNotEmpty ? det.inputNames.first : 'x';
      final recIn = rec.inputNames.isNotEmpty ? rec.inputNames.first : 'x';
      return _OcrModels(
          det, detIn, rec, recIn, CtcDecoder(await _loadVocab(keysPath)));
    } catch (_) {
      // Models/dictionary absent or runtime unavailable: caller falls back to
      // the (empty) text layer, exactly as before OCR existed.
      return null;
    }
  }

  static Future<List<String>> _loadVocab(String path) async {
    final raw = await File(path).readAsString();
    final keys = raw
        .split('\n')
        .map((l) => l.replaceAll('\r', ''))
        .where((l) => l.isNotEmpty)
        .toList();
    return ['<blank>', ...keys, ' '];
  }

  /// Runs the detector; returns a flat `[inHeight, inWidth]` probability map.
  Future<Float32List> runDet(OcrDetInput input) async {
    final value = await OrtValue.fromList(
        input.tensor, [1, 3, input.inHeight, input.inWidth]);
    try {
      final outputs = await _det.run({_detInput: value});
      final out = outputs.values.first;
      final flat = (await out.asFlattenedList()).cast<num>();
      for (final v in outputs.values) {
        await v.dispose();
      }
      // DBNet output is [1, 1, H, W]; take the single channel as-is.
      final map = Float32List(input.inHeight * input.inWidth);
      for (var i = 0; i < map.length; i++) {
        map[i] = flat[i].toDouble();
      }
      return map;
    } finally {
      await value.dispose();
    }
  }

  /// Runs the recognizer on one strip and CTC-decodes the result to text.
  Future<String> runRec(OcrRecInput input) async {
    final value = await OrtValue.fromList(
        input.tensor, [1, 3, kRecHeight, input.stripWidth]);
    try {
      final outputs = await _rec.run({_recInput: value});
      final out = outputs.values.first;
      final flat = (await out.asFlattenedList()).cast<num>();
      for (final v in outputs.values) {
        await v.dispose();
      }
      // Output is [1, steps, classes]; classes is fixed by the vocab.
      final classes = _decoder.vocab.length;
      final steps = flat.length ~/ classes;
      final tensor = Float32List(steps * classes);
      for (var i = 0; i < tensor.length; i++) {
        tensor[i] = flat[i].toDouble();
      }
      return _decoder.decode(tensor, steps, classes);
    } finally {
      await value.dispose();
    }
  }

  Future<void> dispose() async {
    await _det.close();
    await _rec.close();
  }
}
