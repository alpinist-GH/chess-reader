import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/features/reader/data/epub_book.dart';

/// Builds a minimal valid EPUB in a temp file.
Future<String> _makeTestEpub() async {
  const container = '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  const opf = '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0" unique-identifier="id">
  <metadata><dc:title>Test Chess Book</dc:title></metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="ch1"/><itemref idref="ch2"/></spine>
</package>''';
  const ch1 = '''
<html><body><h1>The Ruy Lopez</h1>
<p>The main line runs 1.e4 e5 2.&#9816;f3 &#9822;c6 3.Bb5 and now 3...a6
is the most common reply.</p></body></html>''';
  // Chapter 2 continues the same game: continuity across chapters.
  const ch2 = '''
<html><body><h2>Continuing</h2>
<p>Play goes on with 4.Ba4 Nf6 5.O-O and White is comfortable.</p></body></html>''';

  final archive = Archive()
    ..addFile(ArchiveFile('mimetype', 20, utf8.encode('application/epub+zip')))
    ..addFile(ArchiveFile(
        'META-INF/container.xml', container.length, utf8.encode(container)))
    ..addFile(ArchiveFile('OEBPS/content.opf', opf.length, utf8.encode(opf)))
    ..addFile(ArchiveFile('OEBPS/ch1.xhtml', ch1.length, utf8.encode(ch1)))
    ..addFile(ArchiveFile('OEBPS/ch2.xhtml', ch2.length, utf8.encode(ch2)));

  final bytes = ZipEncoder().encode(archive);
  final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}chess_reader_test.epub');
  await file.writeAsBytes(bytes);
  return file.path;
}

void main() {
  test('parses EPUB, wraps moves, resolves across chapters', () async {
    final path = await _makeTestEpub();
    addTearDown(() => File(path).delete());

    final book = await loadEpubBook(path);
    expect(book.title, 'Test Chess Book');
    expect(book.chapters, hasLength(2));

    final ch1 = book.chapters[0];
    expect(ch1.title, 'The Ruy Lopez');
    // e4 e5 Nf3 (figurine) Nc6 (figurine) Bb5 a6 — all legal in sequence.
    expect(ch1.moves.map((m) => m.token.san).toList(),
        ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6']);
    expect(ch1.html, contains('<chessmove'));
    expect(ch1.html, contains('idx="0"'));

    // Chapter 2 continues the same game — proof of cross-chapter context.
    final ch2 = book.chapters[1];
    expect(ch2.moves.map((m) => m.token.san).toList(), ['Ba4', 'Nf6', 'O-O']);
    expect(ch2.moves.last.positionAfter.fen,
        startsWith('r1bqkb1r/1ppp1ppp/p1n2n2/4p3/B3P3/5N2/PPPP1PPP/RNBQ1RK1'));
  });

  test('spine entry missing from the archive throws FormatException', () async {
    final path = await _makeBrokenEpub(dropChapter: true);
    addTearDown(() => File(path).delete());
    expect(loadEpubBook(path), throwsFormatException);
  });

  test('container.xml without a rootfile throws FormatException', () async {
    final path = await _makeBrokenEpub(emptyContainer: true);
    addTearDown(() => File(path).delete());
    expect(loadEpubBook(path), throwsFormatException);
  });
}

/// A structurally broken EPUB: either the container has no rootfile, or the
/// spine references a chapter file that isn't in the archive.
Future<String> _makeBrokenEpub(
    {bool dropChapter = false, bool emptyContainer = false}) async {
  final container = emptyContainer
      ? '<?xml version="1.0"?><container/>'
      : '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  const opf = '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <manifest>
    <item id="ch1" href="missing.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="ch1"/></spine>
</package>''';

  final archive = Archive()
    ..addFile(ArchiveFile('mimetype', 20, utf8.encode('application/epub+zip')))
    ..addFile(ArchiveFile(
        'META-INF/container.xml', container.length, utf8.encode(container)))
    ..addFile(ArchiveFile('OEBPS/content.opf', opf.length, utf8.encode(opf)));
  // dropChapter: the spine points at missing.xhtml, which is never added.

  final bytes = ZipEncoder().encode(archive);
  final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}'
      'chess_reader_broken_test.epub');
  await file.writeAsBytes(bytes);
  return file.path;
}
