import 'dart:typed_data';

import 'package:chess_reader/core/entitlements/pro_entitlement.dart';
import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/chessnut/codec/chessnut_codec.dart';
import 'package:chess_reader/features/chessnut/model/chessnut_constants.dart';
import 'package:chess_reader/features/chessnut/model/chessnut_state.dart';
import 'package:chess_reader/features/chessnut/state/chessnut_controller.dart';
import 'package:chess_reader/features/chessnut/transport/fake_chessnut_board.dart';
import 'package:chess_reader/features/computer_opponent/domain/computer_opponent_models.dart';
import 'package:chess_reader/features/computer_opponent/state/computer_opponent_provider.dart';
import 'package:chess_reader/features/engine/state/analysis_provider.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_uci_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late FakeChessnutBoard fakeBoard;
  late FakeUciEngine fakeEngine;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    fakeBoard = FakeChessnutBoard();
    fakeEngine = FakeUciEngine();

    container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        proEntitlementProvider.overrideWithValue(true),
        chessnutTransportProvider.overrideWithValue(fakeBoard),
        opponentEngineFactoryProvider.overrideWithValue(() => fakeEngine),
        analysisEngineFactoryProvider.overrideWithValue(() => FakeUciEngine()),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 400));

  Future<void> connectAndSyncBoard() async {
    final controller = container.read(chessnutControllerProvider.notifier);
    await controller.startScan();
    await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
    // Board starts with startpos placement, matches app startpos
    fakeBoard.simulatePhysicalMove(
      ChessnutCodec.extractPlacement(Chess.initial.fen),
    );
    await settle();
    expect(container.read(chessnutControllerProvider).syncState,
        ChessnutSyncState.synchronized);
  }

  group('Chessnut Move integration with Computer Opponent (Phase 7d)', () {
    test(
        'human and computer moves both drive the physical board via motor '
        'target commands, not LEDs', () async {
      await connectAndSyncBoard();
      // Drive completion manually (the pattern used throughout
      // chessnut_regression_test.dart for multi-move sequences): the fake
      // board's one-shot auto-echo doesn't model real hardware's continuous
      // FEN streaming, so a second app-origin move arriving while the first
      // is still in flight (here, the engine's near-instant reply) would
      // otherwise race the completion timer.
      fakeBoard.autoCompleteMotion = false;

      fakeEngine.nextBestmove = 'e7e5';
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      fakeBoard.receivedCommands.clear();

      bool isMotorCommand(Uint8List cmd) =>
          cmd.length == 35 && cmd[0] == 0x42 && cmd[1] == 0x21 && cmd[34] == 1;

      final afterE4 = ChessnutCodec.extractPlacement(
        Chess.initial.play(NormalMove.fromUci('e2e4')).fen,
      );
      final afterE5 = ChessnutCodec.extractPlacement(
        Chess.initial
            .play(NormalMove.fromUci('e2e4'))
            .play(NormalMove.fromUci('e7e5'))
            .fen,
      );

      // Human plays 1. e4 on screen: the physical board must follow.
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));
      // Let the engine's near-instant reply land and queue behind e4's
      // still-in-flight motion.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The physical board "arrives" at e4 (simulating the motor): this is
      // what lets the already-queued e5 target actually get sent.
      fakeBoard.simulatePhysicalMove(afterE4);
      await settle();

      final motorPlacements = fakeBoard.receivedCommands
          .where(isMotorCommand)
          .map((cmd) => ChessnutCodec.boardBytesToPlacement(cmd, 2))
          .toList();
      expect(motorPlacements, [afterE4, afterE5]);

      // No colored guidance LED (green) should ever be sent for the engine's
      // move now that the motor physically makes it.
      final greenLedCommands = fakeBoard.receivedCommands.where((cmd) {
        if (cmd.length != 34 || cmd[0] != 0x43 || cmd[1] != 0x20) {
          return false;
        }
        for (var i = 2; i < 34; i++) {
          final lo = cmd[i] & 0x0F;
          final hi = (cmd[i] >> 4) & 0x0F;
          if (lo == ChessnutConstants.ledGreen ||
              hi == ChessnutConstants.ledGreen) {
            return true;
          }
        }
        return false;
      });
      expect(greenLedCommands, isEmpty);
    });

    test(
        'computer opponent move automatically completes on the board and '
        'returns to human turn without double-playing', () async {
      await connectAndSyncBoard();
      fakeBoard.autoCompleteMotion = false;

      fakeEngine.nextBestmove = 'e7e5';
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      final afterE4 = ChessnutCodec.extractPlacement(
        Chess.initial.play(NormalMove.fromUci('e2e4')).fen,
      );
      final afterE5 = ChessnutCodec.extractPlacement(
        Chess.initial
            .play(NormalMove.fromUci('e2e4'))
            .play(NormalMove.fromUci('e7e5'))
            .fen,
      );

      // Human plays 1. e4
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));
      // Revision increments synchronously with the on-screen move, well
      // before the physical board even starts moving.
      final revAfterE4 = container.read(gameSessionProvider).revision;

      // Engine's reply (e7e5) lands and queues behind e4's in-flight motion.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The board "arrives" at e4: this both completes e4's motion and lets
      // the queued e5 target get sent to the motor.
      fakeBoard.simulatePhysicalMove(afterE4);
      await settle();
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.awaitingPhysicalMove);

      // The board now "arrives" at e5 on its own — matching real motor-driven
      // hardware, no legal-move re-matching is needed to advance the turn.
      fakeBoard.simulatePhysicalMove(afterE5);
      await settle();

      final oppState = container.read(computerOpponentProvider);
      expect(oppState.phase, ComputerGamePhase.humanTurn);
      expect(oppState.isAwaitingPhysical, isFalse);

      // The engine's move increments the revision exactly once; the board
      // settling on the commanded target must not play a second, duplicate
      // move on top of it.
      expect(container.read(gameSessionProvider).revision, revAfterE4 + 1);
      expect(container.read(gameSessionProvider).lastMove,
          NormalMove.fromUci('e7e5'));
      expect(container.read(gameSessionProvider).position.turn, Side.white);
    });

    test('blocks out-of-turn physical moves and physical takebacks during computer game',
        () async {
      await connectAndSyncBoard();

      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      // Human plays 1. e4
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));

      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.engineThinking);

      // While engine is thinking, simulate user making an out-of-turn physical move
      final d4Pos = Chess.initial.playUnchecked(NormalMove.fromUci('d2d4'));
      fakeBoard.simulatePhysicalMove(ChessnutCodec.extractPlacement(d4Pos.fen));
      await settle();

      // Must remain engineThinking and not accept d4 into GameSession
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.engineThinking);
      expect(container.read(gameSessionProvider).lastMove,
          NormalMove.fromUci('e2e4'));

      // Also verify physical takeback (restoring startpos) is blocked
      fakeBoard.simulatePhysicalMove(
        ChessnutCodec.extractPlacement(Chess.initial.fen),
      );
      await settle();

      // Must NOT undo the move
      expect(container.read(gameSessionProvider).lastMove,
          NormalMove.fromUci('e2e4'));
    });

    test('special moves diffPlacements produces correct green LED square sets',
        () {
      // 1. White Kingside Castling (e1g1)
      const preCastle =
          'r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R';
      const postCastle =
          'r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQ1RK1';
      final castleDiff = ChessnutCodec.diffPlacements(preCastle, postCastle);
      expect(castleDiff.length, 4);
      expect(
        castleDiff,
        containsAll([
          ChessnutCodec.squareToChessnutIndex(Square.e1),
          ChessnutCodec.squareToChessnutIndex(Square.g1),
          ChessnutCodec.squareToChessnutIndex(Square.f1),
          ChessnutCodec.squareToChessnutIndex(Square.h1),
        ]),
      );

      // 2. Black En Passant (exd6 e.p.)
      const preEp = 'rnbqkbnr/pppp1ppp/8/3Pp3/8/8/PPP1PPPP/RNBQKBNR';
      const postEp = 'rnbqkbnr/pppp1ppp/3P4/8/8/8/PPP1PPPP/RNBQKBNR';
      final epDiff = ChessnutCodec.diffPlacements(preEp, postEp);
      expect(epDiff.length, 3);
      expect(
        epDiff,
        containsAll([
          ChessnutCodec.squareToChessnutIndex(Square.d5),
          ChessnutCodec.squareToChessnutIndex(Square.e5),
          ChessnutCodec.squareToChessnutIndex(Square.d6),
        ]),
      );

      // 3. Pawn Promotion (e7e8q)
      const prePromo = '8/4P3/8/8/8/8/8/4K2k';
      const postPromo = '4Q3/8/8/8/8/8/8/4K2k';
      final promoDiff = ChessnutCodec.diffPlacements(prePromo, postPromo);
      expect(promoDiff.length, 2);
      expect(
        promoDiff,
        containsAll([
          ChessnutCodec.squareToChessnutIndex(Square.e7),
          ChessnutCodec.squareToChessnutIndex(Square.e8),
        ]),
      );
    });

    test(
        'Play on Screen (skipPhysicalWaiting) stops waiting on the motor and '
        'enables human turn', () async {
      await connectAndSyncBoard();

      fakeEngine.nextBestmove = 'e7e5';
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      // Human plays 1. e4
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));

      // Caught mid-motion: the engine's move has been sent to the motor but
      // hasn't stabilized on the target yet (< the 350ms completion window).
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.awaitingPhysicalMove);

      fakeBoard.receivedCommands.clear();

      // Human clicks "Play on Screen" instead of waiting for the board.
      opponent.skipPhysicalWaiting();

      final oppState = container.read(computerOpponentProvider);
      expect(oppState.phase, ComputerGamePhase.humanTurn);
      expect(oppState.isAwaitingPhysical, isFalse);

      // LEDs must be cleared
      final clearCommands = fakeBoard.receivedCommands.where(
        (cmd) => cmd.length == 34 && cmd[0] == 0x43 && cmd[1] == 0x20,
      );
      expect(clearCommands, isNotEmpty);
      final lastCmd = clearCommands.last;
      for (var i = 2; i < 34; i++) {
        expect(lastCmd[i], 0);
      }
    });

    test('returnToBook clears LEDs and restores reader state', () async {
      await connectAndSyncBoard();

      fakeEngine.nextBestmove = 'e7e5';
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.awaitingPhysicalMove);

      fakeBoard.receivedCommands.clear();

      // Return to book
      await opponent.returnToBook();

      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.idle);

      // Clear LEDs command sent
      final clearCommands = fakeBoard.receivedCommands.where(
        (cmd) => cmd.length == 34 && cmd[0] == 0x43 && cmd[1] == 0x20,
      );
      expect(clearCommands, isNotEmpty);
    });
  });
}
