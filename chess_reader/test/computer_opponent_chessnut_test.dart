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
    test('suppresses motor target commands throughout computer opponent game',
        () async {
      await connectAndSyncBoard();

      // Start computer game
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      fakeBoard.receivedCommands.clear();

      // 1. Human plays 1. e4
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));

      // Motor target commands (length 35, 0x42 0x21 with mode 1) must NOT be queued/sent
      final motorCommandsAfterE4 = fakeBoard.receivedCommands.where(
        (cmd) =>
            cmd.length == 35 &&
            cmd[0] == 0x42 &&
            cmd[1] == 0x21 &&
            cmd[34] == 1,
      );
      expect(motorCommandsAfterE4, isEmpty);

      // 2. Engine responds with e7e5
      fakeEngine.nextBestmove = 'e7e5';
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final motorCommandsAfterEngine = fakeBoard.receivedCommands.where(
        (cmd) =>
            cmd.length == 35 &&
            cmd[0] == 0x42 &&
            cmd[1] == 0x21 &&
            cmd[34] == 1,
      );
      expect(motorCommandsAfterEngine, isEmpty);

      // 3. User calls startOrResume manually during active game
      await container.read(chessnutControllerProvider.notifier).startOrResume();
      final motorCommandsAfterResume = fakeBoard.receivedCommands.where(
        (cmd) =>
            cmd.length == 35 &&
            cmd[0] == 0x42 &&
            cmd[1] == 0x21 &&
            cmd[34] == 1,
      );
      expect(motorCommandsAfterResume, isEmpty);
    });

    test('opponent move triggers LED guidance on board and enters awaitingPhysicalMove',
        () async {
      await connectAndSyncBoard();

      fakeEngine.nextBestmove = 'e7e5';
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      // Human plays 1. e4
      fakeBoard.receivedCommands.clear();
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));

      // Engine answers with e7e5
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final oppState = container.read(computerOpponentProvider);
      expect(oppState.phase, ComputerGamePhase.awaitingPhysicalMove);
      expect(oppState.isAwaitingPhysical, isTrue);

      // Board must receive LED command (length 34, 0x43 0x20)
      final ledCommands = fakeBoard.receivedCommands.where(
        (cmd) => cmd.length == 34 && cmd[0] == 0x43 && cmd[1] == 0x20,
      );
      expect(ledCommands, isNotEmpty);

      final latestLedCmd = ledCommands.last;
      final e7Sq = ChessnutCodec.squareToChessnutIndex(Square.e7);
      final e5Sq = ChessnutCodec.squareToChessnutIndex(Square.e5);

      final e7Byte = latestLedCmd[2 + e7Sq ~/ 2];
      final e7Color = (e7Sq % 2 == 0) ? (e7Byte & 0x0F) : ((e7Byte >> 4) & 0x0F);
      expect(e7Color, ChessnutConstants.ledGreen);

      final e5Byte = latestLedCmd[2 + e5Sq ~/ 2];
      final e5Color = (e5Sq % 2 == 0) ? (e5Byte & 0x0F) : ((e5Byte >> 4) & 0x0F);
      expect(e5Color, ChessnutConstants.ledGreen);
    });

    test('physical placement matching computer move enables human turn without double-playing',
        () async {
      await connectAndSyncBoard();

      fakeEngine.nextBestmove = 'e7e5';
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      // Human plays 1. e4
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.awaitingPhysicalMove);

      final revBeforePhysical = container.read(gameSessionProvider).revision;
      final expectedPlacement =
          container.read(computerOpponentProvider).expectedPhysicalPlacement!;

      // Simulate human moving physical pieces on the board to match the computer move
      fakeBoard.simulatePhysicalMove(expectedPlacement);
      await settle();

      // Phase transitions to humanTurn and isAwaitingPhysical is cleared
      final oppState = container.read(computerOpponentProvider);
      expect(oppState.phase, ComputerGamePhase.humanTurn);
      expect(oppState.isAwaitingPhysical, isFalse);

      // The move was already played in GameSession when computer made it,
      // so the session revision must NOT have incremented again.
      expect(container.read(gameSessionProvider).revision, revBeforePhysical);
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

    test('Play on Screen (skipPhysicalWaiting) clears LEDs and enables human turn',
        () async {
      await connectAndSyncBoard();

      fakeEngine.nextBestmove = 'e7e5';
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      // Human plays 1. e4
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.awaitingPhysicalMove);

      fakeBoard.receivedCommands.clear();

      // Human clicks "Play on Screen"
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
