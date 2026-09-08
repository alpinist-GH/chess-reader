import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/chessnut/codec/chessnut_codec.dart';
import 'package:chess_reader/features/chessnut/model/chessnut_state.dart';
import 'package:chess_reader/features/chessnut/state/chessnut_controller.dart';
import 'package:chess_reader/features/chessnut/transport/fake_chessnut_board.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late FakeChessnutBoard fakeBoard;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    fakeBoard = FakeChessnutBoard();
    container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        chessnutTransportProvider.overrideWithValue(fakeBoard),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  /// Advances real time past the FEN-stability window that now gates both
  /// outgoing move completion and incoming physical-move recognition, since
  /// real hardware has no distinct motion-completion notification.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 400));

  group('ChessnutController connection lifecycle', () {
    test('starts disconnected, scans and connects to fake board in paused state', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      expect(container.read(chessnutControllerProvider).connectionState,
          ChessnutConnectionState.disconnected);

      await controller.startScan();
      expect(container.read(chessnutControllerProvider).connectionState,
          ChessnutConnectionState.scanning);
      expect(controller.discoveredDevices.length, 1);

      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      final state = container.read(chessnutControllerProvider);
      expect(state.connectionState, ChessnutConnectionState.connected);
      expect(state.syncState, ChessnutSyncState.paused);
      expect(state.boardBattery, isNotNull);
      expect(state.boardBattery!.level, 85);
      expect(state.pieceStatuses, isNotNull);
      expect(state.pieceStatuses!.length, 34);
    });

    test('rejects peripheral when required GATT services are missing', () async {
      fakeBoard.requiredServicesValid = false;
      final controller = container.read(chessnutControllerProvider.notifier);

      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      final state = container.read(chessnutControllerProvider);
      expect(state.connectionState, ChessnutConnectionState.error);
      expect(state.lastError, contains('missing required Chessnut Move'));
    });

    test('auto-synchronizes without Start/Resume when the board already matches the app', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      expect(container.read(chessnutControllerProvider).syncState,
          ChessnutSyncState.paused);

      // A physical FEN report arrives (as real hardware streams continuously)
      // already showing the same placement as the app's current position.
      // No motion is required, so the Start/Resume gate should be skipped.
      fakeBoard.simulatePhysicalMove(
        ChessnutCodec.extractPlacement(Chess.initial.fen),
      );

      final state = container.read(chessnutControllerProvider);
      expect(state.syncState, ChessnutSyncState.synchronized);
      expect(fakeBoard.receivedCommands.any((cmd) => cmd.length == 35), isFalse);
    });

    test('stays paused, waiting for Start/Resume, when the board does not match the app', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);

      final e4Pos = Chess.initial.playUnchecked(NormalMove.fromUci('e2e4'));
      fakeBoard.simulatePhysicalMove(ChessnutCodec.extractPlacement(e4Pos.fen));

      final state = container.read(chessnutControllerProvider);
      expect(state.syncState, ChessnutSyncState.paused);
    });
  });

  group('ChessnutController App-to-Board synchronization', () {
    test('startOrResume sends current app position and enters aligning', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);

      fakeBoard.receivedCommands.clear();
      await controller.startOrResume();

      // Completion is confirmed only after the reported placement stays
      // stable for the completion window, not on the first matching packet
      // (real hardware has no distinct motion-completion notification).
      expect(container.read(chessnutControllerProvider).syncState,
          ChessnutSyncState.moving);

      await settle();

      final state = container.read(chessnutControllerProvider);
      expect(state.syncState, ChessnutSyncState.synchronized);
      expect(fakeBoard.receivedCommands.isNotEmpty, isTrue);

      // Verify target command bytes: starts with 0x42, 0x21
      final targetCmd = fakeBoard.receivedCommands.first;
      expect(targetCmd.length, 35);
      expect(targetCmd[0], 0x42);
      expect(targetCmd[1], 0x21);
      expect(targetCmd[34], 1); // non-force mode
    });

    test('deduplicates identical placement without sending redundant move commands', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      await controller.startOrResume();
      await settle();

      final countBefore = fakeBoard.receivedCommands.length;

      // Playing a null or side-to-move-only change with same placement field
      final session = container.read(gameSessionProvider.notifier);
      session.reset(origin: PositionOrigin.app);

      // Same startpos placement should not trigger new command
      expect(fakeBoard.receivedCommands.length, countBefore);
    });

    test('user stop immediately halts motion and pauses synchronization', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      await controller.startOrResume();

      fakeBoard.receivedCommands.clear();
      await controller.stop();

      final state = container.read(chessnutControllerProvider);
      expect(state.syncState, ChessnutSyncState.paused);
      expect(fakeBoard.receivedCommands.length, 2); // Stop command + clear LEDs command

      final stopCmd = fakeBoard.receivedCommands.first;
      expect(stopCmd[0], 0x42);
      expect(stopCmd[1], 0x21);
      expect(stopCmd[34], 0);

      // A stray physical report that still matches the (unmoved) app
      // position must not silently un-pause: Stop requires an explicit
      // Start/Resume, even though nothing would need to move.
      fakeBoard.simulatePhysicalMove(ChessnutCodec.extractPlacement(Chess.initial.fen));
      expect(container.read(chessnutControllerProvider).syncState,
          ChessnutSyncState.paused);
    });

    test('book reset pauses synchronization without moving physical pieces', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      await controller.startOrResume();
      await settle();

      final countBefore = fakeBoard.receivedCommands.length;
      final session = container.read(gameSessionProvider.notifier);

      // Trigger book change reset
      session.reset(origin: PositionOrigin.bookReset);

      final state = container.read(chessnutControllerProvider);
      expect(state.syncState, ChessnutSyncState.paused);
      expect(fakeBoard.receivedCommands.length, countBefore);

      // The physical board still shows the same (unmoved) placement the
      // reset landed on. A stray report confirming that must not silently
      // resume synchronization — book reset requires explicit Start/Resume.
      fakeBoard.simulatePhysicalMove(ChessnutCodec.extractPlacement(Chess.initial.fen));
      expect(container.read(chessnutControllerProvider).syncState,
          ChessnutSyncState.paused);
    });

    test('inventory limit check pauses when position exceeds max pieces', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);

      // Set position with 3 White Queens
      final session = container.read(gameSessionProvider.notifier);
      session.setDisplayFen('8/8/8/8/8/QQQ5/k7/4K3 w - - 0 1');

      await controller.startOrResume();

      final state = container.read(chessnutControllerProvider);
      expect(state.syncState, ChessnutSyncState.paused);
      expect(state.lastError, contains('2 White Queens'));
    });
  });

  group('ChessnutController Board-to-App physical move recognition', () {
    test('recognizes physical move after stability timer and plays it in session', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      await controller.startOrResume();
      await settle();

      expect(container.read(gameSessionProvider).position.turn, Side.white);

      // Board emits 1. e4 placement
      final e4Pos = Chess.initial.playUnchecked(NormalMove.fromUci('e2e4'));
      final e4Placement = ChessnutCodec.extractPlacement(e4Pos.fen);

      fakeBoard.simulatePhysicalMove(e4Placement);

      // Fast forward past stability duration (350ms)
      await settle();

      final sessionState = container.read(gameSessionProvider);
      expect(sessionState.origin, PositionOrigin.physical);
      expect(sessionState.lastMove, NormalMove.fromUci('e2e4'));
      expect(sessionState.position.turn, Side.black);
    });

    test('recognizes physical takeback and restores previous position via undo', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      await controller.startOrResume();
      await settle();

      // Play 1. e4 via screen/app
      final session = container.read(gameSessionProvider.notifier);
      session.playMove(NormalMove.fromUci('e2e4'));

      // Let the app's own e4 target reach and settle on the board before
      // the user physically moves anything, matching real hardware timing.
      await settle();

      // User physically returns pawn from e4 back to e2
      fakeBoard.simulatePhysicalMove(ChessnutCodec.extractPlacement(Chess.initial.fen));

      // Fast forward past stability duration
      await settle();

      final sessionState = container.read(gameSessionProvider);
      expect(sessionState.origin, PositionOrigin.physical);
      expect(sessionState.position.fen, Chess.initial.fen);
      expect(sessionState.lastMove, isNull);
    });

    test('intermediate castling state holds grace timer and shows hint', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      await controller.startOrResume();
      await settle();

      // Position where white can castle kingside (e.g. 1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5)
      Position pos = Chess.initial;
      pos = pos.playUnchecked(NormalMove.fromUci('e2e4'));
      pos = pos.playUnchecked(NormalMove.fromUci('e7e5'));
      pos = pos.playUnchecked(NormalMove.fromUci('g1f3'));
      pos = pos.playUnchecked(NormalMove.fromUci('b8c6'));
      pos = pos.playUnchecked(NormalMove.fromUci('f1c4'));
      pos = pos.playUnchecked(NormalMove.fromUci('f8c5'));

      container.read(gameSessionProvider.notifier).setPosition(pos);
      await settle();
      await controller.startOrResume();
      await settle();

      // Simulate King moved to g1 (rook still on h1)
      fakeBoard.simulateCastlingIntermediate(side: Side.white, kingside: true);

      await settle();

      final state = container.read(chessnutControllerProvider);
      expect(state.intermediateHint, contains('Complete castling'));
      expect(state.syncState, isNot(ChessnutSyncState.mismatch));
    });

    test('restricted turn recovery proposes confirmation on turn-uncertain diagram', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      await controller.startOrResume();
      await settle();

      // Quiet diagram loaded with turnRecoverable: true (White to move)
      // Placement: 8/8/8/8/8/4k3/8/4K3 w - - 0 1
      container.read(gameSessionProvider.notifier).loadFen(
        '8/8/8/8/8/4k3/8/4K3 w - - 0 1',
        turnRecoverable: true,
      );

      // Let the diagram's own target reach and settle on the board before
      // the physical move is simulated.
      await settle();

      // Black physically plays 1... Kd4 (or Ke4)
      final oppositeSetup = Setup.parseFen('8/8/8/8/8/4k3/8/4K3 b - - 0 1');
      final oppositePos = Chess.fromSetup(oppositeSetup, ignoreImpossibleCheck: true);
      final move = NormalMove.fromUci('e3d4');
      final playedPos = oppositePos.playUnchecked(move);

      fakeBoard.simulatePhysicalMove(ChessnutCodec.extractPlacement(playedPos.fen));

      await settle();

      final state = container.read(chessnutControllerProvider);
      expect(state.pendingTurnRecovery, isNotNull);
      expect(state.pendingTurnRecovery!.move, move);

      // User confirms turn recovery
      controller.confirmTurnRecovery();

      final sessionState = container.read(gameSessionProvider);
      expect(sessionState.origin, PositionOrigin.physical);
      expect(sessionState.lastMove, move);
      expect(sessionState.turnRecoverable, isFalse);

      // Physical undo restores corrected pre-move
      container.read(gameSessionProvider.notifier).undo(origin: PositionOrigin.physical);
      expect(container.read(gameSessionProvider).position.turn, Side.black);
    });

    test('mismatch after grace period triggers mismatch state and red LEDs', () async {
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      await controller.startOrResume();
      await settle();

      fakeBoard.receivedCommands.clear();

      // Put an arbitrary random placement on the board
      fakeBoard.simulatePhysicalMove('8/8/8/8/8/8/8/8');

      // Stability period finishes
      await settle();
      expect(container.read(chessnutControllerProvider).syncState,
          isNot(ChessnutSyncState.mismatch));

      // Fast forward past grace duration (1.75s)
      await Future<void>.delayed(const Duration(milliseconds: 1800));

      final state = container.read(chessnutControllerProvider);
      expect(state.syncState, ChessnutSyncState.mismatch);
      expect(state.mismatchedSquares.isNotEmpty, isTrue);

      // Board received red LED command (0x43, 0x20)
      final ledCmds = fakeBoard.receivedCommands.where((cmd) => cmd.length == 34 && cmd[0] == 0x43 && cmd[1] == 0x20);
      expect(ledCmds.isNotEmpty, isTrue);
    });
  });
}
