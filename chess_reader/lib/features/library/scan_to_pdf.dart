import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Assembles a sequence of captured page images (cropped + de-skewed by the
/// document scanner) into a single image-only PDF and returns its path.
///
/// The resulting PDF has no text layer, so when it flows through the normal
/// open pipeline it lands on the scanned-PDF branch of `convertPdf` and the
/// on-device OCR runs automatically — no special handling needed downstream.
///
/// One full-bleed image per page, with the page size matched to each image's
/// own aspect ratio so the page is rendered at natural proportions (the OCR
/// recognizer normalises line height itself, so there is nothing to gain from
/// upscaling here).
Future<String> buildPdfFromImages(List<String> imagePaths,
    {String? title}) async {
  final doc = pw.Document(title: title);

  for (final path in imagePaths) {
    final bytes = await File(path).readAsBytes();
    // Decode just to learn the pixel dimensions so the PDF page matches the
    // image aspect; the original encoded bytes are embedded as-is.
    final decoded = img.decodeImage(bytes);
    final width = (decoded?.width ?? 1000).toDouble();
    final height = (decoded?.height ?? 1414).toDouble();
    final image = pw.MemoryImage(bytes);

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(width, height),
        build: (context) => pw.FullPage(
          ignoreMargins: true,
          child: pw.Image(image, fit: pw.BoxFit.fill),
        ),
      ),
    );
  }

  final dir = await getTemporaryDirectory();
  final name = title == null || title.trim().isEmpty
      ? 'Scan ${DateTime.now().millisecondsSinceEpoch}'
      : title.trim();
  final dest = File(p.join(dir.path, '$name.pdf'));
  await dest.writeAsBytes(await doc.save(), flush: true);
  return dest.path;
}
