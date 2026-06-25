import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ocr/data/onnx_text_recognizer.dart';
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

/// Runs (or loads from disk) the whole-book diagram conversion for [path].
/// The reader awaits this on open and shows a progress bar meanwhile.
final conversionProvider =
    FutureProvider.family<BookConversion, String>((ref, path) async {
  final recognizer = DiagramRecognizer();
  // Lazily-loaded: the OCR models are only loaded when a page's text layer is
  // sparse, so digital PDFs and cache hits pay nothing for it.
  final ocr = OcrTextRecognizer();
  ref.onDispose(recognizer.dispose);
  ref.onDispose(ocr.dispose);
  ref.read(conversionProgressProvider.notifier).set(path, 0);
  final conversion = await loadOrConvert(
    path,
    recognizer,
    ocr: ocr,
    onProgress: (pr) =>
        ref.read(conversionProgressProvider.notifier).set(path, pr),
  );
  return conversion;
});
