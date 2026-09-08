import 'package:chess_reader/core/state/game_session.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GameSession prerequisite fixes', () {
    test('playMove guards on legal state and ignores moves on display-only board', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final session = container.read(gameSessionProvider.notifier);
      // Load an illegal FEN (display-only)
      session.loadFen('8/8/8/8/8/8/8/4K3 w - - 0 1');
      expect(container.read(gameSessionProvider).legal, isFalse);

      final revBefore = container.read(gameSessionProvider).revision;
      // Try playing e2e4 (legal in Chess.initial, but board is display-only)
      session.playMove(NormalMove.fromUci('e2e4'));

      expect(container.read(gameSessionProvider).legal, isFalse);
      expect(container.read(gameSessionProvider).revision, revBefore);
      expect(container.read(gameSessionProvider).lastMove, isNull);
    });

    test('reset origin differentiates user reset from book change reset', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final session = container.read(gameSessionProvider.notifier);
      session.reset(origin: PositionOrigin.app);
      expect(container.read(gameSessionProvider).origin, PositionOrigin.app);

      session.reset(origin: PositionOrigin.bookReset);
      expect(container.read(gameSessionProvider).origin, PositionOrigin.bookReset);
    });

    test('previousPosition snapshots undo position and physical undo preserves origin', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final session = container.read(gameSessionProvider.notifier);
      expect(session.previousPosition, isNull);

      session.playMove(NormalMove.fromUci('e2e4'));
      expect(session.previousPosition, isNotNull);
      expect(session.previousPosition!.$1.fen, Chess.initial.fen);
      expect(session.previousPosition!.$2, isNull);

      session.undo(origin: PositionOrigin.physical);
      expect(container.read(gameSessionProvider).origin, PositionOrigin.physical);
      expect(container.read(gameSessionProvider).position.fen, Chess.initial.fen);
    });

    test('applyTurnCorrection atomically applies corrected diagram and physical move', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final session = container.read(gameSessionProvider.notifier);
      session.loadFen('8/8/8/8/8/4k3/8/4K3 w - - 0 1', turnRecoverable: true);
      // Suppose diagram was white to move: 8/8/8/8/8/4k3/8/4K3 w - - 0 1
      // Corrected pre-move has black to move: 8/8/8/8/8/4k3/8/4K3 b - - 0 1
      final preMove = Chess.fromSetup(
        Setup.parseFen('8/8/8/8/8/4k3/8/4K3 b - - 0 1'),
        ignoreImpossibleCheck: true,
      );
      final move = NormalMove.fromUci('e3e4');

      session.applyTurnCorrection(correctedPreMove: preMove, move: move);

      final state = container.read(gameSessionProvider);
      expect(state.origin, PositionOrigin.physical);
      expect(state.canUndo, isTrue);
      expect(state.turnRecoverable, isFalse);
      expect(state.lastMove, move);

      // Undo restores the corrected diagram pre-move
      session.undo(origin: PositionOrigin.physical);
      final undone = container.read(gameSessionProvider);
      expect(undone.position.fen, preMove.fen);
      expect(undone.origin, PositionOrigin.physical);
    });

    test('turnRecoverable flag is set for diagram loads and cleared on playMove', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final session = container.read(gameSessionProvider.notifier);
      session.loadFen('rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1', turnRecoverable: true);
      expect(container.read(gameSessionProvider).turnRecoverable, isTrue);

      session.playMove(NormalMove.fromUci('e7e5'));
      expect(container.read(gameSessionProvider).turnRecoverable, isFalse);
    });
  });
}
