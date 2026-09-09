import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/computer_opponent/domain/computer_opponent_models.dart';
import 'package:chess_reader/features/reader/domain/move_resolver.dart';
import 'package:chess_reader/core/models/move_token.dart';
import 'package:chess_reader/features/reader/state/book_providers.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('repetitionKeyFor', () {
    test('normalizes placement, turn, and castling rights', () {
      final pos = Chess.initial;
      final key = repetitionKeyFor(pos);
      expect(key, 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -');
    });

    test('ignores fullmove and halfmove counters', () {
      final pos1 = Chess.fromSetup(Setup.parseFen(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      ));
      final pos2 = Chess.fromSetup(Setup.parseFen(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 4 10',
      ));
      expect(repetitionKeyFor(pos1), equals(repetitionKeyFor(pos2)));
    });

    test('includes en passant square only when an ep capture is legally possible', () {
      // 1. e4 e5 2. Nf3 a6 3. e5 d5 - Black's d5 creates ep square d6; White has pawn on e5 that can capture exd6!
      final epCapturablePos = Chess.fromSetup(Setup.parseFen(
        'rnbqkbnr/1pp1pppp/p7/3pP3/8/5N2/PPPP1PPP/RNBQKB1R w KQkq d6 0 4',
      ));
      final key1 = repetitionKeyFor(epCapturablePos);
      expect(key1, contains('d6'));

      // Position where ep square is recorded in FEN but no opposing pawn can capture it
      final epNotCapturablePos = Chess.fromSetup(Setup.parseFen(
        'rnbqkbnr/ppp1pppp/8/3p4/8/8/PPPPPPPP/RNBQKBNR w KQkq d6 0 2',
      ));
      final key2 = repetitionKeyFor(epNotCapturablePos);
      expect(key2.endsWith('-'), isTrue);
    });
  });

  group('ComputerStrengthPreset', () {
    test('defines expected presets and Elo bounds', () {
      expect(ComputerStrengthPreset.casual.elo, 1350);
      expect(ComputerStrengthPreset.intermediate.elo, 1650);
      expect(ComputerStrengthPreset.advanced.elo, 2000);
      expect(ComputerStrengthPreset.fullStrength.elo, isNull);
    });
  });

  group('SavedReaderContext and GameSessionSnapshot', () {
    test('captures and restores complete reader and excursion state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final session = container.read(gameSessionProvider.notifier);
      final initialFen = container.read(gameSessionProvider).fen;

      // Book position
      final bookPos = Chess.initial.play(NormalMove.fromUci('e2e4'));
      session.setPosition(bookPos, lastMove: NormalMove.fromUci('e2e4'));
      expect(session.state.onBookLine, isTrue);

      // Excursion moves
      session.playMove(NormalMove.fromUci('c7c5'));
      session.playMove(NormalMove.fromUci('g1f3'));
      expect(session.state.onBookLine, isFalse);
      expect(session.state.canUndo, isTrue);

      final snapshot = session.captureSnapshot();
      final activeLine = ActiveLine(
        moves: [
          ResolvedMove(
            token: const MoveToken(
              san: 'e4',
              start: 0,
              end: 2,
              moveNumber: 1,
              isWhiteHint: true,
            ),
            positionBefore: Chess.initial,
            positionAfter: bookPos,
            move: NormalMove.fromUci('e2e4'),
          ),
        ],
        index: 0,
        sourceKey: 1,
      );

      final context = SavedReaderContext(
        sessionSnapshot: snapshot,
        activeLine: activeLine,
      );

      // Mutate session as if starting a computer game
      session.reset();
      expect(session.state.fen, initialFen);
      expect(session.state.canUndo, isFalse);

      // Restore
      session.restoreSnapshot(context.sessionSnapshot);
      expect(session.state.fen, snapshot.state.fen);
      expect(session.state.onBookLine, isFalse);
      expect(session.state.canUndo, isTrue);

      // Undo excursion restores to previous move
      session.undo();
      expect(session.state.lastMove, NormalMove.fromUci('c7c5'));

      // Back to book restores to book anchor
      session.backToBook();
      expect(session.state.onBookLine, isTrue);
      expect(session.state.fen, bookPos.fen);
    });
  });
}
