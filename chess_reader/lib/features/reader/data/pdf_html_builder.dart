import '../../../core/models/move_token.dart';
import '../domain/figurine_map.dart';
import '../domain/move_resolver.dart';
import '../domain/san_tokenizer.dart';
import 'book_conversion.dart';
import 'epub_book.dart';

/// Turns a PDF [BookConversion] into the same `EpubChapter` shape the EPUB
/// reader uses, so both render through one HTML view. One chapter per page.
///
/// Moves are resolved over the whole book as a single continuous stream (games
/// span pages), exactly like `PageMovesService`, then each page's resolved
/// tokens are wrapped in `<chessmove>` and its diagrams inserted as
/// `<chessdiagram>` at their detected vertical position.
List<EpubChapter> buildPdfChapters(BookConversion conversion) {
  final pageTexts = [for (final p in conversion.pages) p.text ?? ''];
  final pageTokens = [for (final t in pageTexts) SanTokenizer.tokenize(t)];

  final allTokens = [for (final tokens in pageTokens) ...tokens];
  final line = MoveResolver.resolve(allTokens);
  final resolvedByToken = {for (final r in line.moves) r.token: r};

  final chapters = <EpubChapter>[];
  for (var i = 0; i < conversion.pages.length; i++) {
    final page = conversion.pages[i];
    final text = pageTexts[i];
    final resolvedTokens =
        pageTokens[i].where(resolvedByToken.containsKey).toList();
    final moves = [for (final t in resolvedTokens) resolvedByToken[t]!];
    chapters.add(EpubChapter(
      title: 'Page ${page.index}',
      html: _buildPageHtml(text, resolvedTokens, page.diagrams),
      moves: moves,
    ));
  }
  return chapters;
}

String _buildPageHtml(
  String text,
  List<MoveToken> resolvedTokens,
  List<ConvertedDiagram> diagrams,
) {
  final sortedDiagrams = [...diagrams]
    ..sort((a, b) => a.anchor.compareTo(b.anchor));

  final buf = StringBuffer('<div><p>');
  var cursor = 0;
  var di = 0;

  void flushDiagramsBefore(int limit) {
    while (di < sortedDiagrams.length && sortedDiagrams[di].anchor <= limit) {
      final at = sortedDiagrams[di].anchor.clamp(cursor, text.length);
      buf.write(_formatText(text.substring(cursor, at)));
      buf.write('</p>');
      buf.write(_diagramHtml(sortedDiagrams[di]));
      buf.write('<p>');
      cursor = at;
      di++;
    }
  }

  for (var k = 0; k < resolvedTokens.length; k++) {
    final t = resolvedTokens[k];
    flushDiagramsBefore(t.start);
    if (t.start > cursor) {
      buf.write(_formatText(text.substring(cursor, t.start)));
    }
    // Show standard SAN (figurine glyphs already mapped to letters), not the
    // book's raw glyph soup. The chip's idx still drives the side board.
    final inner = _escapeText(t.san);
    buf.write('<chessmove idx="$k">$inner</chessmove>');
    cursor = t.end;
  }

  // Diagrams after the last move, then any trailing text.
  flushDiagramsBefore(text.length);
  if (cursor < text.length) {
    buf.write(_formatText(text.substring(cursor)));
  }
  buf.write('</p></div>');
  return buf.toString();
}

String _diagramHtml(ConvertedDiagram d) =>
    '<chessdiagram fen="${_escapeAttr(d.fen)}"'
    '${d.annotations.isEmpty ? '' : ' ann="${_escapeAttr(d.annotations)}"'}>'
    '<img src="data:image/png;base64,${d.cropPngBase64}"></chessdiagram>';

/// A word the OCR splits across a wrapped line ends in a hyphen — usually a
/// soft hyphen (U+00AD) or a Unicode hyphen variant (U+2010/U+2011) the reader
/// font has no glyph for, so it shows as a "tofu" box. Drop the hyphen *and*
/// the single line break so the word rejoins ("char­\nacter" → "character").
/// A blank line (paragraph break) is left alone.
final _lineWrapHyphen = RegExp('[­‐‑]\n(?!\n)');

/// Other invisible / format characters with no glyph in the reader font that
/// would otherwise render as boxes: stray soft hyphens (mid-line, not at a
/// wrap), zero-width spaces/joiners, directional marks, word joiner, BOM, and
/// the Unicode replacement char left over from unmapped glyphs.
final _invisibleChars =
    RegExp('[­​-‏⁠﻿�]');

/// Escapes a text run and turns blank lines into paragraph breaks (single
/// newlines become spaces — PDF lines are wrapped, not semantic). Figurine
/// glyphs in the prose between moves are normalized to letters for display
/// (`normalizeFigurines` is prose-safe), so non-standard fonts don't leak
/// glyph soup into the reading view. Line-wrap hyphens and stray invisible
/// characters are cleaned up before paragraph handling.
String _formatText(String s) => _escapeText(normalizeFigurines(s)
        .text
        .replaceAll(_lineWrapHyphen, '')
        .replaceAll(_invisibleChars, ''))
    .replaceAll(RegExp(r'\n{2,}'), '</p><p>')
    .replaceAll('\n', ' ');

String _escapeText(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _escapeAttr(String s) => _escapeText(s).replaceAll('"', '&quot;');
