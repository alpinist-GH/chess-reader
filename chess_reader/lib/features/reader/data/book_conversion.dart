import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/async/semaphore.dart';
import '../../../core/util/fnv_hash.dart';
import '../../ocr/domain/text_page_recognizer.dart';
import '../../vision/data/diagram_recognizer.dart';
import 'epub_book.dart';

/// One recognized diagram, ready to place in a page/chapter.
class ConvertedDiagram {
  const ConvertedDiagram({
    required this.fen,
    required this.cropPngBase64,
    required this.left,
    required this.top,
    required this.size,
    required this.anchor,
  });

  /// Detected position.
  final String fen;

  /// Board crop as base64 PNG (embedded into the HTML reading view).
  final String cropPngBase64;

  /// Board region in raster pixels of the rendered page (200 dpi). Used by the
  /// Original-PDF overlay to place a tappable hotspot.
  final int left;
  final int top;
  final int size;

  /// Placement hint: for PDF, the character offset in the page text where the
  /// diagram should be inserted; for EPUB, the occurrence index of the board
  /// `<img>` within the chapter.
  final int anchor;

  Map<String, dynamic> toJson() => {
        'fen': fen,
        'png': cropPngBase64,
        'l': left,
        't': top,
        's': size,
        'a': anchor,
      };

  factory ConvertedDiagram.fromJson(Map<String, dynamic> j) => ConvertedDiagram(
        fen: j['fen'] as String,
        cropPngBase64: j['png'] as String,
        left: j['l'] as int,
        top: j['t'] as int,
        size: j['s'] as int,
        anchor: j['a'] as int,
      );
}

/// One PDF page or EPUB chapter after conversion.
class ConvertedPage {
  const ConvertedPage({
    required this.index,
    this.text,
    this.diagrams = const [],
  });

  /// PDF page number, or EPUB chapter index.
  final int index;

  /// Plain page text (PDF only; used to build the HTML reading view).
  final String? text;

  final List<ConvertedDiagram> diagrams;

  Map<String, dynamic> toJson() => {
        'i': index,
        if (text != null) 'text': text,
        'd': [for (final d in diagrams) d.toJson()],
      };

  factory ConvertedPage.fromJson(Map<String, dynamic> j) => ConvertedPage(
        index: j['i'] as int,
        text: j['text'] as String?,
        diagrams: [
          for (final d in (j['d'] as List? ?? const []))
            ConvertedDiagram.fromJson(d as Map<String, dynamic>)
        ],
      );
}

/// The cached result of detecting diagrams (and, for PDF, extracting text)
/// across a whole book. The slow vision work lives here; move resolution and
/// HTML assembly are recomputed cheaply on open.
class BookConversion {
  const BookConversion({
    required this.title,
    required this.format,
    required this.pages,
    this.sourcePath = '',
    this.ocrAttempted = true,
  });

  final String title;

  /// 'pdf' or 'epub'.
  final String format;
  final List<ConvertedPage> pages;

  /// Absolute path of the source book (recorded so the converted-books library
  /// can list and reopen cached books).
  final String sourcePath;

  /// Whether OCR was run during this conversion. A scanned PDF opened with
  /// "Keep original" is converted without OCR (`false`), so the reader can offer
  /// a "Run OCR" action; `true` means OCR already ran (succeeded, or failed on a
  /// poor scan — re-running wouldn't help), so the action is not offered. Older
  /// caches (which always ran OCR) default to `true`.
  final bool ocrAttempted;

  /// Diagrams for a given PDF page number / EPUB chapter index.
  List<ConvertedDiagram> diagramsFor(int index) =>
      pages.firstWhere((p) => p.index == index,
          orElse: () => const ConvertedPage(index: -1)).diagrams;

  /// Whether the book has a usable text layer. A scanned/image-only PDF
  /// extracts (almost) no text, so move resolution and the HTML reading view
  /// produce nothing — the reader warns and steers to Original pages.
  ///
  /// EPUB is XHTML (always text), so only PDFs are gated; the test is a low
  /// average of non-whitespace characters per page.
  bool get hasExtractableText {
    if (format != 'pdf' || pages.isEmpty) return true;
    var chars = 0;
    for (final p in pages) {
      final t = p.text;
      if (t == null) continue;
      chars += t.replaceAll(RegExp(r'\s'), '').length;
    }
    return chars >= pages.length * _minTextCharsPerPage;
  }

  /// Average non-whitespace chars/page below which a PDF is treated as
  /// image-only. Real book pages have hundreds; scanned pages have ~0.
  static const _minTextCharsPerPage = 20;

  // v3: diagram recognition rejects empty/false boards (board_validator).
  // v4: validator no longer assumes a legal position — it tolerates the square
  //     model's misreads (extra kings, 33+ pieces) so real diagrams are not
  //     dropped; only empty/noise regions are rejected. Re-run v3 caches that
  //     wrongly dropped every diagram.
  // v5: board_repair adds the promotion-aware material cap (e.g. a 3rd rook with
  //     all pawns present is demoted), so cached FENs from v4 must be recomputed.
  // v6: mask-aware recognition (arrow segmenter + 2-channel classifier) reads
  //     through drawn arrows/annotations, so v5 caches with phantom pieces on
  //     arrow squares must be recomputed.
  // v7: OCR text layer for scanned PDFs — pages whose embedded text layer is
  //     sparse are now read with the ONNX OCR pipeline, so v6 caches that
  //     stored empty page text for image-only books must be recomputed.
  // v8: OCR recognizer now feeds each text line at its natural width instead of
  //     squashing it into a 320px strip (which crushed glyphs and produced
  //     garbled/empty lines), so v7 OCR caches must be recomputed.
  // v9: OCR detector pads line boxes more generously sideways (~60% of line
  //     height, was 30%) so the first/last glyph isn't clipped (a capital "T"
  //     no longer reads as "I", leading punctuation is kept), so v8 OCR caches
  //     must be recomputed.
  // v10: OCR recognizer upgraded from PP-OCRv3 to PP-OCRv4 mobile (same size and
  //     dictionary, measurably fewer errors on degraded scans), so v9 OCR
  //     caches must be recomputed.
  // v11: two reader upgrades, so older caches are stale. (1) The
  //     tokenizer/resolver now also read English descriptive notation
  //     (P-K4, Kt-QB3, PxQP, Castles). (2) A central-dark-mass emptiness gate
  //     stops hatched "dark" squares (old print diagrams) being read as phantom
  //     pieces, so those books' diagram FENs change.
  // v12: move-illustration diagrams (teaching books that tag squares with "x")
  //     are now rejected instead of emitted as a wall of phantom pieces.
  // v13: the 2-channel square classifier was finetuned on real engraving-font
  //     diagrams (Lasker's "Chess Strategy"), fixing the residual bishop->king
  //     confusion and the last arrow-induced phantom rooks/dropped pawns, so v12
  //     caches of old-print books must be recomputed.
  // v16: line-wrap hyphens (soft hyphen / Unicode hyphen variants the reader
  //     font can't render, shown as "tofu" boxes) are now stripped and the
  //     split word rejoined in the HTML builder, along with other invisible
  //     format characters, so cached page HTML must be rebuilt.
  // v17: diagram crop PNGs move out of the cache JSON into a sidecar directory
  //     ('pf' filename replaces the inline base64 'png'). The JSON stays slim
  //     (page text + geometry), the PNGs avoid the 33% base64 overhead, and
  //     listing/reading caches no longer decodes megabytes of image data.
  // v18: square classifier retrained on the Chess Strategy / Chess
  //     Fundamentals EPUB scans (engraving fonts, bleed-through, faint white
  //     glyphs) and the central-dark-mass emptiness gate removed, so cached
  //     diagram FENs from older versions are stale.
  // v19: plausibility gate accepts sparse/king-less teaching diagrams read at
  //     high confidence (basic mates, pawn skeletons), and king repair flips
  //     colour-misread kings / clears adjacent king-bleed cells instead of
  //     minting phantom officers — dropped and misread diagrams differ.
  static const _version = 19;

  Map<String, dynamic> toJson() => {
        'v': _version,
        'title': title,
        'format': format,
        'sourcePath': sourcePath,
        'ocrAttempted': ocrAttempted,
        'pages': [for (final p in pages) p.toJson()],
      };

  factory BookConversion.fromJson(Map<String, dynamic> j) => BookConversion(
        title: j['title'] as String,
        format: j['format'] as String,
        sourcePath: j['sourcePath'] as String? ?? '',
        ocrAttempted: j['ocrAttempted'] as bool? ?? true,
        pages: [
          for (final pg in (j['pages'] as List))
            ConvertedPage.fromJson(pg as Map<String, dynamic>)
        ],
      );
}

/// A converted book on disk: enough to list and reopen it.
class CachedBook {
  const CachedBook(
      {required this.path, required this.title, required this.format});
  final String path;
  final String title;
  final String format;
}

/// Thrown when a conversion is abandoned because the user closed the book (or
/// otherwise cancelled) while it was still running. Nothing is cached.
class ConversionCancelled implements Exception {
  const ConversionCancelled();
  @override
  String toString() => 'Conversion cancelled';
}

/// Loads a cached conversion if one exists for [path]'s current contents,
/// otherwise runs the conversion and caches it. Reports progress in [0,1].
/// [isCancelled] is polled between pages; when it returns true the conversion
/// stops (after in-flight pages drain) and throws [ConversionCancelled].
Future<BookConversion> loadOrConvert(
  String path,
  DiagramRecognizer recognizer, {
  TextPageRecognizer? ocr,
  void Function(double progress)? onProgress,
  void Function(BookConversion partial)? onPartial,
  bool Function()? isCancelled,
}) async {
  final cached = await _readCache(path);
  if (cached != null) {
    onProgress?.call(1);
    return cached;
  }
  final conversion = path.toLowerCase().endsWith('.epub')
      ? await convertEpub(path, recognizer,
          onProgress: onProgress, isCancelled: isCancelled)
      : await convertPdf(path, recognizer,
          ocr: ocr,
          onProgress: onProgress,
          onPartial: onPartial,
          isCancelled: isCancelled);
  await _writeCache(path, conversion);
  return conversion;
}

/// Whether a page's embedded text layer is too sparse to use — the per-page
/// equivalent of [BookConversion.hasExtractableText], used to decide when to
/// fall back to OCR. A real digital page has hundreds of non-whitespace chars;
/// a scanned page has ~0.
bool _pageTextIsSparse(String text) =>
    text.replaceAll(RegExp(r'\s'), '').length <
        BookConversion._minTextCharsPerPage;

/// How many pages are recognized concurrently. The per-page locate step runs
/// in its own isolate (`compute`), so several pages overlap across CPU cores;
/// rendering stays sequential (single PdfDocument) and ONNX inference is
/// serialized inside the recognizer. Cuts a big book's first open several-fold.
const int _conversionConcurrency = 4;

/// PDF conversion: render each page (200 dpi), recognize diagrams, extract the
/// page text, and compute each diagram's insertion offset into that text.
///
/// Rendering is sequential (the page loop), but recognition of up to
/// [_conversionConcurrency] pages runs at once; results are placed by index so
/// the output order is unaffected.
Future<BookConversion> convertPdf(
  String path,
  DiagramRecognizer recognizer, {
  TextPageRecognizer? ocr,
  void Function(double progress)? onProgress,
  void Function(BookConversion partial)? onPartial,
  bool Function()? isCancelled,
}) async {
  const scale = 200 / 72; // PDF points (72 dpi) → ~200 dpi raster.
  final doc = await PdfDocument.openFile(path);
  var aborted = false;
  try {
    final total = doc.pages.length;
    final results = List<ConvertedPage?>.filled(total, null);
    final sem = Semaphore(_conversionConcurrency);
    final inFlight = <Future<void>>[];
    var completed = 0;

    for (var i = 0; i < total; i++) {
      // Throttle BEFORE rendering so at most N page images are in memory.
      await sem.acquire();
      // Stop scheduling new pages once cancelled; in-flight pages drain below
      // so the document isn't disposed under them.
      if (isCancelled?.call() ?? false) {
        sem.release();
        aborted = true;
        break;
      }
      final page = doc.pages[i];
      final structured = await page.loadStructuredText();
      final text = structured.fullText;
      final image = await page.render(
        fullWidth: page.width * scale,
        fullHeight: page.height * scale,
      );

      final index = i;
      final pageNumber = page.pageNumber;
      final pageHeight = page.height;
      final charRects = structured.charRects;

      Future<void> recognize() async {
        final diagrams = <ConvertedDiagram>[];
        var pageText = text;
        if (image != null) {
          final recognized = await recognizer.recognizePage(
            bgra: image.pixels,
            width: image.width,
            height: image.height,
          );
          // Scanned/image-only page: recover its body text via OCR so the
          // reflowed reading view (and search/move resolution) work. Reuses the
          // raster already rendered for diagram recognition — no extra render.
          if (ocr != null && _pageTextIsSparse(text)) {
            final ocrText = await ocr.recognizePage(
              bgra: image.pixels,
              width: image.width,
              height: image.height,
            );
            if (ocrText.trim().isNotEmpty) pageText = ocrText;
          }
          image.dispose();
          for (final r in recognized) {
            diagrams.add(ConvertedDiagram(
              fen: r.fen,
              cropPngBase64: base64Encode(r.cropPng),
              left: r.left,
              top: r.top,
              size: r.size,
              anchor: _insertOffsetForDiagram(
                charRects: charRects,
                pageHeight: pageHeight,
                scale: scale,
                diagramTopPx: r.top,
                textLength: text.length,
              ),
            ));
          }
        }
        results[index] =
            ConvertedPage(index: pageNumber, text: pageText, diagrams: diagrams);
        completed++;
        onProgress?.call(completed / total);
        // Emit a growing partial so the reader can open early (pages convert
        // out of order; diagramsFor() looks up by index, so a subset is fine).
        // Throttle to keep widget rebuilds cheap on long books.
        if (onPartial != null &&
            (completed == total || completed % 4 == 0)) {
          onPartial(BookConversion(
            title: p.basenameWithoutExtension(path),
            format: 'pdf',
            sourcePath: path,
            ocrAttempted: ocr != null,
            pages: [for (final pg in results) ?pg],
          ));
        }
      }

      inFlight.add(recognize().whenComplete(sem.release));
    }
    await Future.wait(inFlight);
    if (aborted) throw const ConversionCancelled();
    return BookConversion(
      title: p.basenameWithoutExtension(path),
      format: 'pdf',
      sourcePath: path,
      ocrAttempted: ocr != null,
      pages: [for (final pg in results) pg!],
    );
  } finally {
    doc.dispose();
  }
}

/// EPUB conversion: recognize boards in each chapter's images. Each diagram's
/// [ConvertedDiagram.anchor] is the `<img>` occurrence index within its
/// chapter, so the HTML builder can wrap exactly that image. Chapters are
/// recognized up to [_conversionConcurrency] at a time; results go by index.
Future<BookConversion> convertEpub(
  String path,
  DiagramRecognizer recognizer, {
  void Function(double progress)? onProgress,
  bool Function()? isCancelled,
}) async {
  final chapterImages = await epubChapterImages(path);
  final total = chapterImages.length;
  final results = List<ConvertedPage?>.filled(total, null);
  final sem = Semaphore(_conversionConcurrency);
  final inFlight = <Future<void>>[];
  var completed = 0;
  var aborted = false;

  for (var c = 0; c < total; c++) {
    await sem.acquire();
    if (isCancelled?.call() ?? false) {
      sem.release();
      aborted = true;
      break;
    }
    final index = c;
    final images = chapterImages[c];

    Future<void> recognize() async {
      final diagrams = <ConvertedDiagram>[];
      for (var j = 0; j < images.length; j++) {
        final bytes = images[j];
        if (bytes == null) continue;
        final recognized = await recognizer.recognizeEncoded(bytes);
        if (recognized.isEmpty) continue;
        final r = recognized.first; // largest board in the image
        diagrams.add(ConvertedDiagram(
          fen: r.fen,
          cropPngBase64: base64Encode(r.cropPng),
          left: r.left,
          top: r.top,
          size: r.size,
          anchor: j,
        ));
      }
      results[index] = ConvertedPage(index: index, diagrams: diagrams);
      completed++;
      onProgress?.call(total == 0 ? 1 : completed / total);
    }

    inFlight.add(recognize().whenComplete(sem.release));
  }
  await Future.wait(inFlight);
  if (aborted) throw const ConversionCancelled();
  if (total == 0) onProgress?.call(1);
  return BookConversion(
    title: p.basenameWithoutExtension(path),
    format: 'epub',
    sourcePath: path,
    pages: [for (final pg in results) pg!],
  );
}

/// Finds the character offset where a diagram (whose top edge is [diagramTopPx]
/// raster pixels from the page top) should be spliced into the page text:
/// the first character whose vertical centre sits at or below the diagram top.
/// PDF coordinates are bottom-up (larger y = higher on the page).
int _insertOffsetForDiagram({
  required List<PdfRect> charRects,
  required double pageHeight,
  required double scale,
  required int diagramTopPx,
  required int textLength,
}) {
  final diagramTopPdfY = pageHeight - diagramTopPx / scale;
  for (var i = 0; i < charRects.length && i < textLength; i++) {
    final r = charRects[i];
    if (r.width <= 0 && r.height <= 0) continue;
    final centreY = (r.top + r.bottom) / 2;
    if (centreY <= diagramTopPdfY) return i;
  }
  return textLength;
}

/// Quickly decides whether a PDF is scanned/image-only — i.e. it has no usable
/// embedded text layer — by sampling the text of a spread of pages. It only
/// reads the text layer (no rendering, no OCR), so it returns in well under a
/// second even for a long book, and is used to decide whether to offer the
/// (slow) OCR conversion before the heavy work starts.
///
/// EPUB is always text, so it is never image-only.
Future<bool> pdfIsImageOnly(String path) async {
  if (path.toLowerCase().endsWith('.epub')) return false;
  final doc = await PdfDocument.openFile(path);
  try {
    final total = doc.pages.length;
    if (total == 0) return false;
    // Sample up to ~12 pages evenly spread across the book.
    const sampleTarget = 12;
    final step = (total / sampleTarget).ceil().clamp(1, total);
    var sampled = 0;
    var chars = 0;
    for (var i = 0; i < total; i += step) {
      final text = (await doc.pages[i].loadStructuredText()).fullText;
      chars += text.replaceAll(RegExp(r'\s'), '').length;
      sampled++;
    }
    return chars < sampled * BookConversion._minTextCharsPerPage;
  } catch (_) {
    return false; // If we can't tell, don't gate — convert normally.
  } finally {
    doc.dispose();
  }
}

/// Whether a cached conversion exists for [path]'s current contents.
Future<bool> hasCachedConversion(String path) async {
  try {
    return (await _cacheFile(path)).existsSync();
  } catch (_) {
    return false;
  }
}

Future<Directory> _cacheDir() async {
  final dir = await getApplicationSupportDirectory();
  final cacheDir = Directory(p.join(dir.path, 'book_cache'));
  if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
  return cacheDir;
}

/// Lists every converted book held in the on-disk cache (newest first).
/// The cache JSONs embed base64 diagram PNGs and can be many MB each, so the
/// reads and decodes run off the UI isolate.
Future<List<CachedBook>> listCachedConversions() async {
  try {
    final dirPath = (await _cacheDir()).path;
    return await Isolate.run(() => _listCachedConversionsSync(dirPath));
  } catch (_) {
    return const [];
  }
}

List<CachedBook> _listCachedConversionsSync(String dirPath) {
  try {
    final files = Directory(dirPath)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) =>
          b.statSync().modified.compareTo(a.statSync().modified));
    final books = <CachedBook>[];
    for (final f in files) {
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final source = j['sourcePath'] as String? ?? '';
        if (source.isEmpty) continue; // pre-v2 cache without a source path
        books.add(CachedBook(
          path: source,
          title: j['title'] as String? ?? p.basenameWithoutExtension(source),
          format: j['format'] as String? ?? 'pdf',
        ));
      } catch (_) {
        // Skip corrupt entries.
      }
    }
    return books;
  } catch (_) {
    return const [];
  }
}

/// Deletes the cached conversion for [path] (the source book is untouched).
Future<void> deleteCachedConversion(String path) async {
  try {
    final file = await _cacheFile(path);
    if (file.existsSync()) file.deleteSync();
    final pngDir = _pngDirFor(file);
    if (pngDir.existsSync()) pngDir.deleteSync(recursive: true);
  } catch (_) {
    // Ignore.
  }
}

// ---- Disk cache ---------------------------------------------------------

Future<File> _cacheFile(String path) async {
  final cacheDir = await _cacheDir();
  final stat = File(path).statSync();
  final base = p
      .basenameWithoutExtension(path)
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  // Hash the full path so same-named books of equal size/mtime at different
  // locations can't collide on one cache entry.
  final pathTag = fnv1aHex(utf8.encode(path));
  final key =
      '${base}_${stat.size}_${stat.modified.millisecondsSinceEpoch}_$pathTag';
  return File(p.join(cacheDir.path, '$key.json'));
}

// On disk a conversion is a slim JSON (page text + diagram geometry) plus a
// sidecar directory of diagram crop PNGs: each diagram's 'png' (base64) field
// is swapped for a 'pf' filename on write and hydrated back on read. Keeps the
// JSON small and the images binary. Reads/writes still run off the UI isolate.

/// Sidecar PNG directory for a cache [file] (`<key>.json` → `<key>_png/`).
Directory _pngDirFor(File file) =>
    Directory('${file.path.substring(0, file.path.length - '.json'.length)}_png');

Future<BookConversion?> _readCache(String path) async {
  try {
    final file = await _cacheFile(path);
    if (!file.existsSync()) return null;
    final pngDirPath = _pngDirFor(file).path;
    return await Isolate.run(() {
      final json =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (json['v'] != BookConversion._version) return null;
      for (final page in json['pages'] as List) {
        for (final d in (page as Map<String, dynamic>)['d'] as List) {
          final diagram = d as Map<String, dynamic>;
          final pf = diagram.remove('pf') as String?;
          if (pf == null) continue;
          // A missing sidecar throws here → outer catch → reconvert.
          diagram['png'] = base64Encode(
              File(p.join(pngDirPath, pf)).readAsBytesSync());
        }
      }
      return BookConversion.fromJson(json);
    });
  } catch (_) {
    return null; // Corrupt or unreadable cache: just reconvert.
  }
}

Future<void> _writeCache(String path, BookConversion conversion) async {
  try {
    final file = await _cacheFile(path);
    final pngDirPath = _pngDirFor(file).path;
    await Isolate.run(() {
      final json = conversion.toJson();
      final pngDir = Directory(pngDirPath);
      if (pngDir.existsSync()) pngDir.deleteSync(recursive: true);
      pngDir.createSync(recursive: true);
      for (final page in json['pages'] as List) {
        final pageMap = page as Map<String, dynamic>;
        final diagrams = pageMap['d'] as List;
        for (var j = 0; j < diagrams.length; j++) {
          final diagram = diagrams[j] as Map<String, dynamic>;
          final name = 'p${pageMap['i']}_$j.png';
          File(p.join(pngDirPath, name)).writeAsBytesSync(
              base64Decode(diagram.remove('png') as String));
          diagram['pf'] = name;
        }
      }
      file.writeAsStringSync(jsonEncode(json));
    });
  } catch (_) {
    // Best-effort cache; conversion still returns to the caller.
  }
}
