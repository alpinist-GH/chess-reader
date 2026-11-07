import 'dart:async';
import 'dart:typed_data';

import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/chessnut/codec/chessnut_codec.dart';
import 'package:chess_reader/features/chessnut/model/chessnut_board_model.dart';
import 'package:chess_reader/features/chessnut/model/chessnut_constants.dart';
import 'package:chess_reader/features/chessnut/model/chessnut_state.dart';
import 'package:chess_reader/features/chessnut/state/chessnut_controller.dart';
import 'package:chess_reader/features/chessnut/transport/auto_chessnut_transport.dart';
import 'package:chess_reader/features/chessnut/transport/evo_board_channel.dart';
import 'package:chess_reader/features/chessnut/transport/fake_chessnut_board.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

class EvoPort implements EvoBoardPort {
  EvoPort(this.present);
  final bool present;
  int connections = 0;
  int polls = 0;
  Uint8List? switches;
  final eventsController = StreamController<Map<Object?, Object?>>.broadcast();
  @override
  Stream<Map<Object?, Object?>> get events => eventsController.stream;
  @override
  Future<bool> isAvailable() async => present;
  @override
  Future<void> connect() async {
    connections++;
  }

  @override
  Future<void> disconnect() async {}
  @override
  Future<String?> getFen() async {
    polls++;
    return Chess.initial.fen;
  }

  @override
  Future<void> setLed(Uint8List on, Uint8List rgb) async {
    switches = on;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recognizes board names and service-only advertisements', () {
    for (final model in ChessnutBoardModel.values.where(
      (m) => m != ChessnutBoardModel.unknown,
    )) {
      expect(
        ChessnutBoardModel.fromAdvertisedName(model.displayName.toUpperCase()),
        model,
      );
    }
    expect(isChessnutAdvertisement(name: 'Watch'), isFalse);
    expect(isChessnutAdvertisement(rawName: 'Chessnut Air'), isTrue);
    expect(
      isChessnutAdvertisement(
        services: [
          ChessnutConstants.fenServiceUuid.toUpperCase().replaceAll('-', ''),
        ],
      ),
      isTrue,
    );
    expect(ChessnutBoardModel.air.canMovePieces, isFalse);
    expect(ChessnutBoardModel.move.canMovePieces, isTrue);
  });

  for (final model in [
    ChessnutBoardModel.air,
    ChessnutBoardModel.evo,
    ChessnutBoardModel.go,
  ]) {
    test(
      '${model.displayName}: manual alignment, legal moves and remembered identity',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final board = FakeChessnutBoard()..availablePieces = null;
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            chessnutTransportProvider.overrideWithValue(board),
          ],
        );
        addTearDown(() {
          container.dispose();
          board.dispose();
        });
        final controller = container.read(chessnutControllerProvider.notifier);
        await controller.connectToDevice(
          'manual-board',
          nameHint: model.displayName,
        );
        expect(controller.boardModel, model);
        expect(prefs.getString('chessnutDeviceName'), model.displayName);
        expect(
          board.receivedCommands.where((c) => c.length == 3 && c[2] == 0x0b),
          isEmpty,
        );
        final initial = ChessnutCodec.extractPlacement(Chess.initial.fen);
        final e4 = Chess.initial.playUnchecked(NormalMove.fromUci('e2e4'));
        board.simulatePhysicalMove(ChessnutCodec.extractPlacement(e4.fen));
        await controller.startOrResume();
        expect(
          container.read(chessnutControllerProvider).syncState,
          ChessnutSyncState.aligning,
        );
        expect(
          container.read(chessnutControllerProvider).mismatchedSquares,
          isNotEmpty,
        );
        expect(board.receivedCommands.any((c) => c.length == 35), isFalse);
        expect(
          board.receivedCommands.last[0],
          model.usesBitmapLeds ? 0x0a : 0x43,
        );
        board.simulatePhysicalMove(initial);
        expect(
          container.read(chessnutControllerProvider).syncState,
          ChessnutSyncState.synchronized,
        );
        board.simulatePhysicalMove(ChessnutCodec.extractPlacement(e4.fen));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(
          ChessnutCodec.extractPlacement(
            container.read(gameSessionProvider).fen,
          ),
          ChessnutCodec.extractPlacement(e4.fen),
        );
        container
            .read(gameSessionProvider.notifier)
            .playMove(NormalMove.fromUci('e7e5'));
        expect(
          container.read(chessnutControllerProvider).syncState,
          ChessnutSyncState.aligning,
        );
        expect(
          container.read(chessnutControllerProvider).mismatchedSquares,
          isNotEmpty,
        );
        container.read(gameSessionProvider.notifier).undo();
        expect(
          container.read(chessnutControllerProvider).syncState,
          ChessnutSyncState.synchronized,
        );
        expect(
          container.read(chessnutControllerProvider).mismatchedSquares,
          isEmpty,
        );
        container
            .read(gameSessionProvider.notifier)
            .playMove(NormalMove.fromUci('e7e5'));
        board.simulatePhysicalMove(
          ChessnutCodec.extractPlacement(
            container.read(gameSessionProvider).fen,
          ),
        );
        expect(
          container.read(chessnutControllerProvider).syncState,
          ChessnutSyncState.synchronized,
        );
        await controller.disconnect();
        await controller.connectToDevice('manual-board');
        expect(controller.boardModel, model);
        await controller.stop();
        expect(board.receivedCommands.any((c) => c.length == 35), isFalse);
      },
    );
  }

  test(
    'pausing a manual board clears its LEDs and Resume relights them',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final board = FakeChessnutBoard()..availablePieces = null;
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chessnutTransportProvider.overrideWithValue(board),
        ],
      );
      addTearDown(() {
        container.dispose();
        board.dispose();
      });
      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice('air', nameHint: 'Chessnut Air');
      final e4 = Chess.initial.playUnchecked(NormalMove.fromUci('e2e4'));
      board.simulatePhysicalMove(ChessnutCodec.extractPlacement(e4.fen));
      await controller.startOrResume();
      expect(
        container.read(chessnutControllerProvider).mismatchedSquares,
        isNotEmpty,
      );

      await controller.pause();
      expect(
        container.read(chessnutControllerProvider).mismatchedSquares,
        isEmpty,
      );
      expect(
        board.receivedCommands.last,
        ChessnutCodec.encodeClearLedsCommand(),
      );

      // No new report is needed: a manual board's last report remains true.
      await controller.startOrResume();
      final state = container.read(chessnutControllerProvider);
      expect(state.syncState, ChessnutSyncState.aligning);
      expect(state.mismatchedSquares, isNotEmpty);
    },
  );

  test('Evo native service discovery, FEN and LEDs bypass Bluetooth', () async {
    final ble = FakeChessnutBoard();
    final evo = EvoPort(true);
    final transport = AutoChessnutTransport(
      ble: ble,
      evo: evo,
      isAndroid: true,
    );
    addTearDown(() async {
      transport.dispose();
      await evo.eventsController.close();
    });
    final found = <BleDevice>[];
    final subscription = transport.scanResults.listen(found.add);
    addTearDown(subscription.cancel);
    expect(await transport.getAvailabilityState(), AvailabilityState.poweredOn);
    await transport.startScan();
    await Future<void>.delayed(Duration.zero);
    expect(found.single.deviceId, EvoBoardChannel.deviceId);
    expect(ble.isScanning, isFalse);
    await transport.connect(EvoBoardChannel.deviceId);
    final reports = <Uint8List>[];
    await transport.subscribeToNotifications(
      deviceId: EvoBoardChannel.deviceId,
      onFenReport: reports.add,
      onCommandResponse: (_) {},
    );
    expect(
      ChessnutCodec.decodeFenReport(reports.single),
      ChessnutCodec.extractPlacement(Chess.initial.fen),
    );
    await transport.writeCommand(
      EvoBoardChannel.deviceId,
      ChessnutCodec.encodeMismatchLedsCommand({0, 63}),
    );
    expect(evo.switches!.where((b) => b == 1).length, 2);
    await transport.disconnect(EvoBoardChannel.deviceId);
    expect(evo.connections, 1);
    expect(ble.receivedCommands, isEmpty);
  });

  test('Android without Evo service falls back to BLE', () async {
    final ble = FakeChessnutBoard();
    final evo = EvoPort(false);
    final transport = AutoChessnutTransport(
      ble: ble,
      evo: evo,
      isAndroid: true,
    );
    addTearDown(() async {
      transport.dispose();
      await evo.eventsController.close();
    });
    final result = transport.scanResults.first;
    await transport.startScan();
    expect((await result).deviceId, FakeChessnutBoard.fakeDeviceId);
    expect(ble.isScanning, isTrue);
    await transport.stopScan();
  });
}
