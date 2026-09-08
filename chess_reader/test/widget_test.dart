import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/board/board_panel.dart';
import 'package:chess_reader/features/chessnut/state/chessnut_controller.dart';
import 'package:chess_reader/features/chessnut/transport/fake_chessnut_board.dart';

void main() {
  group('GameSession', () {
    test('plays legal moves and rejects illegal ones', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final session = container.read(gameSessionProvider.notifier);

      session.playMove(NormalMove.fromUci('e2e4'));
      expect(
        container.read(gameSessionProvider).fen,
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
      );

      // Illegal: white pawn already moved, black to play.
      session.playMove(NormalMove.fromUci('e4e5'));
      expect(
        container.read(gameSessionProvider).fen,
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
      );

      session.playMove(NormalMove.fromUci('e7e5'));
      expect(container.read(gameSessionProvider).position.turn, Side.white);
    });

    test('undo and reset restore earlier positions', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final session = container.read(gameSessionProvider.notifier);

      session.playMove(NormalMove.fromUci('d2d4'));
      session.playMove(NormalMove.fromUci('g8f6'));
      session.undo();
      expect(
        container.read(gameSessionProvider).fen,
        'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1',
      );

      session.reset();
      expect(container.read(gameSessionProvider).fen, kInitialFEN);
      expect(container.read(gameSessionProvider).canUndo, isFalse);
    });
  });

  testWidgets('the board follows the game session', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // The board appears once a book is open; test the panel directly so the
    // board-follows-session wiring is covered without a real book file.
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        chessnutTransportProvider.overrideWith((ref) {
          final board = FakeChessnutBoard();
          ref.onDispose(board.dispose);
          return board;
        }),
      ],
      child: const MaterialApp(home: Scaffold(body: BoardPanel())),
    ));
    await tester.pump();

    expect(find.byType(Chessboard), findsOneWidget);

    final context = tester.element(find.byType(Chessboard));
    final container = ProviderScope.containerOf(context, listen: false);
    container.read(gameSessionProvider.notifier).playMove(
          NormalMove.fromUci('e2e4'),
        );
    await tester.pumpAndSettle();

    final controller =
        tester.widget<Chessboard>(find.byType(Chessboard)).controller;
    expect(
      controller.fen,
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
    );
  });
}
