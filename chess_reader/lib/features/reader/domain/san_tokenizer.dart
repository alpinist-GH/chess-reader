import '../../../core/models/move_token.dart';
import 'figurine_map.dart';

/// Tokenizes book text into candidate chess moves.
///
/// Pure function over text: no legality checking here. The resolver decides
/// which tokens are real moves; this stage only finds everything that *looks*
/// like SAN, including figurine notation, and records move-number hints.
///
/// v1 grammar: move numbers, SAN moves, castling. NAG suffixes (`!?` etc.)
/// are consumed but stripped from the SAN. Variation parentheses are left to
/// Phase 3.
///
/// Also recognizes **English descriptive notation** (`P-K4`, `Kt-QB3`, `PxQP`,
/// `Castles`) used by pre-1980 books. Descriptive moves are board-relative and
/// can only be turned into a concrete move by the resolver, so the token just
/// carries the raw text with [MoveToken.isDescriptive] set. Detection is
/// deliberately broad — the resolver drops anything illegal or ambiguous, so a
/// prose false positive cannot become a wrong move — but it stays case-sensitive
/// (descriptive uses capitals) to keep ordinary hyphenated words out.
class SanTokenizer {
  SanTokenizer._();

  // --- Descriptive-notation fragments -------------------------------------
  // A piece/pawn cluster, e.g. `P`, `Kt`, `QKt`, `KB`, `KP`, `QBP`. Internal
  // spaces are tolerated ("K Kt", "P-Q 4") and stripped by the resolver.
  static const _sideQ = r'(?:[KQ]\s*)?';
  static const _pieceLetter = r'(?:Kt|N|[RB])';
  static const _cluster =
      '(?:$_sideQ$_pieceLetter\\s*P|(?:[KQ]\\s*)?P|$_sideQ$_pieceLetter|[KQ])';
  // A destination square: a file (named like a piece) plus a rank digit.
  static const _destSq = '(?:$_sideQ$_pieceLetter\\s*[1-8]|[KQ]\\s*[1-8])';
  // Optional promotion, e.g. `=Q` or `(Q)`.
  static const _promo = r'(?:\s*[=(]\s*(?:Kt|[QRBN])\)?)?';
  // The dash may be doubled in some typesetting ("B--KKt5").
  static const _descriptive = '(?<descr>Castles(?:\\s+[KQ]R)?'
      '|$_cluster\\s*(?:-+\\s*$_destSq|[x×]\\s*$_cluster)$_promo)';

  /// `12.` `12...` `12. ...` move-number markers, a SAN move, or a descriptive
  /// move.
  ///
  /// SAN alternatives, in order: castling (longest first), piece move with
  /// optional disambiguation, pawn move with optional capture/promotion.
  /// Lookarounds keep matches from starting inside words or numbers
  /// ("Mb4" or "e45" must not yield "b4"/"e4"). The descriptive alternative is
  /// last so algebraic always wins where both could match.
  static final RegExp _pattern = RegExp(
    // "12." / "12..." / "12. ..." style.
    r'(?<!\d)(?<number>\d{1,3})\s*\.(?<dots>\s*\.\.\.?|…)?'
    // Bare "38 Rc3" style (Gambit and others print no dot): the number must
    // be directly followed by something move-shaped.
    r'|(?<!\d)(?<barenum>\d{1,3})'
    r'(?=\s+(?:[KQRBN][a-h1-8x]|[a-h][1-8x]|O-O|0-0))'
    r'|(?<![A-Za-z0-9=])'
    // `l` is accepted as a destination rank: some chess fonts print rank 1
    // as lowercase L ("Qcl" = Qc1). It is normalized to 1 below; the word
    // boundaries above keep prose ("personal") out.
    r'(?<san>O-O-O|O-O|0-0-0|0-0'
    r'|[KQRBN][a-h]?[1-8]?x?[a-h][1-8l]'
    r'|[a-h](?:x[a-h])?[1-8l](?:=[QRBN])?'
    r')'
    r'(?<suffix>[+#]?[!?]{0,2})'
    r'(?![A-Za-z0-9=])'
    // Descriptive notation (case-sensitive, capitals only).
    '|(?<![A-Za-z])$_descriptive'
    r'(?![A-Za-z])',
  );

  static List<MoveToken> tokenize(String text) {
    final normalized = normalizeFigurines(text);
    final tokens = <MoveToken>[];

    int? pendingNumber;
    bool? pendingIsWhite;

    for (final match in _pattern.allMatches(normalized.text)) {
      final numberGroup = match.namedGroup('number');
      if (numberGroup != null) {
        pendingNumber = int.parse(numberGroup);
        pendingIsWhite = match.namedGroup('dots') == null;
        continue;
      }
      final bareNumber = match.namedGroup('barenum');
      if (bareNumber != null) {
        pendingNumber = int.parse(bareNumber);
        pendingIsWhite = true;
        continue;
      }

      final descr = match.namedGroup('descr');
      if (descr != null) {
        tokens.add(MoveToken(
          san: descr,
          start: normalized.sourceOffsets[match.start],
          end: normalized.sourceOffsets[match.start + descr.length],
          moveNumber: pendingNumber,
          isWhiteHint: pendingIsWhite,
          isDescriptive: true,
        ));
        if (pendingIsWhite == true) {
          pendingIsWhite = false;
        } else {
          pendingNumber = null;
          pendingIsWhite = null;
        }
        continue;
      }

      final san = match.namedGroup('san')!;
      final check = match.namedGroup('suffix') ?? '';
      // Keep check/mate marks (dartchess accepts them), drop NAG glyphs.
      final checkMark = check.startsWith('+') || check.startsWith('#')
          ? check[0]
          : '';
      // 0-0 style castling is normalized to letter-O SAN; trailing rank-1
      // glyph collisions ("Qcl") to digits.
      var normalizedSan =
          san.startsWith('0') ? san.replaceAll('0', 'O') : san;
      normalizedSan = normalizedSan.replaceAll('l', '1');

      tokens.add(MoveToken(
        san: normalizedSan + checkMark,
        start: normalized.sourceOffsets[match.start],
        // Cover the check/mate mark too: it is part of the printed move.
        end: normalized
            .sourceOffsets[match.start + san.length + checkMark.length],
        moveNumber: pendingNumber,
        isWhiteHint: pendingIsWhite,
      ));

      // A move number only applies to the moves immediately following it:
      // after a white move, the next unnumbered move is black's reply.
      if (pendingIsWhite == true) {
        pendingIsWhite = false;
      } else {
        pendingNumber = null;
        pendingIsWhite = null;
      }
    }
    return tokens;
  }
}
