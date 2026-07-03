import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ocr/data/native_text_recognizer.dart';
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

/// Fraction of a book that must be converted before the reader opens it for
/// reading (the rest keeps converting in the background; diagrams light up as
/// their page completes).
const double kReadableThreshold = 0.2;

/// Latest PARTIAL conversion per book path, published while [conversionProvider]
/// is still running so the reader can open early. Holds a growing subset of the
/// pages (diagrams appear as each page finishes); replaced by the full
/// conversion when it completes.
class PartialConversion extends Notifier<Map<String, BookConversion>> {
  @override
  Map<String, BookConversion> build() => const {};

  void set(String path, BookConversion partial) {
    state = {...state, path: partial};
  }

  void clear(String path) {
    if (!state.containsKey(path)) return;
    state = {...state}..remove(path);
  }
}

final partialConversionProvider =
    NotifierProvider<PartialConversion, Map<String, BookConversion>>(
        PartialConversion.new);

/// Books the user has chosen to start reading early (before conversion finishes)
/// by tapping "Start reading" on the progress screen. Once a path is here the
/// reader opens it and keeps converting the rest in the background.
class ReadEarly extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void start(String path) {
    if (state.contains(path)) return;
    state = {...state, path};
  }
}

final readEarlyProvider =
    NotifierProvider<ReadEarly, Set<String>>(ReadEarly.new);

/// The best conversion available for [path] right now: the full result once
/// [conversionProvider] completes, otherwise the latest ≥[kReadableThreshold]
/// partial. Null until enough pages are converted to start reading. The reader,
/// diagram overlays and move resolution read this so they show data incrementally
/// during a background conversion. (Export and the OCR-availability check still
/// read [conversionProvider] directly, as they need the complete book.)
final effectiveConversionProvider =
    Provider.autoDispose.family<BookConversion?, String>((ref, path) {
  final full = ref.watch(conversionProvider(path)).value;
  if (full != null) return full;
  return ref.watch(partialConversionProvider)[path];
});

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
///
/// autoDispose doubles as cancellation: the reader widgets watching this keep
/// it alive while the book is open; closing the book drops the last listener,
/// the provider disposes, and the running conversion aborts between pages
/// (nothing is cached). A completed conversion calls `keepAlive` so reopening
/// in-session stays instant.
final conversionProvider = FutureProvider.autoDispose
    .family<BookConversion, String>((ref, path) async {
  var cancelled = false;
  ref.onDispose(() => cancelled = true);
  final recognizer = DiagramRecognizer();
  // OCR uses the OS-native text recognizer on every platform (Apple Vision on
  // iOS/macOS, ML Kit on Android, Windows.Media.Ocr on Windows) — faster, more
  // accurate, and lets us ship without the ~13 MB ONNX OCR models. On any
  // platform without a native recognizer it simply yields no text. OCR is lazily
  // used — only when a page's text layer is sparse — so digital PDFs and cache
  // hits pay nothing for it.
  final TextPageRecognizer ocr = NativeTextRecognizer();
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
    // Publish partials once enough of the book is ready, so the reader opens at
    // ~[kReadableThreshold] and keeps converting the rest in the background.
    onPartial: (partial) {
      final pr = ref.read(conversionProgressProvider)[path] ?? 0;
      if (pr >= kReadableThreshold) {
        ref.read(partialConversionProvider.notifier).set(path, partial);
      }
    },
    isCancelled: () => cancelled,
  );
  ref.keepAlive();
  return conversion;
});
