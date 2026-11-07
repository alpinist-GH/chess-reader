import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_reader/features/reader/data/book_conversion.dart';
import 'package:chess_reader/features/vision/data/diagram_recognizer.dart';
import 'package:chess_reader/features/reader/data/processed_book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('processed_book_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => dir.path,
        );
  });
  tearDown(() async => dir.delete(recursive: true));

  test(
    'round trip restores source, text, diagrams and a reusable local cache',
    () async {
      final source = File('${dir.path}/sample.pdf');
      await source.writeAsBytes([1, 2, 3, 4]);
      final conversion = BookConversion(
        title: 'Sample',
        format: 'pdf',
        sourcePath: source.path,
        ocrAttempted: false,
        pages: [
          ConvertedPage(
            index: 1,
            text: '1. e4',
            diagrams: [
              ConvertedDiagram(
                fen: '8/8/8/8/8/8/8/8 w - - 0 1',
                cropPngBase64: base64Encode([5, 6]),
                left: 10,
                top: 20,
                size: 100,
                anchor: 2,
                annotations: 'test',
              ),
            ],
          ),
        ],
      );
      final bundle = File('${dir.path}/sample.chessbook.zip');
      await bundle.writeAsBytes(
        await exportProcessedBook(source.path, conversion),
      );
      final imported = await importProcessedBook(bundle.path);
      final reimported = await importProcessedBook(bundle.path);
      expect(reimported, imported);
      expect(await File(imported).readAsBytes(), [1, 2, 3, 4]);
      // convertBook must return the installed cache even for this synthetic PDF;
      // attempting PDF recognition on these bytes would fail.
      final restored = await loadOrConvert(imported, DiagramRecognizer());
      expect(restored.sourcePath, imported);
      expect(restored.ocrAttempted, false);
      expect(restored.pages.single.toJson(), conversion.pages.single.toJson());
    },
  );

  test(
    'rejects unsupported detection versions before installing a book',
    () async {
      final metadata = utf8.encode(
        jsonEncode({
          'type': 'chess-reader-processed-book',
          'version': 1,
          'name': 'sample.pdf',
          'conversion': {'v': -1},
        }),
      );
      final zip = Archive()
        ..addFile(ArchiveFile('manifest.json', metadata.length, metadata))
        ..addFile(ArchiveFile('book', 1, [1]));
      final file = File('${dir.path}/bad.zip');
      await file.writeAsBytes(ZipEncoder().encode(zip));
      await expectLater(importProcessedBook(file.path), throwsFormatException);
      expect(Directory('${dir.path}/books').existsSync(), false);
    },
  );
}
