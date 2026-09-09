import 'package:dartchess/dartchess.dart';

import '../../../core/state/game_session.dart';
import '../../reader/state/book_providers.dart';

/// Explicit phases for the computer game state machine.
enum ComputerGamePhase {
  /// No computer game is currently active.
  idle,

  /// Setup sheet / dialog is open to configure game options.
  setup,

  /// Active game: waiting for the human player to make their move.
  humanTurn,

  /// Active game: engine is currently searching for a move.
  engineThinking,

  /// Active game: engine move committed; waiting for physical board to match via LEDs.
  awaitingPhysicalMove,

  /// Active game paused (e.g. app backgrounded, reconnecting board, or user paused).
  paused,

  /// Game ended with an outcome (checkmate, stalemate, draw, resignation).
  finished,

  /// Engine or transport error occurred; allows Retry or Exit without discarding state.
  error,
}

/// Human-like strength presets bounding Stockfish's UCI_LimitStrength and UCI_Elo.
enum ComputerStrengthPreset {
  casual(
    label: 'Casual',
    elo: 1350,
    description: '~1350 Elo — Friendly & forgiving',
  ),
  intermediate(
    label: 'Intermediate',
    elo: 1650,
    description: '~1650 Elo — Solid club play',
  ),
  advanced(
    label: 'Advanced',
    elo: 2000,
    description: '~2000 Elo — Strong tactical play',
  ),
  fullStrength(
    label: 'Full Strength',
    elo: null,
    description: 'Uncapped engine strength',
  );

  const ComputerStrengthPreset({
    required this.label,
    required this.elo,
    required this.description,
  });

  final String label;
  final int? elo;
  final String description;
}

/// Possible terminal outcomes of a game vs computer.
enum ComputerGameOutcome {
  checkmate,
  stalemate,
  threefoldRepetition,
  fiftyMoveRule,
  insufficientMaterial,
  resignation,
}

/// Winner of the game, if any.
enum GameWinner {
  human,
  computer,
  draw,
}

/// Outcome details for a finished game.
class ComputerGameResult {
  const ComputerGameResult({
    required this.outcome,
    required this.winner,
    required this.description,
  });

  final ComputerGameOutcome outcome;
  final GameWinner winner;
  final String description;
}

/// Snapshot of reader and book session state before starting a game,
/// ensuring exact restoration to the pre-game position/excursion on exit.
class SavedReaderContext {
  const SavedReaderContext({
    required this.sessionSnapshot,
    required this.activeLine,
  });

  final GameSessionSnapshot sessionSnapshot;
  final ActiveLine? activeLine;
}

/// Computes a normalized repetition key for [pos], incorporating board placement,
/// active color, castling rights, and legally capturable en-passant square.
String repetitionKeyFor(Position pos) {
  final parts = pos.fen.split(' ');
  final epAvailable = pos.epSquare != null &&
      pos.legalMoves.values.any((dests) => dests.squares.contains(pos.epSquare!));
  final ep = epAvailable ? parts[3] : '-';
  return '${parts[0]} ${parts[1]} ${parts[2]} $ep';
}

/// Complete immutable state of the computer opponent feature.
class ComputerOpponentState {
  const ComputerOpponentState({
    this.phase = ComputerGamePhase.idle,
    this.humanSide = Side.white,
    this.strength = ComputerStrengthPreset.casual,
    this.result,
    this.lastEngineMove,
    this.expectedPhysicalPlacement,
    this.startPosition = Chess.initial,
    this.history = const [],
    this.repetitionKeys = const {},
    this.searchGeneration = 0,
    this.savedReaderContext,
    this.errorMessage,
    this.isAwaitingPhysical = false,
  });

  final ComputerGamePhase phase;
  final Side humanSide;
  final ComputerStrengthPreset strength;
  final ComputerGameResult? result;
  final NormalMove? lastEngineMove;
  final String? expectedPhysicalPlacement;
  final Position startPosition;
  final List<NormalMove> history;
  final Map<String, int> repetitionKeys;
  final int searchGeneration;
  final SavedReaderContext? savedReaderContext;
  final String? errorMessage;
  final bool isAwaitingPhysical;

  bool get isGameActive =>
      phase == ComputerGamePhase.humanTurn ||
      phase == ComputerGamePhase.engineThinking ||
      phase == ComputerGamePhase.awaitingPhysicalMove ||
      phase == ComputerGamePhase.paused;

  bool get isHumanTurn => phase == ComputerGamePhase.humanTurn;

  bool get isThinking => phase == ComputerGamePhase.engineThinking;

  bool get isFinished => phase == ComputerGamePhase.finished;

  ComputerOpponentState copyWith({
    ComputerGamePhase? phase,
    Side? humanSide,
    ComputerStrengthPreset? strength,
    ComputerGameResult? result,
    bool clearResult = false,
    NormalMove? lastEngineMove,
    bool clearLastEngineMove = false,
    String? expectedPhysicalPlacement,
    bool clearExpectedPhysicalPlacement = false,
    Position? startPosition,
    List<NormalMove>? history,
    Map<String, int>? repetitionKeys,
    int? searchGeneration,
    SavedReaderContext? savedReaderContext,
    bool clearSavedReaderContext = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool? isAwaitingPhysical,
  }) {
    return ComputerOpponentState(
      phase: phase ?? this.phase,
      humanSide: humanSide ?? this.humanSide,
      strength: strength ?? this.strength,
      result: clearResult ? null : (result ?? this.result),
      lastEngineMove: clearLastEngineMove
          ? null
          : (lastEngineMove ?? this.lastEngineMove),
      expectedPhysicalPlacement: clearExpectedPhysicalPlacement
          ? null
          : (expectedPhysicalPlacement ?? this.expectedPhysicalPlacement),
      startPosition: startPosition ?? this.startPosition,
      history: history ?? this.history,
      repetitionKeys: repetitionKeys ?? this.repetitionKeys,
      searchGeneration: searchGeneration ?? this.searchGeneration,
      savedReaderContext: clearSavedReaderContext
          ? null
          : (savedReaderContext ?? this.savedReaderContext),
      errorMessage:
          clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      isAwaitingPhysical: isAwaitingPhysical ?? this.isAwaitingPhysical,
    );
  }
}
