// Extracts the app's located + frame-peeled board crops from any PDF.
//
//   dart run tool/extract_pdf_boards.dart <pdf> <slug> <outDir> [pageStart] [pageEnd]
//
// Writes <outDir>/<slug>_p<page>_b<i>.png (cropInsideFrame output, exactly what
// the app slices). Used to build test corpora for vision_train/eval_books.py.
import 'dart:io';
import 'dart:typed_data';

import 'package:chess_reader/features/vision/domain/board_locator.dart';
import 'package:chess_reader/features/vision/domain/board_slicer.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx_engine/pdfrx_engine.dart';

Future<void> main(List<String> args) async {
  final path = args[0], slug = args[1], out = args[2];
  final start = args.length > 3 ? int.parse(args[3]) : 1;
  await pdfrxInitialize();
  Directory(out).createSync(recursive: true);
  const locator = ConnectedComponentBoardLocator();
  final doc = await PdfDocument.openFile(path);
  final end = args.length > 4 ? int.parse(args[4]) : doc.pages.length;
  var n = 0;
  for (var p = start; p <= end && p <= doc.pages.length; p++) {
    final page = doc.pages[p - 1];
    const scale = 350.0 / 72.0;
    final pdfImage = await page.render(
        fullWidth: page.width * scale, fullHeight: page.height * scale);
    if (pdfImage == null) continue;
    final image = img.Image.fromBytes(
      width: pdfImage.width,
      height: pdfImage.height,
      bytes: pdfImage.pixels.buffer,
      order: img.ChannelOrder.bgra,
    );
    final boards = locator.locate(image);
    for (var i = 0; i < boards.length; i++) {
      final inner = cropInsideFrame(image, boards[i]);
      File('$out/${slug}_p${p}_b$i.png')
          .writeAsBytesSync(Uint8List.fromList(img.encodePng(inner)));
      n++;
    }
  }
  doc.dispose();
  print('$slug: $n boards');
}
