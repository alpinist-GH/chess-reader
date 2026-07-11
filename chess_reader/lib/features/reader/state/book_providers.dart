import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/persistence/library_store.dart';
import '../../../core/state/game_session.dart';
import '../../library/book_import.dart';
import '../data/page_moves_service.dart';
import '../domain/move_resolver.dart';
import 'reader_nav.dart';

/// Path of the currently opened book, or null when no book is open.
final openedBookProvider = NotifierProvider<OpenedBook, String?>(
  OpenedBook.new,
);

class OpenedBook extends Notifier<String?> {
  @override
  String? build() => null;

  Future<void> open(String path) async {
    // On iOS/Android/macOS this copies a freshly-picked book into stable app
    // storage and returns the local path (a recent-book reopen is already
    // local); on Windows/Linux it returns [path] unchanged.
    final localPath = await importBook(path);
    ref.read(libraryStoreProvider.notifier).recordOpened(localPath);
    _resetReadingState();
    state = localPath;
  }

  void close() {
    _resetReadingState();
    state = null;
  }

  /// Clears per-book transient state so switching books doesn't carry over the
  /// previous book's board, selected move, or scroll/jump intent.
  void _resetReadingState() {
    ref.read(activeLineProvider.notifier).clear();
    ref.read(currentPageProvider.notifier).set(1);
    ref.read(epubJumpProvider.notifier).consumed();
    ref.read(gameSessionProvider.notifier).reset();
  }
}

final pageMovesServiceProvider = Provider((ref) => PageMovesService());

/// The sequence of book moves the user is currently stepping through —
/// the resolved moves of one PDF page or EPUB chapter — plus the index of
/// the move shown on the board. Source-agnostic so the move strip and
/// prev/next work for both formats.
class ActiveLine {
  const ActiveLine({
    required this.moves,
    required this.index,
    required this.sourceKey,
  });

  final List<ResolvedMove> moves;

  /// Index into [moves] of the move currently shown.
  final int index;

  /// Identifies where the line came from (PDF page number, EPUB chapter
  /// index) so views can highlight the selected move.
  final Object sourceKey;

  bool get hasPrevious => index > 0;
  bool get hasNext => index < moves.length - 1;
}

class ActiveLineNotifier extends Notifier<ActiveLine?> {
  @override
  ActiveLine? build() => null;

  void clear() => state = null;

  /// User tapped a move in the book: show its resulting position.
  void select(List<ResolvedMove> moves, int index, Object sourceKey) {
    state = ActiveLine(moves: moves, index: index, sourceKey: sourceKey);
    _applyToBoard();
  }

  void next() {
    final line = state;
    if (line == null || !line.hasNext) return;
    state = ActiveLine(
        moves: line.moves, index: line.index + 1, sourceKey: line.sourceKey);
    _applyToBoard();
  }

  void previous() {
    final line = state;
    if (line == null || !line.hasPrevious) return;
    state = ActiveLine(
        moves: line.moves, index: line.index - 1, sourceKey: line.sourceKey);
    _applyToBoard();
  }

  void _applyToBoard() {
    final line = state;
    if (line == null) return;
    final resolved = line.moves[line.index];
    ref.read(gameSessionProvider.notifier).setPosition(
          resolved.positionAfter,
          lastMove: resolved.move is NormalMove
              ? resolved.move as NormalMove
              : null,
        );
  }
}

final activeLineProvider =
    NotifierProvider<ActiveLineNotifier, ActiveLine?>(ActiveLineNotifier.new);
