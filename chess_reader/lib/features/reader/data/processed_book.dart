import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'book_conversion.dart';

/// A portable ZIP containing the original book and hydrated detection results.
Future<Uint8List> exportProcessedBook(
  String path,
  BookConversion conversion,
) async {
  return Isolate.run(() {
    final json = conversion.toJson()..remove('sourcePath');
    final metadata = utf8.encode(
      jsonEncode({
        'type': 'chess-reader-processed-book',
        'version': 1,
        'name': p.basename(path),
        'conversion': json,
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
    return (name, conversion, Uint8List.fromList(source.content));
  });
  final support = await getApplicationSupportDirectory();
  final root = Directory(p.join(support.path, 'books'));
  await root.create(recursive: true);
  final baseName = p.basenameWithoutExtension(decoded.$1);
  final key = '${baseName}_${decoded.$3.length}';
  final directory = Directory(p.join(root.path, key));
  final existed = directory.existsSync();
  await directory.create(recursive: true);
  try {
    final book = File(p.join(directory.path, decoded.$1));
    await book.writeAsBytes(decoded.$3, flush: true);
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
    return book.path;
  } catch (_) {
    if (!existed && directory.existsSync()) {
      await directory.delete(recursive: true);
    }
    rethrow;
  }
}
