import 'dart:convert';
import 'dart:io';

import 'package:chess_reader/features/reader/data/book_conversion.dart';
import 'package:chess_reader/features/reader/data/diagram_corrections.dart';
import 'package:chess_reader/features/reader/data/pdf_html_builder.dart';
import 'package:chess_reader/features/reader/data/processed_book.dart';
import 'package:chess_reader/features/reader/state/diagram_corrections_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _wrong = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _right = '8/8/8/8/8/8/8/K6k w - - 0 1';

BookConversion _book(String sourcePath) => BookConversion(
  title: 'T',
  format: 'pdf',
  sourcePath: sourcePath,
  pages: [
    ConvertedPage(
      index: 3,
      text: 'text',
      diagrams: [
        ConvertedDiagram(
          fen: _wrong,
          cropPngBase64: base64Encode([1]),
          left: 10,
          top: 20,
          size: 100,
          anchor: 2,
        ),
        ConvertedDiagram(
          fen: _wrong,
          cropPngBase64: base64Encode([2]),
          left: 10,
          top: 300,
          size: 100,
          anchor: 4,
        ),
      ],
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('corrections_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => dir.path,
        );
  });
  tearDown(() async => dir.delete(recursive: true));

  test('overlay changes only the keyed diagram and marks it corrected', () {
    final book = _book('x.pdf');
    final first = book.pages.single.diagrams.first;
    final out = applyDiagramCorrections(book, {diagramKey(3, first): _right});
    final diagrams = out.pages.single.diagrams;
    expect(diagrams[0].fen, _right);
    expect(diagrams[0].corrected, isTrue);
    expect(diagrams[0].cropPngBase64, first.cropPngBase64);
    expect(diagrams[1].fen, _wrong);
    expect(diagrams[1].corrected, isFalse);
  });

  test('no applicable corrections returns the same conversion', () {
    final book = _book('x.pdf');
    expect(applyDiagramCorrections(book, const {}), same(book));
    expect(applyDiagramCorrections(book, {'9:9:9:9': _right}), same(book));
  });

  test('corrections are not written into the detection data', () {
    final book = _book('x.pdf');
    final first = book.pages.single.diagrams.first;
    final out = applyDiagramCorrections(book, {diagramKey(3, first): _right});
    expect(jsonEncode(out.toJson()).contains('corrected'), isFalse);
  });

  test('HTML carries the diagram key and corrected flag', () {
    final book = _book('x.pdf');
    final first = book.pages.single.diagrams.first;
    final corrected = applyDiagramCorrections(book, {
      diagramKey(3, first): _right,
    });
    final html = buildPdfChapters(corrected).single.html;
    expect(html, contains('dkey="${diagramKey(3, first)}"'));
    expect(RegExp('corrected="1"').allMatches(html), hasLength(1));
  });

  test('corrections persist and can be cleared', () async {
    final source = File('${dir.path}/b.pdf')..writeAsBytesSync([1, 2, 3]);
    expect(await loadDiagramCorrections(source.path), isEmpty);
    await saveDiagramCorrections(source.path, {'3:2:10:20': _right});
    expect(await loadDiagramCorrections(source.path), {'3:2:10:20': _right});
    await saveDiagramCorrections(source.path, {});
    expect(await loadDiagramCorrections(source.path), isEmpty);
  });

  test('export/import carries corrections and keeps local ones', () async {
    final source = File('${dir.path}/c.pdf')..writeAsBytesSync([1, 2, 3, 4]);
    final book = _book(source.path);
    final keyA = diagramKey(3, book.pages.single.diagrams[0]);
    final keyB = diagramKey(3, book.pages.single.diagrams[1]);
    final bundle = File('${dir.path}/c.chessbook.zip')
      ..writeAsBytesSync(
        await exportProcessedBook(
          source.path,
          book,
          corrections: {keyA: _right, keyB: _right},
        ),
      );
    final imported = await importProcessedBook(bundle.path);
    expect(await loadDiagramCorrections(imported), {
      keyA: _right,
      keyB: _right,
    });

    // A local edit beats the bundle's on re-import.
    const local = '8/8/8/8/8/8/8/k6K b - - 0 1';
    await saveDiagramCorrections(imported, {keyA: local});
    await importProcessedBook(bundle.path);
    expect(await loadDiagramCorrections(imported), {keyA: local, keyB: _right});
  });

  test('a bundle without corrections still imports', () async {
    final source = File('${dir.path}/d.pdf')..writeAsBytesSync([9, 9]);
    final bundle = File('${dir.path}/d.chessbook.zip')
      ..writeAsBytesSync(await exportProcessedBook(source.path, _book('d')));
    final imported = await importProcessedBook(bundle.path);
    expect(await loadDiagramCorrections(imported), isEmpty);
  });

  test('books with the same name and size do not share corrections', () async {
    final a = File('${dir.path}/a/same.pdf')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    final b = File('${dir.path}/b/same.pdf')
      ..createSync(recursive: true)
      ..writeAsBytesSync([4, 5, 6]);
    await saveDiagramCorrections(a.path, {'1:1:1:1': _right});
    expect(await loadDiagramCorrections(b.path), isEmpty);
    expect(await loadDiagramCorrections(a.path), isNotEmpty);
  });

  group('provider', () {
    late String path;
    late ProviderContainer container;
    setUp(() {
      path = (File('${dir.path}/p.pdf')..writeAsBytesSync([7, 7, 7])).path;
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test(
      'an edit before the load finishes keeps earlier corrections',
      () async {
        await saveDiagramCorrections(path, {'old': _right});
        final n = container.read(diagramCorrectionsProvider(path).notifier);
        await n.set('new', _wrong); // no await on `loaded` first
        expect(container.read(diagramCorrectionsProvider(path)), {
          'old': _right,
          'new': _wrong,
        });
        expect(await loadDiagramCorrections(path), {
          'old': _right,
          'new': _wrong,
        });
      },
    );

    test('invalidate reloads from disk without throwing', () async {
      final n = container.read(diagramCorrectionsProvider(path).notifier);
      await n.set('k', _right);
      await saveDiagramCorrections(path, {'k': _right, 'imported': _wrong});
      container.invalidate(diagramCorrectionsProvider(path));
      final again = container.read(diagramCorrectionsProvider(path).notifier);
      await again.loaded;
      expect(container.read(diagramCorrectionsProvider(path)), {
        'k': _right,
        'imported': _wrong,
      });
    });

    test(
      'overlapping set and remove end in the order they were issued',
      () async {
        final n = container.read(diagramCorrectionsProvider(path).notifier);
        final futures = [
          n.set('k', _right),
          n.remove('k'),
          n.set('j', _wrong),
          n.set('k', _wrong),
        ];
        await Future.wait(futures);
        final expected = {'j': _wrong, 'k': _wrong};
        expect(container.read(diagramCorrectionsProvider(path)), expected);
        expect(await loadDiagramCorrections(path), expected);
      },
    );
  });
}
