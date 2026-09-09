import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/game_session.dart';
import '../../reader/state/book_providers.dart';
import '../domain/guess_move_models.dart';

class GuessMoveNotifier extends Notifier<GuessMoveState> {
  int _watchedRevision = -1;

  @override
  GuessMoveState build() {
    ref.listen<GameSessionState>(gameSessionProvider, (previous, next) {
      if (!state.isActive ||
          previous == null ||
          next.revision == _watchedRevision) {
        return;
      }
      _watchedRevision = next.revision;
      if (next.origin != PositionOrigin.app &&
          next.origin != PositionOrigin.physical) {
        return;
      }
      final move = next.lastMove;
      final target = state.target;
      if (move == null ||
          target == null ||
          next.fen == target.positionBefore.fen) {
        return;
      }
      _evaluate(move);
    });
    return const GuessMoveState();
  }

  void start() {
    if (state.isActive) return;
    final line = ref.read(activeLineProvider);
    final session = ref.read(gameSessionProvider);
    if (line == null || !session.legal || line.index >= line.moves.length - 1) {
      return;
    }

    final target = line.moves[line.index + 1];
    // The active line may have been changed without the board being updated by
    // a caller. Refuse to grade a move against a different position.
    if (target.positionBefore.fen != session.fen) return;

    _watchedRevision = session.revision;
    state = GuessMoveState(
      phase: GuessMovePhase.active,
      target: target,
      startPosition: session.position,
      startSnapshot: ref.read(gameSessionProvider.notifier).captureSnapshot(),
    );
  }

  void _evaluate(NormalMove move) {
    final target = state.target;
    final snapshot = state.startSnapshot;
    if (target == null || snapshot == null) return;

    if (target.move is NormalMove && move.uci == target.move.uci) {
      final correctMoves = state.correctMoves + 1;
      final line = ref.read(activeLineProvider);
      if (line != null && line.hasNext) {
        ref.read(activeLineProvider.notifier).advanceForGuess();
        final advancedLine = ref.read(activeLineProvider);
        final nextTarget = advancedLine != null && advancedLine.hasNext
            ? advancedLine.moves[advancedLine.index + 1]
            : null;
        if (nextTarget == null) {
          state = state.copyWith(
            phase: GuessMovePhase.correct,
            correctMoves: correctMoves,
            feedback: 'Training complete: ${target.token.san}',
          );
          return;
        }
        state = state.copyWith(
          phase: GuessMovePhase.active,
          target: nextTarget,
          startPosition: ref.read(gameSessionProvider).position,
          startSnapshot: ref
              .read(gameSessionProvider.notifier)
              .captureSnapshot(),
          correctMoves: correctMoves,
          hintLevel: 0,
          feedback: 'Correct: ${target.token.san} — next move',
        );
      } else {
        state = state.copyWith(
          phase: GuessMovePhase.correct,
          correctMoves: correctMoves,
          feedback: 'Training complete: ${target.token.san}',
        );
      }
      return;
    }

    final attempts = state.attempts + 1;
    state = state.copyWith(
      phase: GuessMovePhase.incorrect,
      attempts: attempts,
      feedback: 'Not the book move. Try again.',
    );
    ref.read(gameSessionProvider.notifier).restoreSnapshot(snapshot);
  }

  void requestHint() {
    if (!state.canRequestHint) return;
    state = state.copyWith(
      hintLevel: state.hintLevel + 1,
      hintsUsed: state.hintsUsed + 1,
    );
  }

  void retry() {
    final target = state.target;
    final snapshot = state.startSnapshot;
    if (target == null || snapshot == null) return;
    ref.read(gameSessionProvider.notifier).restoreSnapshot(snapshot);
    _watchedRevision = ref.read(gameSessionProvider).revision;
    state = state.copyWith(
      phase: GuessMovePhase.active,
      hintLevel: 0,
      clearFeedback: true,
    );
  }

  void dismiss() => state = const GuessMoveState();
}

final guessMoveProvider = NotifierProvider<GuessMoveNotifier, GuessMoveState>(
  GuessMoveNotifier.new,
);
