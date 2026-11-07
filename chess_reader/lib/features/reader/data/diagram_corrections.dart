import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/util/fnv_hash.dart';
import 'book_conversion.dart';

/// Stable identity of a diagram inside a book: the page (PDF) / chapter (EPUB)
/// index plus its placement hints. Unlike the diagram's FEN it never changes
/// when the user corrects the position, so a correction keeps matching.
String diagramKey(int page, ConvertedDiagram d) =>
    '$page:${d.anchor}:${d.left}:${d.top}';

/// [conversion] with each diagram whose key is in [corrections] showing the
/// user's FEN instead of the detected one. Returns [conversion] itself when
/// nothing applies, so identity-based memoisation downstream stays valid.
BookConversion applyDiagramCorrections(
  BookConversion conversion,
  Map<String, String> corrections,
) {
  if (corrections.isEmpty) return conversion;
  var changed = false;
  final pages = [
    for (final page in conversion.pages)
      ConvertedPage(
        index: page.index,
        text: page.text,
        diagrams: [
          for (final d in page.diagrams)
            if (corrections[diagramKey(page.index, d)] case final fen?
                when fen != d.fen)
              () {
                changed = true;
                return d.withFen(fen);
              }()
            else
              d,
        ],
      ),
  ];
  if (!changed) return conversion;
  return BookConversion(
    title: conversion.title,
    format: conversion.format,
    pages: pages,
    sourcePath: conversion.sourcePath,
    ocrAttempted: conversion.ocrAttempted,
  );
}

/// Corrections live outside the detection cache: the cache is discarded
/// whenever the detector improves, but a hand-corrected position must survive.
/// Keyed by the book's file name, size and a hash of its first and last 64 KB,
/// so two different books that share a name and size don't share corrections,
/// while the same book copied to another device still finds its file.
Future<File> _correctionsFile(String bookPath) async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory(p.join(support.path, 'diagram_corrections'));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final base = p.basename(bookPath).replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final (size, hash) = _bookIdentity(bookPath);
  return File(p.join(dir.path, '${base}_${size}_$hash.json'));
}

(int, String) _bookIdentity(String bookPath) {
  const sample = 64 * 1024;
  final raf = File(bookPath).openSync();
  try {
    final size = raf.lengthSync();
    final head = raf.readSync(size < sample ? size : sample);
    var tail = const <int>[];
    if (size > sample) {
      // Whatever the head didn't cover, up to another 64 KB.
      final tailLength = size - sample < sample ? size - sample : sample;
      raf.setPositionSync(size - tailLength);
      tail = raf.readSync(tailLength);
    }
    return (size, fnv1aHex([...head, ...tail]));
  } finally {
    raf.closeSync();
  }
}

Future<Map<String, String>> loadDiagramCorrections(String bookPath) async {
  try {
    final file = await _correctionsFile(bookPath);
    if (!file.existsSync()) return const {};
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return {
      for (final e in json.entries)
        if (e.value is String) e.key: e.value as String,
    };
  } catch (_) {
    return const {}; // Unreadable file: behave as if nothing was corrected.
  }
}

Future<void> saveDiagramCorrections(
  String bookPath,
  Map<String, String> corrections,
) async {
  final file = await _correctionsFile(bookPath);
  if (corrections.isEmpty) {
    if (file.existsSync()) await file.delete();
    return;
  }
  final partial = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.partial',
  );
  await partial.writeAsString(jsonEncode(corrections), flush: true);
  await partial.rename(file.path);
}
