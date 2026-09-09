import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'board_loader.dart';

/// Origin of a board position change.
enum PositionOrigin {
  /// App-initiated: user tapped board/move, entered FEN, book navigation,
  /// or clicked user Reset button.
  app,

  /// Physical board-initiated: move recognized from Chessnut hardware or
  /// physical takeback.
  physical,

  /// Book lifecycle change: opening/closing a book clears book reading state.
  /// Synchronization should pause rather than moving physical pieces.
  bookReset,

  /// Computer opponent move played during a game vs the engine.
  computer,
}

/// Snapshot of reader/session state captured before starting a computer game,
/// allowing complete restoration back to the exact reader position and excursion.
class GameSessionSnapshot {
  const GameSessionSnapshot({
    required this.state,
    required this.undoStack,
    required this.bookAnchor,
  });

  final GameSessionState state;
  final List<(Position, NormalMove?)> undoStack;
  final (Position, NormalMove?)? bookAnchor;
}

/// Immutable snapshot of the board state the app is currently showing.
class GameSessionState {
  const GameSessionState({
    required this.position,
    this.lastMove,
    this.canUndo = false,
    this.onBookLine = true,
    this.legal = true,
    this.displayFen,
    this.origin = PositionOrigin.app,
    this.revision = 0,
    this.turnRecoverable = false,
  });

  final Position position;
  final NormalMove? lastMove;
  final bool canUndo;

  /// False while the user is exploring own moves away from the position the
  /// book set (variation sandbox). "Back to book" snaps back.
  final bool onBookLine;

  /// True when [position] is a real, legal position. False for a display-only
  /// board (a detected diagram whose placement can't be validated): the pieces
  /// render, but there is no move generation or engine analysis.
  final bool legal;

  /// Set only for display-only boards; otherwise null (use the position's FEN).
  final String? displayFen;

  /// Origin of the most recent position change.
  final PositionOrigin origin;

  /// Monotonically increasing revision number, bumped on every position change.
  /// App-origin changes invalidate in-flight physical settling buffers.
  final int revision;

  /// True only for newly imported vision diagrams whose side-to-move was inferred
  /// or uncertain, allowing one-time physical turn recovery.
  final bool turnRecoverable;

  /// FEN to render and to share with links/engine (the raw detected placement
  /// when [legal] is false).
  String get fen => displayFen ?? position.fen;
}

/// Central authority over the current position. The board, the reader and
/// the engine all observe this provider; moves from any source (board taps,
/// clicked book moves, diagram anchors) funnel through it.
class GameSession extends Notifier<GameSessionState> {
  final List<(Position, NormalMove?)> _undoStack = [];

  /// The position the book most recently put on the board — the place
  /// "back to book" returns to.
  (Position, NormalMove?)? _bookAnchor;

  @override
  GameSessionState build() => const GameSessionState(position: Chess.initial);

  void playMove(Move move, {PositionOrigin origin = PositionOrigin.app}) {
    if (!state.legal) return;
    final pos = state.position;
    if (move is! NormalMove || !pos.isLegal(move)) return;
    _undoStack.add((pos, state.lastMove));
    state = GameSessionState(
      position: pos.playUnchecked(move),
      lastMove: move,
      canUndo: true,
      // Only an excursion when there is a book position to return to.
      onBookLine: _bookAnchor == null,
      origin: origin,
      revision: state.revision + 1,
      turnRecoverable: false,
    );
  }

  void undo({PositionOrigin origin = PositionOrigin.app}) {
    if (_undoStack.isEmpty) return;
    final (pos, lastMove) = _undoStack.removeLast();
    state = GameSessionState(
      position: pos,
      lastMove: lastMove,
      canUndo: _undoStack.isNotEmpty,
      onBookLine: _isBookPosition(pos),
      origin: origin,
      revision: state.revision + 1,
      turnRecoverable: false,
    );
  }

  void reset({PositionOrigin origin = PositionOrigin.app}) {
    _undoStack.clear();
    _bookAnchor = null;
    state = GameSessionState(
      position: Chess.initial,
      origin: origin,
      revision: state.revision + 1,
      turnRecoverable: false,
    );
  }

  /// Jumps to a book position (clicked move, diagram anchor, FEN input).
  /// Becomes the new anchor; the undo stack restarts from here.
  void setPosition(
    Position position, {
    NormalMove? lastMove,
    PositionOrigin origin = PositionOrigin.app,
    bool turnRecoverable = false,
  }) {
    _undoStack.clear();
    _bookAnchor = (position, lastMove);
    state = GameSessionState(
      position: position,
      lastMove: lastMove,
      origin: origin,
      revision: state.revision + 1,
      turnRecoverable: turnRecoverable,
    );
  }

  /// Loads a detected or pasted FEN, tolerating the defects common to vision
  /// diagrams (wrong side-to-move, "impossible" check). A placement that
  /// parses but can't be made legal is shown display-only so the board always
  /// reflects what was detected. Returns false only when [fen] is unparseable.
  bool loadFen(String fen, {bool turnRecoverable = false}) {
    final loaded = tryLoadFen(fen);
    if (loaded == null) return false;
    final position = loaded.position;
    if (position != null) {
      setPosition(position, turnRecoverable: turnRecoverable);
    } else {
      setDisplayFen(loaded.fen, turnRecoverable: turnRecoverable);
    }
    return true;
  }

  /// Shows an arbitrary (possibly illegal) placement without legal-move
  /// generation. Used as the fallback for diagrams that don't validate.
  void setDisplayFen(
    String fen, {
    PositionOrigin origin = PositionOrigin.app,
    bool turnRecoverable = false,
  }) {
    _undoStack.clear();
    _bookAnchor = null;
    state = GameSessionState(
      position: Chess.initial,
      legal: false,
      displayFen: fen,
      origin: origin,
      revision: state.revision + 1,
      turnRecoverable: turnRecoverable,
    );
  }

  /// Snaps back to the last book position after a sandbox excursion.
  void backToBook({PositionOrigin origin = PositionOrigin.app}) {
    final anchor = _bookAnchor;
    if (anchor == null) return;
    _undoStack.clear();
    state = GameSessionState(
      position: anchor.$1,
      lastMove: anchor.$2,
      origin: origin,
      revision: state.revision + 1,
      turnRecoverable: false,
    );
  }

  /// Snapshot of the previous position and move on the undo stack, if any.
  (Position, NormalMove?)? get previousPosition =>
      _undoStack.isEmpty ? null : _undoStack.last;

  /// Atomically corrects a diagram's turn and plays the user's first physical move.
  /// Undo returns to the corrected diagram pre-move position.
  void applyTurnCorrection({
    required Position correctedPreMove,
    required NormalMove move,
  }) {
    if (!state.legal ||
        !state.turnRecoverable ||
        correctedPreMove.board != state.position.board ||
        correctedPreMove.turn != state.position.turn.opposite ||
        !correctedPreMove.isLegal(move)) {
      return;
    }
    _bookAnchor = (correctedPreMove, null);
    _undoStack.clear();
    _undoStack.add((correctedPreMove, null));
    state = GameSessionState(
      position: correctedPreMove.playUnchecked(move),
      lastMove: move,
      canUndo: true,
      onBookLine: false,
      origin: PositionOrigin.physical,
      revision: state.revision + 1,
      turnRecoverable: false,
    );
  }

  /// Captures the full session state including undo stack and book anchor.
  GameSessionSnapshot captureSnapshot() {
    return GameSessionSnapshot(
      state: state,
      undoStack: List.of(_undoStack),
      bookAnchor: _bookAnchor,
    );
  }

  /// Restores a previously captured snapshot.
  void restoreSnapshot(
    GameSessionSnapshot snapshot, {
    PositionOrigin origin = PositionOrigin.app,
  }) {
    _undoStack
      ..clear()
      ..addAll(snapshot.undoStack);
    _bookAnchor = snapshot.bookAnchor;
    state = GameSessionState(
      position: snapshot.state.position,
      lastMove: snapshot.state.lastMove,
      canUndo: _undoStack.isNotEmpty,
      onBookLine: snapshot.state.onBookLine,
      legal: snapshot.state.legal,
      displayFen: snapshot.state.displayFen,
      origin: origin,
      revision: state.revision + 1,
      turnRecoverable: snapshot.state.turnRecoverable,
    );
  }

  bool _isBookPosition(Position pos) =>
      _bookAnchor == null || _bookAnchor!.$1.fen == pos.fen;
}

final gameSessionProvider = NotifierProvider<GameSession, GameSessionState>(
  GameSession.new,
);
