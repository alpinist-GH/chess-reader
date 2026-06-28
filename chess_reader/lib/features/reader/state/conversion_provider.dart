import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ocr/data/native_text_recognizer.dart';
import '../../ocr/data/onnx_text_recognizer.dart';
import '../../ocr/domain/text_page_recognizer.dart';
import '../../vision/data/diagram_recognizer.dart';
import '../data/book_conversion.dart';

/// Up-front diagram-detection progress per book path, in [0,1].
class ConversionProgress extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => const {};

  void set(String path, double value) {
    state = {...state, path: value};
  }
}

final conversionProgressProvider =
    NotifierProvider<ConversionProgress, Map<String, double>>(
        ConversionProgress.new);

/// Whether [path] is a scanned/image-only PDF (no usable embedded text), decided
/// by a fast text-layer sample with no rendering. Drives the open-book prompt
/// that offers the slow OCR conversion versus keeping the original pages.
final pdfImageOnlyProvider = FutureProvider.family<bool, String>(
    (ref, path) => pdfIsImageOnly(path));

/// Whether a cached conversion already exists for [path] — if so the book opens
/// straight from disk and the OCR prompt is skipped.
final conversionCachedProvider = FutureProvider.family<bool, String>(
    (ref, path) => hasCachedConversion(path));

/// The user's per-path answer to "convert this scanned PDF with OCR?":
/// `true` = run OCR for a reflowed reading view, `false` = keep the original
/// pages only, `null` = not yet answered (the conversion waits). Set by the
/// open-book dialog in the reader.
class OcrDecision extends Notifier<bool?> {
  @override
  bool? build() => null;

  void decide(bool runOcr) => state = runOcr;
}

final ocrDecisionProvider = NotifierProvider.family<OcrDecision, bool?, String>(
    (arg) => OcrDecision());

/// Runs (or loads from disk) the whole-book diagram conversion for [path].
/// The reader awaits this on open and shows a progress bar meanwhile.
final conversionProvider =
    FutureProvider.family<BookConversion, String>((ref, path) async {
  final recognizer = DiagramRecognizer();
  // Mobile uses the device's native OCR (Apple Vision / ML Kit) — faster, more
  // accurate, and lets us ship without the ~13 MB ONNX OCR models. Desktop uses
  // the bundled ONNX pipeline (CoreML-accelerated on macOS). Both are lazily
  // used — only when a page's text layer is sparse — so digital PDFs and cache
  // hits pay nothing for it.
  final TextPageRecognizer ocr = NativeTextRecognizer.isSupported
      ? NativeTextRecognizer()
      : OcrTextRecognizer();
  ref.onDispose(recognizer.dispose);
  ref.onDispose(ocr.dispose);

  // A scanned/image-only PDF is gated behind a user choice, because recovering
  // its text with OCR is slow. Until the open-book dialog records that choice,
  // keep the conversion in a loading state (a never-completing future); the
  // provider re-runs when the decision lands. Cached and digital books skip
  // this entirely and convert straight away.
  final decision = ref.watch(ocrDecisionProvider(path));
  var runOcr = true;
  if (!await ref.watch(conversionCachedProvider(path).future) &&
      await ref.watch(pdfImageOnlyProvider(path).future)) {
    if (decision == null) return Completer<BookConversion>().future;
    runOcr = decision;
  }

  ref.read(conversionProgressProvider.notifier).set(path, 0);
  final conversion = await loadOrConvert(
    path,
    recognizer,
    ocr: runOcr ? ocr : null,
    onProgress: (pr) =>
        ref.read(conversionProgressProvider.notifier).set(path, pr),
  );
  return conversion;
});
