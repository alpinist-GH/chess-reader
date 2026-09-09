import 'package:chess_reader/core/models/move_token.dart';
import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/guess_move/domain/guess_move_models.dart';
import 'package:chess_reader/features/guess_move/state/guess_move_provider.dart';
import 'package:chess_reader/features/reader/domain/move_resolver.dart';
import 'package:chess_reader/features/reader/state/book_providers.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('grades the next resolved book move and restores a wrong attempt', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final e4 = NormalMove.fromUci('e2e4');
    final e5 = NormalMove.fromUci('e7e5');
    final afterE4 = Chess.initial.play(e4);
    final nf3 = NormalMove.fromUci('g1f3');
    final afterE5 = afterE4.play(e5);
    final afterNf3 = afterE5.play(nf3);
    final line = ActiveLine(
      moves: [
        ResolvedMove(
          token: const MoveToken(san: 'e4', start: 0, end: 2),
          move: e4,
          positionBefore: Chess.initial,
          positionAfter: afterE4,
        ),
        ResolvedMove(
          token: const MoveToken(san: 'e5', start: 3, end: 5),
          move: e5,
          positionBefore: afterE4,
          positionAfter: afterE5,
        ),
        ResolvedMove(
          token: const MoveToken(san: 'Nf3', start: 6, end: 9),
          move: nf3,
          positionBefore: afterE5,
          positionAfter: afterNf3,
        ),
      ],
      index: 0,
      sourceKey: 1,
    );

    container
        .read(activeLineProvider.notifier)
        .select(line.moves, line.index, line.sourceKey);
    final guess = container.read(guessMoveProvider.notifier);
    guess.start();
    expect(container.read(guessMoveProvider).phase, GuessMovePhase.active);
    expect(container.read(guessMoveProvider).score, 0);

    guess.requestHint();
    expect(container.read(guessMoveProvider).hint, 'Starts from e7');
    expect(container.read(guessMoveProvider).hintsUsed, 1);

    container
        .read(gameSessionProvider.notifier)
        .playMove(NormalMove.fromUci('c7c6'));
    expect(container.read(guessMoveProvider).phase, GuessMovePhase.incorrect);
    expect(container.read(gameSessionProvider).fen, afterE4.fen);

    guess.retry();
    // Use a newly-created move to ensure grading compares chess identity, not
    // Dart object identity.
    container
        .read(gameSessionProvider.notifier)
        .playMove(NormalMove.fromUci('e7e5'));
    expect(container.read(guessMoveProvider).phase, GuessMovePhase.active);
    expect(container.read(activeLineProvider)!.index, 1);
    expect(container.read(guessMoveProvider).correctMoves, 1);
    expect(container.read(gameSessionProvider).fen, afterE5.fen);

    container
        .read(gameSessionProvider.notifier)
        .playMove(NormalMove.fromUci('g1f3'));
    expect(container.read(guessMoveProvider).phase, GuessMovePhase.correct);
    expect(container.read(activeLineProvider)!.index, 2);
    expect(container.read(guessMoveProvider).correctMoves, 2);
    expect(container.read(gameSessionProvider).fen, afterNf3.fen);
    expect(container.read(guessMoveProvider).score, 150);
  });
}
