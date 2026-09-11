import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:chess_reader/features/vision/domain/board_locator.dart';
import 'package:chess_reader/features/vision/domain/board_slicer.dart';
import 'package:image/image.dart' as img;

/// Extracts chess-diagram board crops from an epub whose diagrams are
/// pre-rendered, full-bleed square images (one board per image, no page
/// layout to locate a board within) — unlike the PDF ebooks in
/// extract_ebook_boards.dart, which render full pages and run
/// ConnectedComponentBoardLocator to find boards inside them.
///
/// Usage: dart run tool/extract_epub_boards.dart <book-slug> <epub-path> [outRoot]
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('Usage: dart run tool/extract_epub_boards.dart <book-slug> <epub-path> [outRoot]');
    return;
  }
  final slug = args[0];
  final epubPath = args[1];
  final outRoot = args.length > 2 ? args[2] : 'tool/ebook_boards';

  final file = File(epubPath);
  if (!file.existsSync()) {
    print('File not found: $epubPath');
    return;
  }

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
  allManifest.removeWhere((m) => m['book'] == slug);

  final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
  final imageEntries = archive.files
      .where((f) => f.isFile && f.name.startsWith('images/') &&
          (f.name.toLowerCase().endsWith('.jpeg') || f.name.toLowerCase().endsWith('.jpg')))
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  print('=== Processing $slug ($epubPath): ${imageEntries.length} images ===');

  var totalBoards = 0;
  for (final entry in imageEntries) {
    final bytes = entry.content as List<int>;
    img.Image? decoded;
    try {
      decoded = img.decodeImage(Uint8List.fromList(bytes));
    } catch (_) {
      continue;
    }
    if (decoded == null) continue;

    // Diagram images in this epub are square, ~500px. Skip anything else
    // (author photo, cover, small icons) — not chess-board diagrams.
    final w = decoded.width, h = decoded.height;
    if ((w - h).abs() > 4 || w < 400 || w > 600) continue;

    final idTag = entry.name.replaceAll(RegExp(r'.*/'), '').replaceAll(RegExp(r'\.\w+$'), '');
    final id = '${slug}_i${idTag}_b0';
    final dir = Directory('$outRoot/$slug/i${idTag}_b0')..createSync(recursive: true);

    File('${dir.path}/board.png')
        .writeAsBytesSync(Uint8List.fromList(img.encodePng(decoded)));

    final board = LocatedBoard(left: 0, top: 0, size: w);
    final inner = cropInsideFrame(decoded, board);
    File('${dir.path}/inner.png')
        .writeAsBytesSync(Uint8List.fromList(img.encodePng(inner)));

    final cells = sliceInner(inner);
    for (var c = 0; c < 64; c++) {
      final rr = c ~/ 8, ff = c % 8;
      File('${dir.path}/cell_$rr$ff.png')
          .writeAsBytesSync(Uint8List.fromList(img.encodePng(cells[c])));
    }

    allManifest.add({
      'id': id,
      'book': slug,
      'page': idTag,
      'boardIndex': 0,
      'left': 0,
      'top': 0,
      'size': w,
      'dir': dir.path,
    });

    totalBoards++;
  }

  manifestFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(allManifest));
  print('=== Done $slug: $totalBoards boards extracted ===');
  print('Total boards across all books in manifest: ${allManifest.length}');
  print('Saved manifest to ${manifestFile.path}');
}
