import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/util/fnv_hash.dart';
import 'book_conversion.dart';
import 'diagram_corrections.dart';

/// A portable ZIP containing the original book and hydrated detection results.
Future<Uint8List> exportProcessedBook(
  String path,
  BookConversion conversion, {
  Map<String, String> corrections = const {},
}) async {
  return Isolate.run(() {
    final json = conversion.toJson()..remove('sourcePath');
    final metadata = utf8.encode(
      jsonEncode({
        'type': 'chess-reader-processed-book',
        'version': 1,
        'name': p.basename(path),
        'conversion': json,
        // User-corrected diagram FENs by diagramKey; absent in older exports.
        if (corrections.isNotEmpty) 'corrections': corrections,
      }),
    );
    final source = File(path).readAsBytesSync();
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', metadata.length, metadata))
      ..addFile(ArchiveFile('book', source.length, source));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  });
}

/// Validates before writing; never extracts archive-controlled paths.
Future<String> importProcessedBook(String path) async {
  final decoded = await Isolate.run(() {
    final archive = ZipDecoder().decodeBytes(
      File(path).readAsBytesSync(),
      verify: true,
    );
    final manifest = archive.findFile('manifest.json');
    final source = archive.findFile('book');
    if (manifest == null || source == null || !source.isFile) {
      throw const FormatException('Not a processed ChessBook Reader book.');
    }
    final json =
        jsonDecode(utf8.decode(manifest.content)) as Map<String, dynamic>;
    if (json['type'] != 'chess-reader-processed-book' || json['version'] != 1) {
      throw const FormatException('Unsupported processed book format.');
    }
    final conversionJson = json['conversion'] as Map<String, dynamic>;
    if (!BookConversion.supportsVersion(conversionJson['v'])) {
      throw const FormatException(
        'Detection data is incompatible with this app version. Export again using the same app version on both devices.',
      );
    }
    final name = json['name'] as String;
    final format = conversionJson['format'];
    if (name.isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains(':') ||
        (format != 'pdf' && format != 'epub') ||
        p.extension(name).toLowerCase() != '.$format') {
      throw const FormatException('Invalid book filename or format.');
    }
    final conversion = BookConversion.fromJson(conversionJson);
    for (final page in conversion.pages) {
      for (final diagram in page.diagrams) {
        base64Decode(diagram.cropPngBase64);
      }
    }
    final rawCorrections = json['corrections'];
    final corrections = <String, String>{
      if (rawCorrections is Map)
        for (final e in rawCorrections.entries)
          if (e.key is String && e.value is String) e.key: e.value as String,
    };
    return (name, conversion, Uint8List.fromList(source.content), corrections);
  });
  final support = await getApplicationSupportDirectory();
  final root = Directory(p.join(support.path, 'books'));
  await root.create(recursive: true);
  // Shares importBook's name + size folder, so re-importing or importing a book
  // that is already in the library reuses its path, covers and saved analysis.
  final bytes = decoded.$3;
  final baseName = p.basenameWithoutExtension(decoded.$1);
  var directory = Directory(p.join(root.path, '${baseName}_${bytes.length}'));
  var book = File(p.join(directory.path, decoded.$1));
  var sameContent = await _hasContent(book, bytes);
  if (book.existsSync() && !sameContent) {
    // A different book with the same name and size must not be replaced.
    directory = Directory('${directory.path}_${fnv1aHex(bytes)}');
    book = File(p.join(directory.path, decoded.$1));
    sameContent = await _hasContent(book, bytes);
  }
  final existed = directory.existsSync();
  await directory.create(recursive: true);
  try {
    // Identical bytes keep their timestamp, which is part of the cache key, and
    // an open book is never rewritten underneath its reader.
    if (!sameContent) {
      final partial = File('${book.path}.partial');
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(book.path);
    }
    final conversion = decoded.$2;
    await saveImportedConversion(
      book.path,
      BookConversion(
        title: conversion.title,
        format: conversion.format,
        pages: conversion.pages,
        ocrAttempted: conversion.ocrAttempted,
        sourcePath: book.path,
      ),
    );
    // Merge rather than replace: corrections made on this device win over the
    // bundle's for the same diagram, and none are lost.
    if (decoded.$4.isNotEmpty) {
      final mine = await loadDiagramCorrections(book.path);
      await saveDiagramCorrections(book.path, {...decoded.$4, ...mine});
    }
    return book.path;
  } catch (_) {
    if (!existed && directory.existsSync()) {
      await directory.delete(recursive: true);
    }
    rethrow;
  }
}

Future<bool> _hasContent(File file, Uint8List bytes) async {
  if (!file.existsSync() || file.lengthSync() != bytes.length) return false;
  final path = file.path;
  return Isolate.run(() {
    final existing = File(path).readAsBytesSync();
    for (var i = 0; i < existing.length; i++) {
      if (existing[i] != bytes[i]) return false;
    }
    return true;
  });
}
