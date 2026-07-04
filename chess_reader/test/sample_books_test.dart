import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/features/reader/data/epub_book.dart';

/// Guards the bundled sample assets: they must exist, parse with the app's
/// EPUB reader, and carry no Project Gutenberg branding (the samples are
/// public-domain text redistributed outside the PG license, so the trademark
/// must stay stripped — see assets/sample/SOURCE.txt).
void main() {
  const samples = [
    'assets/sample/Chess Strategy - Edward Lasker.epub',
    'assets/sample/Chess History - Bird.epub',
  ];

  for (final path in samples) {
    test('$path parses and is Gutenberg-free', () async {
      final file = File(path);
      expect(await file.exists(), isTrue, reason: 'bundled sample missing');

      final book = await loadEpubBook(path);
      expect(book.chapters, isNotEmpty);

      final joined = [
        book.title,
        for (final ch in book.chapters) ...[ch.title, ch.html],
      ].join('\n').toLowerCase();
      expect(joined.contains('gutenberg'), isFalse,
          reason: 'PG branding must stay stripped from shipped samples');
    });
  }

  test('Chess Strategy sample keeps its diagram images', () async {
    final book =
        await loadEpubBook('assets/sample/Chess Strategy - Edward Lasker.epub');
    final imgTags = RegExp('<img').allMatches(
        book.chapters.map((ch) => ch.html).join('\n'));
    expect(imgTags.length, greaterThan(150),
        reason: 'the 167 diagram scans drive the vision pipeline');
  });
}
