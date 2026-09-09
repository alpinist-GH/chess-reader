import 'dart:async';
import 'dart:math';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entitlements/pro_entitlement.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/state/game_session.dart';
import '../../chessnut/codec/chessnut_codec.dart';
import '../../chessnut/state/chessnut_controller.dart';
import '../../engine/data/engine_factory.dart';
import '../../engine/domain/uci_engine.dart';
import '../../engine/domain/uci_parser.dart';
import '../../engine/state/analysis_provider.dart';
import '../../reader/state/book_providers.dart';
import '../domain/computer_opponent_models.dart';

/// Factory provider for creating a UCI engine for computer opponent games.
/// Overridden in tests to provide fake or mock engines.
final opponentEngineFactoryProvider = Provider<UciEngine Function()>(
  (ref) => createEngine,
);

class ComputerOpponentNotifier extends Notifier<ComputerOpponentState>
    with WidgetsBindingObserver {
  UciEngine? _engine;
  StreamSubscription<String>? _engineSubscription;
  int _searchGeneration = 0;

  /// Whether a `go` has been sent whose `bestmove` has not arrived yet.
  bool _searchInFlight = false;

  /// Number of `bestmove` replies still owed by searches we told the engine to
  /// stop. A stopped search still answers, and that answer must be swallowed:
  /// otherwise a resumed game would play the reply to the previous `go` and
  /// then treat the reply to the current one as an out-of-turn move.
  int _bestmovesToDiscard = 0;
  EngineCapabilities _capabilities = const EngineCapabilities();

  @override
  ComputerOpponentState build() {
    WidgetsBinding.instance.addObserver(this);

    ref.listen<GameSessionState>(gameSessionProvider, (previous, next) {
      _onSessionChanged(previous, next);
    });

    ref.listen<bool>(proEntitlementProvider, (previous, next) {
      if (previous == true && !next && state.isGameActive) {
        pauseGame();
      }
    });

    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _disposeEngine();
    });

    return const ComputerOpponentState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (this.state.isGameActive) {
        pauseGame();
      }
    }
  }

  /// Starts a game vs computer.
  ///
  /// Requires Pro entitlement. Preserves the current reader position/context
  /// so [returnToBook] can restore it completely.
  Future<bool> startGame({
    Side? chosenSide,
    ComputerStrengthPreset strength = ComputerStrengthPreset.casual,
    Position? startFrom,
    bool swapColors = false,
  }) async {
    final isPro = ref.read(proEntitlementProvider);
    if (!isPro) {
      state = state.copyWith(
        phase: ComputerGamePhase.error,
        errorMessage: 'Play vs Computer requires Pro entitlement.',
      );
      return false;
    }

    final currentSession = ref.read(gameSessionProvider);
    final startPos = startFrom ?? (currentSession.legal ? currentSession.position : Chess.initial);

    // Reject starting terminal positions.
    if (startPos.isCheckmate || startPos.isStalemate || startPos.isInsufficientMaterial) {
      state = state.copyWith(
        phase: ComputerGamePhase.error,
        errorMessage: 'Cannot start a game from a finished board position.',
      );
      return false;
    }

    // Capture reader context before mutating session. A rematch or a fresh
    // game started while the previous one is still on the board must keep the
    // context captured before the *first* game, otherwise `returnToBook` would
    // restore the game position instead of the book.
    final readerContext = state.savedReaderContext ??
        SavedReaderContext(
          sessionSnapshot:
              ref.read(gameSessionProvider.notifier).captureSnapshot(),
          activeLine: ref.read(activeLineProvider),
        );

    // Exclusive engine ownership: pause analysis engine completely.
    await ref.read(analysisProvider.notifier).pauseForOpponent();

    // Determine player side.
    Side resolvedHumanSide;
    if (chosenSide != null) {
      resolvedHumanSide = swapColors ? chosenSide.opposite : chosenSide;
    } else {
      resolvedHumanSide = Random().nextBool() ? Side.white : Side.black;
    }

    // Set position in session.
    ref.read(gameSessionProvider.notifier).setPosition(
          startPos,
          origin: PositionOrigin.app,
        );

    final startRepetitionKey = repetitionKeyFor(startPos);

    state = ComputerOpponentState(
      phase: ComputerGamePhase.setup,
      humanSide: resolvedHumanSide,
      strength: strength,
      startPosition: startPos,
      history: const [],
      repetitionKeys: {startRepetitionKey: 1},
      searchGeneration: ++_searchGeneration,
      savedReaderContext: readerContext,
    );

    // Initialize opponent engine.
    try {
      await _ensureEngineStarted(strength);
    } catch (e) {
      state = state.copyWith(
        phase: ComputerGamePhase.error,
        errorMessage: 'Failed to start chess engine: $e',
      );
      return false;
    }

    // If human is to move, await human turn; otherwise begin engine search.
    if (startPos.turn == resolvedHumanSide) {
      state = state.copyWith(phase: ComputerGamePhase.humanTurn);
    } else {
      state = state.copyWith(phase: ComputerGamePhase.engineThinking);
      _triggerEngineSearch();
    }

    return true;
  }

  Future<void> _ensureEngineStarted(ComputerStrengthPreset strength) async {
    await _disposeEngine();

    final factory = ref.read(opponentEngineFactoryProvider);
    final engine = factory();
    _engine = engine;

    final startupLines = <String>[];
    final uciCompleter = Completer<void>();

    _engineSubscription = engine.lines.listen((line) {
      startupLines.add(line);
      _onEngineLine(line);
      if (line == 'uciok' && !uciCompleter.isCompleted) {
        uciCompleter.complete();
      }
    });

    await engine.start();

    // Give engine up to 3 seconds for uciok handshake.
    try {
      await uciCompleter.future.timeout(const Duration(seconds: 3));
    } catch (_) {}

    _capabilities = parseEngineCapabilities(startupLines);

    final threads = min(ref.read(settingsProvider).engineThreads, 2);
    engine.send('setoption name Threads value $threads');
    engine.send('setoption name Hash value 32');

    _applyStrengthOptions(strength);
    engine.send('isready');
  }

  void _applyStrengthOptions(ComputerStrengthPreset strength) {
    final engine = _engine;
    if (engine == null) return;

    if (_capabilities.supportsLimitStrength) {
      if (strength == ComputerStrengthPreset.fullStrength) {
        engine.send('setoption name UCI_LimitStrength value false');
      } else {
        engine.send('setoption name UCI_LimitStrength value true');
        final targetElo = strength.elo ?? 1350;
        final clampedElo = targetElo.clamp(_capabilities.minElo, _capabilities.maxElo);
        engine.send('setoption name UCI_Elo value $clampedElo');
      }
    }
  }

  void _triggerEngineSearch() {
    final engine = _engine;
    if (engine == null || !state.isThinking) return;

    final gen = ++_searchGeneration;
    _searchInFlight = true;
    state = state.copyWith(searchGeneration: gen);

    // Format position history for engine.
    final historyUci = _engineMoveList().join(' ');
    final movesPart = historyUci.isEmpty ? '' : ' moves $historyUci';

    if (state.startPosition == Chess.initial) {
      engine.send('position startpos$movesPart');
    } else {
      engine.send('position fen ${state.startPosition.fen}$movesPart');
    }

    // Bounded search time per move (1000ms).
    engine.send('go movetime 1000');
  }

  /// The game's move list in the UCI form the engine understands, replaying
  /// from [ComputerOpponentState.startPosition] so castling is normalized.
  List<String> _engineMoveList() {
    var pos = state.startPosition;
    final moves = <String>[];
    for (final move in state.history) {
      moves.add(uciForEngine(pos, move));
      if (!pos.isLegal(move)) break;
      pos = pos.playUnchecked(move);
    }
    return moves;
  }

  void _onEngineLine(String line) {
    final bestmove = parseBestmove(line);
    if (bestmove != null) {
      _handleBestmove(bestmove);
    }
  }

  void _handleBestmove(String uciMove) {
    // Swallow the answers owed by searches we already stopped. This must not
    // touch `_searchInFlight`: a new search may already be running, and its
    // own answer is still to come.
    if (_bestmovesToDiscard > 0) {
      _bestmovesToDiscard--;
      return;
    }
    // A reply with no search outstanding (engine chatter, duplicate) is not
    // an answer to anything we asked and must never reach the board.
    if (!_searchInFlight) return;
    _searchInFlight = false;

    if (state.phase != ComputerGamePhase.engineThinking) return;

    final session = ref.read(gameSessionProvider);
    final pos = session.position;

    final move = Move.parse(uciMove);
    if (move is! NormalMove || !pos.isLegal(move)) {
      // Malformed or illegal reply: fallback to legal random move if available, or error.
      final fallbackMoves = <NormalMove>[];
      pos.legalMoves.forEach((from, dests) {
        final isPawn = pos.board.pieceAt(from)?.role == Role.pawn;
        for (final to in dests.squares) {
          // A pawn reaching the back rank must name a promotion piece,
          // otherwise `playUnchecked` would leave a pawn there.
          final promotion =
              isPawn && SquareSet.backranks.has(to) ? Role.queen : null;
          fallbackMoves.add(
            NormalMove(from: from, to: to, promotion: promotion),
          );
        }
      });
      if (fallbackMoves.isEmpty) {
        _adjudicateResult(pos);
        return;
      }
      _applyEngineMove(fallbackMoves.first);
      return;
    }

    _applyEngineMove(move);
  }

  void _applyEngineMove(NormalMove move) {
    final session = ref.read(gameSessionProvider);
    final prePlacement = ChessnutCodec.extractPlacement(session.fen);

    // Commit engine move to GameSession.
    ref.read(gameSessionProvider.notifier).playMove(
          move,
          origin: PositionOrigin.computer,
        );

    final newSession = ref.read(gameSessionProvider);
    final postPlacement = ChessnutCodec.extractPlacement(newSession.fen);

    final updatedHistory = List<NormalMove>.from(state.history)..add(move);
    final repKey = repetitionKeyFor(newSession.position);
    final updatedRep = Map<String, int>.from(state.repetitionKeys);
    updatedRep[repKey] = (updatedRep[repKey] ?? 0) + 1;

    state = state.copyWith(
      lastEngineMove: move,
      expectedPhysicalPlacement: postPlacement,
      history: updatedHistory,
      repetitionKeys: updatedRep,
    );

    // Check if move concluded the game.
    if (_adjudicateResult(newSession.position)) {
      return;
    }

    // If Chessnut board is connected, guide move via LEDs and await physical placement.
    final chessnut = ref.read(chessnutControllerProvider);
    if (chessnut.isConnected) {
      state = state.copyWith(
        phase: ComputerGamePhase.awaitingPhysicalMove,
        isAwaitingPhysical: true,
      );
      ref.read(chessnutControllerProvider.notifier).guideOpponentMove(
            prePlacement,
            postPlacement,
          );
    } else {
      state = state.copyWith(
        phase: ComputerGamePhase.humanTurn,
        isAwaitingPhysical: false,
      );
    }
  }

  /// Observes user moves from GameSession.
  void _onSessionChanged(GameSessionState? previous, GameSessionState next) {
    if (previous == null || previous.revision == next.revision) return;
    if (!state.isGameActive) return;

    // Ignore moves committed by the computer engine itself.
    if (next.origin == PositionOrigin.computer) return;

    // A human move occurred.
    if (state.phase == ComputerGamePhase.humanTurn) {
      final lastMove = next.lastMove;
      if (lastMove == null) return;

      // Only a single legal move played by the human from the position we were
      // waiting on counts. Anything else — a jump to another position, a
      // takeback, a restored snapshot — happens to carry a `lastMove` too, and
      // must not be appended to the game or hand the turn to the engine.
      final before = previous.position;
      if (!previous.legal ||
          !next.canUndo ||
          before.turn != state.humanSide ||
          !before.isLegal(lastMove) ||
          before.playUnchecked(lastMove) != next.position) {
        return;
      }

      final updatedHistory = List<NormalMove>.from(state.history)..add(lastMove);
      final repKey = repetitionKeyFor(next.position);
      final updatedRep = Map<String, int>.from(state.repetitionKeys);
      updatedRep[repKey] = (updatedRep[repKey] ?? 0) + 1;

      state = state.copyWith(
        history: updatedHistory,
        repetitionKeys: updatedRep,
      );

      // Check if move ended the game.
      if (_adjudicateResult(next.position)) {
        return;
      }

      // Transition to engine thinking.
      state = state.copyWith(phase: ComputerGamePhase.engineThinking);
      _triggerEngineSearch();
    }
  }

  /// Evaluates checkmate, stalemate, repetition, and 50-move thresholds.
  bool _adjudicateResult(Position pos) {
    // 1. Checkmate takes precedence.
    if (pos.isCheckmate) {
      final winner = pos.turn == state.humanSide ? GameWinner.computer : GameWinner.human;
      final desc = winner == GameWinner.human
          ? 'Checkmate — You won!'
          : 'Checkmate — Computer won!';
      _finishGame(ComputerGameOutcome.checkmate, winner, desc);
      return true;
    }

    // 2. Stalemate.
    if (pos.isStalemate) {
      _finishGame(ComputerGameOutcome.stalemate, GameWinner.draw, 'Draw — Stalemate.');
      return true;
    }

    // 3. Insufficient material.
    if (pos.isInsufficientMaterial) {
      _finishGame(
        ComputerGameOutcome.insufficientMaterial,
        GameWinner.draw,
        'Draw — Insufficient material.',
      );
      return true;
    }

    // 4. Threefold repetition.
    final key = repetitionKeyFor(pos);
    if ((state.repetitionKeys[key] ?? 0) >= 3) {
      _finishGame(
        ComputerGameOutcome.threefoldRepetition,
        GameWinner.draw,
        'Draw — Threefold repetition.',
      );
      return true;
    }

    // 5. Fifty-move rule.
    if (pos.halfmoves >= 100) {
      _finishGame(
        ComputerGameOutcome.fiftyMoveRule,
        GameWinner.draw,
        'Draw — 50-move rule threshold reached.',
      );
      return true;
    }

    return false;
  }

  void _finishGame(ComputerGameOutcome outcome, GameWinner winner, String description) {
    state = state.copyWith(
      phase: ComputerGamePhase.finished,
      result: ComputerGameResult(
        outcome: outcome,
        winner: winner,
        description: description,
      ),
      isAwaitingPhysical: false,
    );
    _cancelInFlightSearch();
  }

  /// Called by ChessnutController when physical placement matches the computer's move.
  void onPhysicalMoveMatched() {
    if (state.phase != ComputerGamePhase.awaitingPhysicalMove) return;

    state = state.copyWith(
      phase: ComputerGamePhase.humanTurn,
      isAwaitingPhysical: false,
    );
  }

  /// User action: continue play on-screen without moving physical pieces.
  void skipPhysicalWaiting() {
    if (state.phase == ComputerGamePhase.awaitingPhysicalMove) {
      ref.read(chessnutControllerProvider.notifier).clearLeds();
      state = state.copyWith(
        phase: ComputerGamePhase.humanTurn,
        isAwaitingPhysical: false,
      );
    }
  }

  /// User action: Resign the game.
  Future<void> resign() async {
    if (!state.isGameActive) return;
    _cancelInFlightSearch();
    state = state.copyWith(
      phase: ComputerGamePhase.finished,
      result: const ComputerGameResult(
        outcome: ComputerGameOutcome.resignation,
        winner: GameWinner.computer,
        description: 'Computer won by resignation.',
      ),
      isAwaitingPhysical: false,
    );
    ref.read(chessnutControllerProvider.notifier).clearLeds();
  }

  /// User action: Restart game from initial starting point.
  Future<void> rematch({bool swapColors = false}) async {
    _cancelInFlightSearch();
    ref.read(chessnutControllerProvider.notifier).clearLeds();

    final chosenSide = swapColors ? state.humanSide.opposite : state.humanSide;
    await startGame(
      chosenSide: chosenSide,
      strength: state.strength,
      startFrom: state.startPosition,
    );
  }

  /// User action: Return to book / exit game, restoring reader state.
  Future<void> returnToBook() async {
    final saved = state.savedReaderContext;

    // Drop out of the game *before* touching the reader: `activeLineProvider`
    // and the board refuse changes while the game owns the board, so restoring
    // with a still-active phase would silently do nothing.
    await _endGame();

    if (saved != null) {
      // Restore GameSession.
      ref.read(gameSessionProvider.notifier).restoreSnapshot(
            saved.sessionSnapshot,
            origin: PositionOrigin.app,
          );

      // Restore the selected book line. The board already came back from the
      // snapshot above, so this only puts the move-strip selection back.
      ref.read(activeLineProvider.notifier).restore(saved.activeLine);
    }

    // Resume analysis engine if it was active before game.
    await ref.read(analysisProvider.notifier).resumeFromOpponent();
  }

  /// Ends the game without restoring the reader context, for when the book
  /// being read is closing or changing and the saved position no longer
  /// exists. Synchronous so the caller's own reset isn't raced by ours.
  void abandonGame() {
    if (state.phase == ComputerGamePhase.idle) return;
    unawaited(_endGame());
    unawaited(ref.read(analysisProvider.notifier).resumeFromOpponent());
  }

  /// Tears down engine, LEDs and game state, returning to [ComputerGamePhase.idle].
  /// The state reset is synchronous; only the engine teardown is awaited.
  Future<void> _endGame() {
    ref.read(chessnutControllerProvider.notifier).clearLeds();
    state = const ComputerOpponentState();
    return _disposeEngine();
  }

  /// User action: Retry engine startup after failure.
  Future<void> retryEngine() async {
    if (state.phase != ComputerGamePhase.error) return;
    if (state.savedReaderContext == null) {
      // The failure happened before a game was ever set up (e.g. the
      // entitlement check): there is nothing to retry, just clear the banner.
      state = const ComputerOpponentState();
      return;
    }

    state = state.copyWith(clearErrorMessage: true);
    try {
      await _ensureEngineStarted(state.strength);
    } catch (e) {
      state = state.copyWith(
        phase: ComputerGamePhase.error,
        errorMessage: 'Failed to start chess engine: $e',
      );
      return;
    }

    final session = ref.read(gameSessionProvider);
    if (session.position.turn == state.humanSide) {
      state = state.copyWith(phase: ComputerGamePhase.humanTurn);
    } else {
      state = state.copyWith(phase: ComputerGamePhase.engineThinking);
      _triggerEngineSearch();
    }
  }

  /// Lifecycle: Pause game (e.g. app backgrounded or user paused).
  void pauseGame() {
    if (!state.isGameActive) return;
    _cancelInFlightSearch();
    state = state.copyWith(phase: ComputerGamePhase.paused);
  }

  /// Lifecycle: Resume paused game.
  void resumeGame() {
    if (state.phase != ComputerGamePhase.paused) return;

    final session = ref.read(gameSessionProvider);
    if (session.position.turn == state.humanSide) {
      state = state.copyWith(phase: ComputerGamePhase.humanTurn);
    } else {
      state = state.copyWith(phase: ComputerGamePhase.engineThinking);
      _triggerEngineSearch();
    }
  }

  void _cancelInFlightSearch() {
    ++_searchGeneration;
    if (_searchInFlight) {
      // The engine still owes one `bestmove` for the search being stopped.
      _bestmovesToDiscard++;
      _searchInFlight = false;
    }
    _engine?.send('stop');
  }

  Future<void> _disposeEngine() async {
    _cancelInFlightSearch();
    // The engine is going away, so nothing more is owed by it.
    _searchInFlight = false;
    _bestmovesToDiscard = 0;
    await _engineSubscription?.cancel();
    _engineSubscription = null;
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
  }
}

final computerOpponentProvider =
    NotifierProvider<ComputerOpponentNotifier, ComputerOpponentState>(
  ComputerOpponentNotifier.new,
);
