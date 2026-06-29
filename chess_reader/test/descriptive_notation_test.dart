import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/features/reader/domain/descriptive_notation.dart';

/// Plays a descriptive-notation line from the initial position and returns the
/// algebraic SAN of each move (or '??' if a move failed to resolve).
List<String> _play(List<String> descriptive) {
  var pos = Chess.initial as Position;
  final sans = <String>[];
  for (final d in descriptive) {
    final move = DescriptiveNotation.toMove(pos, d);
    if (move == null) {
      sans.add('??($d)');
      break;
    }
    final (next, san) = pos.makeSan(move);
    sans.add(san);
    pos = next;
  }
  return sans;
}

void main() {
  test('resolves the opening line from Lasker Chess Strategy p.22', () {
    // 1. P-Q4 P-Q4 2. P-QB4 P-K3 3. Kt-QB3 P-QB4 4. PxQP KPxP
    // 5. P-K4 QPxP 6. P-Q5 Kt-KB3 7. B-KKt5 B-K2 8. KKt-K2 Castles
    final sans = _play([
      'P-Q4', 'P-Q4',
      'P-QB4', 'P-K3',
      'Kt-QB3', 'P-QB4',
      'PxQP', 'KPxP',
      'P-K4', 'QPxP',
      'P-Q5', 'Kt-KB3',
      'B-KKt5', 'B-K2',
      'KKt-K2', 'Castles',
    ]);

    expect(sans, [
      'd4', 'd5',
      'c4', 'e6',
      'Nc3', 'c5',
      'cxd5', 'exd5',
      'e4', 'dxe4',
      'd5', 'Nf6',
      'Bg5', 'Be7',
      'Nge2', 'O-O',
    ]);
  });

  test('descriptive ranks are relative to the side to move', () {
    var pos = Chess.initial as Position;
    // White P-K4 => e4
    pos = pos.play(DescriptiveNotation.toMove(pos, 'P-K4')!);
    expect(pos.board.pieceAt(Square.fromName('e4'))?.role, Role.pawn);
    // Black P-K4 => e5 (rank counts from Black's side)
    pos = pos.play(DescriptiveNotation.toMove(pos, 'P-K4')!);
    expect(pos.board.pieceAt(Square.fromName('e5'))?.role, Role.pawn);
  });

  test('castling: bare Castles is kingside; Castles QR is queenside', () {
    // Reach a position where both sides can castle either way.
    const fen = 'r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R3K2R w KQkq - 0 1';
    final pos = Setup.parseFen(fen).let((s) => Chess.fromSetup(s));
    final kingside = pos.makeSan(DescriptiveNotation.toMove(pos, 'Castles')!).$2;
    final queenside =
        pos.makeSan(DescriptiveNotation.toMove(pos, 'Castles QR')!).$2;
    expect(kingside, 'O-O');
    expect(queenside, 'O-O-O');
  });

  test('rejects prose / non-moves', () {
    final pos = Chess.initial as Position;
    expect(DescriptiveNotation.toMove(pos, 'the'), isNull);
    expect(DescriptiveNotation.toMove(pos, 'B-side'), isNull);
    expect(DescriptiveNotation.toMove(pos, 'P-K9'), isNull);
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
