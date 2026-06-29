import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/features/reader/domain/figurine_map.dart';
import 'package:chess_reader/features/reader/domain/move_resolver.dart';
import 'package:chess_reader/features/reader/domain/san_tokenizer.dart';

void main() {
  group('normalizeFigurines', () {
    test('maps unicode figurines to SAN letters with offset map', () {
      const original = '12...♞xd4 13.♘xd4';
      final n = normalizeFigurines(original);
      expect(n.text, '12...Nxd4 13.Nxd4');
      // 'N' at normalized index 5 came from '♞' at original index 5.
      expect(n.sourceOffsets[5], 5);
      expect(n.sourceOffsets.length, n.text.length + 1);
    });

    test('drops pawn figurines and keeps offsets consistent', () {
      const original = '♙e4';
      final n = normalizeFigurines(original);
      expect(n.text, 'e4');
      expect(n.sourceOffsets[0], 1); // 'e' came from original index 1.
    });
  });

  group('SanTokenizer', () {
    test('tokenizes a numbered main line', () {
      final tokens =
          SanTokenizer.tokenize('1.e4 e5 2.Nf3 Nc6 3.Bb5 a6 4.O-O Nf6');
      expect(tokens.map((t) => t.san).toList(),
          ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'O-O', 'Nf6']);
      expect(tokens[0].moveNumber, 1);
      expect(tokens[0].isWhiteHint, true);
      expect(tokens[1].moveNumber, 1);
      expect(tokens[1].isWhiteHint, false);
      expect(tokens[4].moveNumber, 3);
    });

    test('handles black-to-move numbering, checks and NAGs', () {
      final tokens = SanTokenizer.tokenize(
          'After 12...Qxd4+!? 13.Rxd4 exd4? White is winning, e.g. 14.e8=Q#');
      expect(tokens.map((t) => t.san).toList(),
          ['Qxd4+', 'Rxd4', 'exd4', 'e8=Q#']);
      expect(tokens[0].moveNumber, 12);
      expect(tokens[0].isWhiteHint, false);
    });

    test('tokenizes figurine notation', () {
      final tokens = SanTokenizer.tokenize('1.♘f3 ♞c6 2.♗c4 d5');
      expect(tokens.map((t) => t.san).toList(), ['Nf3', 'Nc6', 'Bc4', 'd5']);
    });

    test('normalizes zero-style castling and disambiguation', () {
      final tokens = SanTokenizer.tokenize('15.0-0-0 Rad8 16.Nbd2');
      expect(tokens.map((t) => t.san).toList(), ['O-O-O', 'Rad8', 'Nbd2']);
    });

    test('does not match inside words or numbers', () {
      final tokens = SanTokenizer.tokenize(
          'In 1985 the Be2-system scored 75% in game 4 of 64.');
      // "Be2" is a legitimate-looking token (hyphen boundary); years and
      // bare digits must not produce moves.
      expect(tokens.map((t) => t.san).toList(), ['Be2']);
    });

    test('token offsets point at the original text', () {
      const text = 'Play 2.♘f3 here';
      final tokens = SanTokenizer.tokenize(text);
      expect(tokens, hasLength(1));
      expect(text.substring(tokens[0].start, tokens[0].end), '♘f3');
    });
  });

  group('MoveResolver', () {
    test('resolves a clean main line into positions', () {
      final tokens = SanTokenizer.tokenize('1.e4 e5 2.Nf3 Nc6 3.Bb5');
      final line = MoveResolver.resolve(tokens);
      expect(line.moves, hasLength(5));
      expect(line.unresolved, isEmpty);
      expect(
        line.moves.last.positionAfter.fen,
        'r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3',
      );
    });

    test('skips prose false positives without derailing the line', () {
      // "b4 square" style prose: illegal in context, must be skipped.
      final tokens = SanTokenizer.tokenize(
          '1.e4 e5 2.Nf3 controlling d4 and threatening Nc6 no wait 2...Nc6');
      final line = MoveResolver.resolve(tokens);
      expect(line.moves.map((m) => m.token.san).toList(),
          ['e4', 'e5', 'Nf3', 'Nc6']);
      // 'd4' was tokenized but is illegal for black after 2.Nf3 — skipped.
      expect(line.unresolved.map((t) => t.san), contains('d4'));
    });

    test('detects English descriptive moves, flagged isDescriptive', () {
      // Real typography from Lasker "Chess Strategy" p.22: spaced rank,
      // doubled dash, spaced piece qualifier, and "Castles".
      final tokens = SanTokenizer.tokenize(
          '1. P-Q 4 P-Q4 7. B--KKt5 B-K2 8. K Kt-K2 Castles');
      final descr = tokens.where((t) => t.isDescriptive).map((t) => t.san);
      expect(descr,
          containsAll(['P-Q 4', 'P-Q4', 'B--KKt5', 'B-K2', 'K Kt-K2', 'Castles']));
      // Plain English with hyphens must NOT be read as moves.
      final prose = SanTokenizer.tokenize(
          'on the K-side, co-operating, a well-known Q-and-A');
      expect(prose.where((t) => t.isDescriptive), isEmpty);
    });

    test('resolves a full descriptive line end to end (p.22)', () {
      // The book prints this line in both notations; algebraic is the oracle.
      final tokens = SanTokenizer.tokenize(
          '1. P-Q 4 P-Q4 2. P-QB4 P-K3 3. Kt-QB3 P-QB4 4. PxQP KPxP '
          '5. P-K4 QPxP 6. P-Q5 Kt-KB3 7. B--KKt5 B-K2 8. K Kt-K2 Castles');
      final line = MoveResolver.resolve(tokens);
      final sans = [
        for (final m in line.moves) m.positionBefore.makeSan(m.move).$2
      ];
      expect(sans, [
        'd4', 'd5', 'c4', 'e6', 'Nc3', 'c5', 'cxd5', 'exd5',
        'e4', 'dxe4', 'd5', 'Nf6', 'Bg5', 'Be7', 'Nge2', 'O-O',
      ]);
      expect(line.unresolved, isEmpty);
    });
  });
}
