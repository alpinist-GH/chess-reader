import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/core/persistence/library_store.dart';
import 'package:chess_reader/features/reader/data/book_conversion.dart';
import 'package:chess_reader/features/reader/data/pdf_html_builder.dart';

void main() {
  group('buildPdfChapters', () {
    test('wraps resolved moves in <chessmove> and inserts <chessdiagram>', () {
      // A 1×1 transparent PNG, just to have valid base64 image data.
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
      final conversion = BookConversion(
        title: 'T',
        format: 'pdf',
        pages: [
          ConvertedPage(
            index: 1,
            text: '1.e4 e5 2.Nf3 Nc6',
            diagrams: [
              ConvertedDiagram(
                fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
                cropPngBase64: png,
                left: 0,
                top: 0,
                size: 100,
                anchor: 0, // before all text → diagram first
              ),
            ],
          ),
        ],
      );

      final chapters = buildPdfChapters(conversion);
      expect(chapters, hasLength(1));
      final html = chapters.single.html;

      // Every legal move on the page became a clickable span.
      expect(chapters.single.moves.length, 4);
      expect('<chessmove idx="0">'.allMatches(html).length, 1);
      expect(RegExp(r'<chessmove idx="\d+">').allMatches(html).length, 4);

      // The diagram is embedded with its FEN and image.
      expect(html.contains('<chessdiagram fen='), isTrue);
      expect(html.contains('data:image/png;base64,$png'), isTrue);
      // anchor 0 places the diagram before the move text.
      expect(html.indexOf('<chessdiagram'),
          lessThan(html.indexOf('<chessmove')));
    });

    test('carries diagram annotations into the ann attribute', () {
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
      final conversion = BookConversion(
        title: 'T',
        format: 'pdf',
        pages: [
          ConvertedPage(
            index: 1,
            text: 'training diagram page',
            diagrams: [
              ConvertedDiagram(
                fen: '4k3/8/8/8/4Q3/8/8/4K3 w - - 0 1',
                annotations: 'Ae4e8;Xd5;Xf5',
                cropPngBase64: png,
                left: 0,
                top: 0,
                size: 100,
                anchor: 0,
              ),
              // No annotations → no ann attribute at all.
              ConvertedDiagram(
                fen: '4k3/8/8/8/8/8/8/4K3 w - - 0 1',
                cropPngBase64: png,
                left: 0,
                top: 200,
                size: 100,
                anchor: 5,
              ),
            ],
          ),
        ],
      );

      final html = buildPdfChapters(conversion).single.html;
      expect(html.contains('ann="Ae4e8;Xd5;Xf5"'), isTrue);
      expect('ann='.allMatches(html).length, 1);
    });

    test('renders figurine moves as standard SAN, not glyph soup', () {
      // Gambit-font extraction: "lt:J" is a knight glyph sequence.
      final conversion = BookConversion(
        title: 'T',
        format: 'pdf',
        pages: const [
          ConvertedPage(index: 1, text: '1.e4 e5 2.lt:Jf3 lt:Jc6'),
        ],
      );
      final html = buildPdfChapters(conversion).single.html;

      // All four moves resolved and the knight moves read as standard SAN.
      expect(RegExp(r'<chessmove idx="\d+">').allMatches(html).length, 4);
      expect(html.contains('<chessmove idx="2">Nf3</chessmove>'), isTrue);
      expect(html.contains('<chessmove idx="3">Nc6</chessmove>'), isTrue);
      // No raw figurine soup leaks into the output.
      expect(html.contains('lt:J'), isFalse);
    });

    test('normalizes figurine glyphs in surrounding prose for display', () {
      final conversion = BookConversion(
        title: 'T',
        format: 'pdf',
        pages: const [
          ConvertedPage(index: 1, text: 'The knight ♘ dominates. 1.e4 e5'),
        ],
      );
      final html = buildPdfChapters(conversion).single.html;
      expect(html.contains('The knight N dominates.'), isTrue);
      expect(html.contains('♘'), isFalse);
    });

    test('rejoins words split by a line-wrap hyphen and strips tofu chars', () {
      // OCR splits "character" across a line with a soft hyphen (U+00AD), and
      // leaves a stray zero-width space (U+200B) and replacement char (U+FFFD)
      // elsewhere in the prose — all render as boxes in the reader font.
      final conversion = BookConversion(
        title: 'T',
        format: 'pdf',
        pages: const [
          ConvertedPage(
            index: 1,
            text: 'a char­\nacter and​ more� prose',
          ),
        ],
      );
      final html = buildPdfChapters(conversion).single.html;

      // The split word is rejoined with no hyphen and no space.
      expect(html.contains('character'), isTrue);
      // No invisible/format characters survive into the HTML.
      expect(html.contains('­'), isFalse);
      expect(html.contains('​'), isFalse);
      expect(html.contains('�'), isFalse);
    });

    test('escapes HTML metacharacters in page text', () {
      final conversion = BookConversion(
        title: 'T',
        format: 'pdf',
        pages: const [ConvertedPage(index: 1, text: 'a < b & c > d')],
      );
      final html = buildPdfChapters(conversion).single.html;
      expect(html.contains('&lt;'), isTrue);
      expect(html.contains('&amp;'), isTrue);
      expect(html.contains('&gt;'), isTrue);
    });
  });

  group('hasExtractableText', () {
    BookConversion pdf(List<String?> pageTexts) => BookConversion(
          title: 'T',
          format: 'pdf',
          pages: [
            for (var i = 0; i < pageTexts.length; i++)
              ConvertedPage(index: i + 1, text: pageTexts[i]),
          ],
        );

    test('true for a normal text PDF', () {
      expect(
        pdf(['1.e4 e5 2.Nf3 Nc6 a real page of prose and moves.']).hasExtractableText,
        isTrue,
      );
    });

    test('false for an image-only PDF (empty/near-empty page text)', () {
      expect(pdf(['', '', '', '']).hasExtractableText, isFalse);
      expect(pdf([null, null]).hasExtractableText, isFalse);
      expect(pdf(['  \n ', ' ']).hasExtractableText, isFalse);
    });

    test('EPUB is always considered to have text', () {
      const c = BookConversion(title: 'T', format: 'epub', pages: []);
      expect(c.hasExtractableText, isTrue);
    });
  });

  group('BookConversion JSON round-trip', () {
    test('survives serialize → deserialize unchanged', () {
      final conversion = BookConversion(
        title: 'Book',
        format: 'pdf',
        pages: const [
          ConvertedPage(index: 1, text: 'hello', diagrams: [
            ConvertedDiagram(
              fen: '8/8/8/8/8/8/8/8 w - - 0 1',
              cropPngBase64: 'AAAA',
              left: 10,
              top: 20,
              size: 200,
              anchor: 3,
            ),
          ]),
          ConvertedPage(index: 2, text: 'world'),
        ],
      );
      final round = BookConversion.fromJson(conversion.toJson());
      expect(round.title, 'Book');
      expect(round.pages, hasLength(2));
      final d = round.diagramsFor(1).single;
      expect(d.fen, '8/8/8/8/8/8/8/8 w - - 0 1');
      expect(d.left, 10);
      expect(d.anchor, 3);
      expect(round.pages[1].text, 'world');
      expect(round.diagramsFor(2), isEmpty);
    });
  });

  group('view mode persistence', () {
    test('records and reloads the per-book view mode', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c1 = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(c1.dispose);
      c1.read(libraryStoreProvider.notifier).setViewMode('book.pdf', 'html');
      expect(
          c1.read(libraryStoreProvider.notifier).viewModeFor('book.pdf'),
          'html');
      expect(
          c1.read(libraryStoreProvider.notifier).viewModeFor('other.pdf'),
          isNull);

      // A fresh store over the same prefs reloads the choice.
      final c2 = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(c2.dispose);
      expect(
          c2.read(libraryStoreProvider.notifier).viewModeFor('book.pdf'),
          'html');
    });
  });
}
