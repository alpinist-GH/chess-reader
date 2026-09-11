import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chess_reader/features/vision/domain/board_locator.dart';
import 'package:chess_reader/features/vision/domain/board_slicer.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx_engine/pdfrx_engine.dart';

class BookSpec {
  final String slug;
  final String path;
  const BookSpec(this.slug, this.path);
}

Future<void> main(List<String> args) async {
  final books = [
    const BookSpec('fischer', '../ebook/01. My 60 Memorable Games - Bobby Fischer 2008.pdf'),
    const BookSpec('middle_game', '../ebook/the-art-of-the-middle-game_compress.pdf'),
    const BookSpec('march_ideas', '../ebook/the-march-of-chess-ideas_compress.pdf'),
    const BookSpec('kotov', '../ebook/think-like-a-grandmaster-9781849940535-1849940533_compress.pdf'),
    const BookSpec('art_of_attack', '../ebook/the-art-of-attack-in-chess.pdf'),
  ];

  final outRoot = args.isNotEmpty ? args[0] : 'tool/ebook_boards';
  final targetBook = args.length > 1 ? args[1] : null;
  final pageStart = args.length > 2 ? int.parse(args[2]) : 1;
  final pageEnd = args.length > 3 ? int.parse(args[3]) : null;

  await pdfrxInitialize();
  const locator = ConnectedComponentBoardLocator();

  final manifestFile = File('$outRoot/manifest.json');
  final allManifest = <Map<String, dynamic>>[];
  if (manifestFile.existsSync()) {
    try {
      final existing = (jsonDecode(manifestFile.readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
      allManifest.addAll(existing);
      print('Loaded ${existing.length} existing board records from manifest.');
    } catch (_) {}
  }

  for (final b in books) {
    if (targetBook != null && b.slug != targetBook) continue;

    final file = File(b.path);
    if (!file.existsSync()) {
      print('File not found: ${b.path}, skipping.');
      continue;
    }

    print('=== Processing ${b.slug} (${b.path}) ===');
    allManifest.removeWhere((m) => m['book'] == b.slug);
    final doc = await PdfDocument.openFile(b.path);
    final numPages = doc.pages.length;
    final lastPage = pageEnd ?? numPages;
    var totalBoardsInBook = 0;
    final stopwatch = Stopwatch()..start();

    for (var pageNum = pageStart; pageNum <= lastPage; pageNum++) {
      final page = doc.pages[pageNum - 1];
      const scale = 350.0 / 72.0;
      final pdfImage = await page.render(
        fullWidth: page.width * scale,
        fullHeight: page.height * scale,
      );
      if (pdfImage == null) continue;

      final image = img.Image.fromBytes(
        width: pdfImage.width,
        height: pdfImage.height,
        bytes: pdfImage.pixels.buffer,
        order: img.ChannelOrder.bgra,
      );

      final boards = locator.locate(image);
      if (boards.isEmpty) {
        if (pageNum % 25 == 0) {
          print('  [${b.slug}] Page $pageNum/$numPages (boards found so far: $totalBoardsInBook, elapsed: ${stopwatch.elapsed.inSeconds}s)');
        }
        continue;
      }

      totalBoardsInBook += boards.length;

      for (var i = 0; i < boards.length; i++) {
        final board = boards[i];
        final id = '${b.slug}_p${pageNum}_b$i';
        final dir = Directory('$outRoot/${b.slug}/p${pageNum}_b$i')..createSync(recursive: true);

        // Whole-board crop
        final crop = img.copyCrop(image,
            x: board.left,
            y: board.top,
            width: board.size,
            height: board.size);
        File('${dir.path}/board.png')
            .writeAsBytesSync(Uint8List.fromList(img.encodePng(crop)));

        // Inner frame-peeled board
        final inner = cropInsideFrame(image, board);
        File('${dir.path}/inner.png')
            .writeAsBytesSync(Uint8List.fromList(img.encodePng(inner)));

        // 64 sliced cells
        final cells = sliceInner(inner);
        for (var c = 0; c < 64; c++) {
          final rr = c ~/ 8, ff = c % 8;
          final cellPng = img.encodePng(cells[c]);
          File('${dir.path}/cell_$rr$ff.png')
              .writeAsBytesSync(Uint8List.fromList(cellPng));
        }

        allManifest.add({
          'id': id,
          'book': b.slug,
          'page': pageNum,
          'boardIndex': i,
          'left': board.left,
          'top': board.top,
          'size': board.size,
          'dir': dir.path,
        });

        print('  Found board $id on page $pageNum at (${board.left}, ${board.top}), size ${board.size}');
      }
    }

    doc.dispose();
    print('=== Done ${b.slug}: $totalBoardsInBook boards in ${stopwatch.elapsed.inSeconds}s ===\n');
  }

  manifestFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(allManifest));
  print('Total boards extracted across books: ${allManifest.length}');
  print('Saved manifest to ${manifestFile.path}');
}
