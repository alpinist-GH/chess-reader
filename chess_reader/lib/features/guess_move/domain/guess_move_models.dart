import 'package:dartchess/dartchess.dart';

import '../../../core/state/game_session.dart';
import '../../reader/domain/move_resolver.dart';

enum GuessMovePhase { idle, active, correct, incorrect }

class GuessMoveState {
  const GuessMoveState({
    this.phase = GuessMovePhase.idle,
    this.target,
    this.startPosition,
    this.startSnapshot,
    this.attempts = 0,
    this.correctMoves = 0,
    this.hintsUsed = 0,
    this.hintLevel = 0,
    this.feedback,
  });

  final GuessMovePhase phase;
  final ResolvedMove? target;
  final Position? startPosition;
  final GameSessionSnapshot? startSnapshot;
  final int attempts;
  final int correctMoves;
  final int hintsUsed;
  final int hintLevel;
  final String? feedback;

  bool get isActive => phase == GuessMovePhase.active;
  bool get isFinished =>
      phase == GuessMovePhase.correct || phase == GuessMovePhase.incorrect;

  /// A simple, explainable score: each solved move is worth 100 points, with
  /// small penalties for wrong attempts and revealed hints.
  int get score =>
      (correctMoves * 100 - attempts * 25 - hintsUsed * 25).clamp(0, 1 << 31);

  bool get canRequestHint => isActive && hintLevel < 3;

  String? get hint {
    final move = target?.move;
    if (move is! NormalMove || hintLevel == 0) return null;
    if (hintLevel == 1) return 'Starts from ${move.from.name}';
    if (hintLevel == 2) return 'Moves to ${move.to.name}';
    return 'Notation: ${target!.token.san}';
  }

  GuessMoveState copyWith({
    GuessMovePhase? phase,
    ResolvedMove? target,
    Position? startPosition,
    GameSessionSnapshot? startSnapshot,
    int? attempts,
    int? correctMoves,
    int? hintsUsed,
    int? hintLevel,
    String? feedback,
    bool clearFeedback = false,
  }) {
    return GuessMoveState(
      phase: phase ?? this.phase,
      target: target ?? this.target,
      startPosition: startPosition ?? this.startPosition,
      startSnapshot: startSnapshot ?? this.startSnapshot,
      attempts: attempts ?? this.attempts,
      correctMoves: correctMoves ?? this.correctMoves,
      hintsUsed: hintsUsed ?? this.hintsUsed,
      hintLevel: hintLevel ?? this.hintLevel,
      feedback: clearFeedback ? null : (feedback ?? this.feedback),
    );
  }
}
