import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/chessnut/codec/chessnut_codec.dart';
import 'package:chess_reader/features/chessnut/model/chessnut_state.dart';
import 'package:chess_reader/features/chessnut/state/chessnut_controller.dart';
import 'package:chess_reader/features/chessnut/transport/fake_chessnut_board.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late FakeChessnutBoard board;
  late ChessnutController controller;
  late GameSession session;
  String placement(Position p) => ChessnutCodec.extractPlacement(p.fen);
  final initial = placement(Chess.initial);
  final e4 = Chess.initial.playUnchecked(NormalMove.fromUci('e2e4'));
  final d4 = Chess.initial.playUnchecked(NormalMove.fromUci('d2d4'));
  final nf3 = Chess.initial.playUnchecked(NormalMove.fromUci('g1f3'));
  int targets() =>
      board.receivedCommands.where((c) => c[0] == 0x42 && c.last == 1).length;
  // Completion now requires the reported placement to stay stable for the
  // completion window (no single-packet completion signal on real
  // hardware), so wait it out before treating the board as settled. Inside
  // testWidgets/checkWidgets that means pumping the fake clock rather than
  // a bare delayed future, which the test binding's fake clock won't
  // auto-advance.
  Future<void> ready([WidgetTester? tester]) async {
    await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
    await controller.startOrResume();
    if (tester != null) {
      await tester.pump(const Duration(milliseconds: 400));
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    board.receivedCommands.clear();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    board = FakeChessnutBoard();
    container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        chessnutTransportProvider.overrideWithValue(board),
      ],
    );
    controller = container.read(chessnutControllerProvider.notifier);
    session = container.read(gameSessionProvider.notifier);
  });
  var cleaned = false;
  setUp(() {
    cleaned = false;
  });
  void cleanup() {
    if (cleaned) return;
    cleaned = true;
    container.dispose();
    board.dispose();
  }

  tearDown(cleanup);
  void checkWidgets(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        cleanup();
      }
    });
  }

  checkWidgets('physical moves and takebacks never echo motor commands', (
    tester,
  ) async {
    await ready(tester);
    board.simulatePhysicalMove(placement(e4));
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(gameSessionProvider).position.fen, e4.fen);
    expect(targets(), 0);
    board.simulatePhysicalMove(initial);
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(gameSessionProvider).position.fen, Chess.initial.fen);
    expect(targets(), 0);
  });

  checkWidgets('repeated identical reports do not starve recognition', (
    tester,
  ) async {
    await ready(tester);
    for (var i = 0; i < 5; i++) {
      board.simulatePhysicalMove(placement(e4));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(container.read(gameSessionProvider).position.fen, e4.fen);
  });

  checkWidgets('pause discards in-flight completion and pending positions', (
    tester,
  ) async {
    await ready(tester);
    board.autoCompleteMotion = false;
    session.setPosition(e4);
    session.setPosition(d4);
    await controller.pause();
    board.simulatePhysicalMove(placement(e4));
    await tester.pump(const Duration(seconds: 2));
    expect(
      container.read(chessnutControllerProvider).syncState,
      ChessnutSyncState.paused,
    );
    expect(targets(), 1);
  });

  checkWidgets(
    'rapid navigation sends only latest pending target after completion',
    (tester) async {
      await ready(tester);
      board.autoCompleteMotion = false;
      session.setPosition(e4);
      session.setPosition(d4);
      session.setPosition(nf3);
      expect(targets(), 1);
      board.simulatePhysicalMove(placement(e4));
      await tester.pump(const Duration(milliseconds: 400));
      expect(targets(), 2);
      final last = board.receivedCommands.lastWhere((c) => c[0] == 0x42);
      expect(ChessnutCodec.boardBytesToPlacement(last, 2), placement(nf3));
    },
  );

  checkWidgets(
    'navigation back to in-flight target clears stale pending target',
    (tester) async {
      await ready(tester);
      board.autoCompleteMotion = false;
      session.setPosition(e4);
      session.setPosition(d4);
      session.setPosition(e4);
      board.simulatePhysicalMove(placement(e4));
      await tester.pump(const Duration(milliseconds: 400));
      expect(targets(), 1);
      expect(
        container.read(chessnutControllerProvider).syncState,
        ChessnutSyncState.synchronized,
      );
    },
  );

  checkWidgets('movement timeout pauses and clears queued target', (
    tester,
  ) async {
    await ready(tester);
    board.autoCompleteMotion = false;
    session.setPosition(e4);
    session.setPosition(d4);
    await tester.pump(const Duration(seconds: 31));
    expect(
      container.read(chessnutControllerProvider).syncState,
      ChessnutSyncState.paused,
    );
    expect(
      container.read(chessnutControllerProvider).lastError,
      contains('timed out'),
    );
    board.simulatePhysicalMove(placement(e4));
    expect(targets(), 1);
  });

  checkWidgets(
    'changed placement cancels an obsolete turn proposal immediately',
    (tester) async {
      await ready(tester);
      session.loadFen('8/8/8/8/8/4k3/8/4K3 w - - 0 1', turnRecoverable: true);
      // Let the diagram's own target reach and settle on the board before
      // simulating a subsequent physical move.
      await tester.pump(const Duration(milliseconds: 400));
      final opposite = Chess.fromSetup(
        Setup.parseFen('8/8/8/8/8/4k3/8/4K3 b - - 0 1'),
      );
      board.simulatePhysicalMove(
        placement(opposite.playUnchecked(NormalMove.fromUci('e3d4'))),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        container.read(chessnutControllerProvider).pendingTurnRecovery,
        isNotNull,
      );
      final before = container.read(gameSessionProvider).revision;
      board.simulatePhysicalMove(placement(opposite));
      controller.confirmTurnRecovery();
      expect(container.read(gameSessionProvider).revision, before);
      expect(
        container.read(chessnutControllerProvider).pendingTurnRecovery,
        isNull,
      );
    },
  );

  checkWidgets('grace timer refers only to the latest stable placement', (
    tester,
  ) async {
    await ready(tester);
    board.simulatePhysicalMove('8/8/8/8/8/8/8/8');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 1400));
    board.simulatePhysicalMove('8/8/8/8/8/8/8/4K3');
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      container.read(chessnutControllerProvider).syncState,
      ChessnutSyncState.synchronized,
    );
    await tester.pump(const Duration(milliseconds: 1800));
    expect(
      container.read(chessnutControllerProvider).mismatchedPlacement,
      '8/8/8/8/8/8/8/4K3',
    );
  });

  checkWidgets(
    'en passant intermediate stays out of mismatch until capture is removed',
    (tester) async {
      await ready(tester);
      session.loadFen('4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1');
      // Let the diagram's own target reach and settle on the board before
      // simulating a subsequent physical move.
      await tester.pump(const Duration(milliseconds: 400));
      board.simulatePhysicalMove('4k3/8/3P4/3p4/8/8/8/4K3');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 3));
      expect(
        container.read(chessnutControllerProvider).intermediateHint,
        contains('en passant'),
      );
      expect(
        container.read(chessnutControllerProvider).syncState,
        ChessnutSyncState.synchronized,
      );
      board.simulatePhysicalMove('4k3/8/3P4/8/8/8/8/4K3');
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        container.read(gameSessionProvider).lastMove,
        NormalMove.fromUci('e5d6'),
      );
    },
  );

  for (final reason in ['protocol', 'mtu', 'inventory', 'missing piece']) {
    test('every motion entry point rejects unverified $reason', () async {
      if (reason == 'protocol') board.motionProtocolVerified = false;
      if (reason == 'mtu') board.simulatedMtu = 23;
      if (reason == 'inventory') {
        board.respondToPieceStatusQuery = false;
        board.availablePieces = null;
      }
      if (reason == 'missing piece') board.setPieceAvailability('K', false);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      board.receivedCommands.clear();
      await controller.startOrResume();
      await controller.sendAppPositionToBoard();
      session.setDisplayFen('8/8/8/8/8/8/8/4K3 w - - 0 1');
      await controller.startOrResume();
      await controller.sendDiagramAnyway();
      expect(targets(), 0);
      expect(
        container.read(chessnutControllerProvider).syncState,
        ChessnutSyncState.paused,
      );
      expect(container.read(chessnutControllerProvider).lastError, isNotNull);
    });
  }

  test(
    'representable display-only diagrams require explicit override',
    () async {
      await ready();
      session.setDisplayFen('8/8/8/8/8/8/8/4K3 w - - 0 1');
      expect(targets(), 0);
      await controller.startOrResume();
      expect(targets(), 0);
      expect(
        container.read(chessnutControllerProvider).canSendDiagramAnyway,
        isTrue,
      );
      await controller.sendDiagramAnyway();
      expect(targets(), 1);
      expect(container.read(gameSessionProvider).legal, isFalse);
    },
  );

  test('old connection notifications are ignored after reconnect', () async {
    await ready();
    final stale = board.onFenReport!;
    final packetBoard = FakeChessnutBoard(initialPlacement: placement(e4));
    List<int>? packet;
    packetBoard.onFenReport = (value) => packet = value;
    packetBoard.emitCurrentFenNotification();
    await controller.disconnect();
    await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
    await controller.startOrResume();
    // Capture the real Uint8List without introducing transport delivery.
    packetBoard.onFenReport = stale;
    packetBoard.emitCurrentFenNotification();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(packet, isNotNull);
    expect(container.read(gameSessionProvider).position.fen, Chess.initial.fen);
    packetBoard.dispose();
  });

  checkWidgets('background cancels reconnect and requires resume', (
    tester,
  ) async {
    await ready(tester);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await board.disconnect(FakeChessnutBoard.fakeDeviceId);
    await tester.pump(const Duration(seconds: 40));
    expect(board.isConnected, isFalse);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(
      container.read(chessnutControllerProvider).syncState,
      ChessnutSyncState.paused,
    );
  });

  checkWidgets('scan timeout restores controls', (tester) async {
    await controller.startScan();
    await tester.pump(const Duration(seconds: 16));
    expect(
      container.read(chessnutControllerProvider).connectionState,
      ChessnutConnectionState.disconnected,
    );
    expect(board.isScanning, isFalse);
  });

  test(
    'Bluetooth power loss immediately invalidates synchronization',
    () async {
      await ready();
      board.simulateAvailability(AvailabilityState.poweredOff);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(chessnutControllerProvider).isConnected, isFalse);
      expect(
        container.read(chessnutControllerProvider).syncState,
        ChessnutSyncState.paused,
      );
      expect(
        container.read(chessnutControllerProvider).statusMessage,
        contains('powered off'),
      );
      board.simulatePhysicalMove(placement(e4));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        container.read(gameSessionProvider).position.fen,
        Chess.initial.fen,
      );
    },
  );

  test('session refuses turn correction during established play', () {
    final opposite = Chess.fromSetup(Setup.parseFen('$initial b KQkq - 0 1'));
    session.applyTurnCorrection(
      correctedPreMove: opposite,
      move: NormalMove.fromUci('e7e5'),
    );
    expect(container.read(gameSessionProvider).revision, 0);
  });

  test(
    'malformed placements fail inventory validation without range errors',
    () {
      for (final fen in [
        '9/8/8/8/8/8/8/8',
        '08/8/8/8/8/8/8/8',
        '8K/8/8/8/8/8/8/8',
        'x/8/8/8/8/8/8/8',
      ]) {
        expect(ChessnutCodec.validateInventory(fen).isValid, isFalse);
        expect(
          () => ChessnutCodec.placementToBoardBytes(fen),
          throwsFormatException,
        );
      }
    },
  );
}
