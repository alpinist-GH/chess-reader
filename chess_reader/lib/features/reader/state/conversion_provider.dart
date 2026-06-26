import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/book_import.dart';
import '../../ocr/data/onnx_text_recognizer.dart';
import '../../purchase/billing_config.dart';
import '../../purchase/purchase_controller.dart';
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
  // Lazily-loaded: the OCR models are only loaded when a page's text layer is
  // sparse, so digital PDFs and cache hits pay nothing for it.
  final ocr = OcrTextRecognizer();
  ref.onDispose(recognizer.dispose);
  ref.onDispose(ocr.dispose);

  final cached = await ref.watch(conversionCachedProvider(path).future);
  // A genuinely new conversion — not a cache re-open, not the free sample book.
  // Only these count against the freemium meter.
  final isFresh = !cached && !isSampleBookPath(path);

  // Freemium gate: once the free allowance is spent (and Pro isn't unlocked),
  // hold a fresh conversion in a loading state — the reader shows the paywall
  // instead of the progress bar. Watching the controller re-runs this provider
  // when the lifetime unlock lands, so the book then converts automatically.
  if (isFresh && kBillingEnabled) {
    ref.watch(purchaseControllerProvider);
    if (!ref.read(purchaseControllerProvider.notifier).canConvert()) {
      return Completer<BookConversion>().future;
    }
  }

  // A scanned/image-only PDF is gated behind a user choice, because recovering
  // its text with OCR is slow. Until the open-book dialog records that choice,
  // keep the conversion in a loading state (a never-completing future); the
  // provider re-runs when the decision lands. Cached and digital books skip
  // this entirely and convert straight away.
  final decision = ref.watch(ocrDecisionProvider(path));
  var runOcr = true;
  if (!cached && await ref.watch(pdfImageOnlyProvider(path).future)) {
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
  // Count the conversion only after it actually completed.
  if (isFresh) ref.read(purchaseControllerProvider.notifier).recordConversion();
  return conversion;
});

/// Whether opening [path] right now is blocked by the freemium paywall: a fresh
/// (uncached, non-sample) conversion once the free allowance is spent and Pro
/// isn't unlocked. The reader watches this to show the paywall in place of the
/// conversion progress bar. Always false when billing is disabled (desktop).
final conversionGatedProvider = Provider.family<bool, String>((ref, path) {
  if (!kBillingEnabled) return false;
  final cached = ref.watch(conversionCachedProvider(path)).value ?? false;
  if (cached || isSampleBookPath(path)) return false;
  ref.watch(purchaseControllerProvider);
  return !ref.read(purchaseControllerProvider.notifier).canConvert();
});
