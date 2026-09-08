import 'dart:async';
import 'dart:typed_data';
import 'package:dartchess/dartchess.dart';
import 'package:universal_ble/universal_ble.dart';

import '../codec/chessnut_codec.dart';
import '../model/chessnut_constants.dart';
import 'chessnut_transport.dart';

/// In-memory simulated Chessnut Move board for testing, CI, and hardware-free simulation.
class FakeChessnutBoard implements ChessnutTransport {
  FakeChessnutBoard({
    String? initialPlacement,
    this.simulatedMtu = ChessnutConstants.desiredAndroidMtu,
    this.requiredServicesValid = true,
  }) : currentPlacement =
           initialPlacement ??
           ChessnutCodec.extractPlacement(Chess.initial.fen);

  @override
  bool motionProtocolVerified = true;
  @override
  Map<String, int>? availablePieces = {
    for (final piece in ChessnutCodec.nominalPieceOrder.toSet())
      piece: ChessnutCodec.nominalPieceOrder.where((p) => p == piece).length,
  };
  bool autoCompleteMotion = true;

  final _scanController = StreamController<BleDevice>.broadcast();
  final _availabilityController =
      StreamController<AvailabilityState>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();

  AvailabilityState availabilityState = AvailabilityState.poweredOn;
  int simulatedMtu;
  bool requiredServicesValid;
  bool isConnected = false;
  bool isScanning = false;

  String currentPlacement;
  int boardBatteryLevel = 85;
  bool boardCharging = false;
  final Map<int, int> pieceBatteries = {
    for (var i = 0; i < ChessnutConstants.totalNominalPieces; i++) i: 85,
  };

  void Function(Uint8List value)? onFenReport;
  void Function(Uint8List value)? onCommandResponse;

  final List<Uint8List> receivedCommands = [];

  static const String fakeDeviceId = 'fake-chessnut-move-001';
  static const String fakeDeviceName = 'Chessnut Move Test';

  @override
  Stream<BleDevice> get scanResults => _scanController.stream;

  @override
  Stream<AvailabilityState> get availabilityStream =>
      _availabilityController.stream;

  @override
  Future<AvailabilityState> getAvailabilityState() async => availabilityState;

  @override
  Future<bool> checkAndRequestPermissions() async => true;

  Timer? _scanTimeoutTimer;

  @override
  Future<void> startScan({Duration? timeout}) async {
    isScanning = true;
    _scanController.add(
      BleDevice(
        deviceId: fakeDeviceId,
        name: fakeDeviceName,
        rssi: -55,
        services: [
          ChessnutConstants.fenServiceUuid,
          ChessnutConstants.commandServiceUuid,
        ],
      ),
    );
    if (timeout != null) {
      _scanTimeoutTimer?.cancel();
      _scanTimeoutTimer = Timer(timeout, stopScan);
    }
  }

  @override
  Future<void> stopScan() async {
    isScanning = false;
    _scanTimeoutTimer?.cancel();
  }

  @override
  Future<void> connect(String deviceId, {Duration? timeout}) async {
    isConnected = true;
    _connectionController.add(true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    isConnected = false;
    _connectionController.add(false);
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    return simulatedMtu;
  }

  @override
  Future<bool> validateRequiredServices(String deviceId) async {
    return requiredServicesValid;
  }

  @override
  Future<void> subscribeToNotifications({
    required String deviceId,
    required void Function(Uint8List value) onFenReport,
    required void Function(Uint8List value) onCommandResponse,
  }) async {
    this.onFenReport = onFenReport;
    this.onCommandResponse = onCommandResponse;
  }

  @override
  Future<void> writeCommand(String deviceId, Uint8List data) async {
    receivedCommands.add(Uint8List.fromList(data));

    // Enable FEN reporting command: [0x21, 0x01, 0x00]
    if (data.length == 3 &&
        data[0] == 0x21 &&
        data[1] == 0x01 &&
        data[2] == 0x00) {
      emitCurrentFenNotification();
      return;
    }

    // Battery query command: [0x41, 0x01, 0x0C]
    if (data.length == 3 &&
        data[0] == 0x41 &&
        data[1] == 0x01 &&
        data[2] == 0x0C) {
      final response = Uint8List(5);
      response[0] = 0x41;
      response[1] = 0x03;
      response[2] = 0x0C;
      response[3] = boardCharging ? 1 : 0;
      response[4] = boardBatteryLevel;
      onCommandResponse?.call(response);
      return;
    }

    // Piece status query command: [0x41, 0x01, 0x0B]
    if (data.length == 3 &&
        data[0] == 0x41 &&
        data[1] == 0x01 &&
        data[2] == 0x0B) {
      final response = Uint8List(139);
      response[0] = 0x41;
      response[1] = 0x89;
      response[2] = 0x0B;
      for (var i = 0; i < ChessnutConstants.totalNominalPieces; i++) {
        final offset = 3 + i * 4;
        response[offset] = i + 1; // piece identity
        response[offset + 1] = 100; // x
        response[offset + 2] = 100; // y
        response[offset + 3] = pieceBatteries[i] ?? 85; // battery
      }
      onCommandResponse?.call(response);
      return;
    }

    // Target position command: [0x42, 0x21, ...32 bytes..., forceFlag]
    if (data.length == 35 && data[0] == 0x42 && data[1] == 0x21) {
      var isStop = true;
      for (var i = 2; i < 35; i++) {
        if (data[i] != 0) {
          isStop = false;
          break;
        }
      }

      if (!isStop) {
        // Update simulated physical board placement and emit notification
        if (autoCompleteMotion) {
          currentPlacement = ChessnutCodec.boardBytesToPlacement(data, 2);
          emitCurrentFenNotification();
        }
      }
      return;
    }
  }

  /// Emits a 38-byte FEN notification packet representing [currentPlacement].
  void emitCurrentFenNotification() {
    final packet = Uint8List(ChessnutConstants.fenReportLength);
    packet[0] = 0x21;
    packet[1] = 0x20;
    final boardBytes = ChessnutCodec.placementToBoardBytes(currentPlacement);
    packet.setRange(2, 34, boardBytes);
    onFenReport?.call(packet);
  }

  /// Simulates the user making a physical move to [newPlacement].
  void simulatePhysicalMove(String newPlacement) {
    currentPlacement = ChessnutCodec.extractPlacement(newPlacement);
    emitCurrentFenNotification();
  }

  /// Simulates White or Black castling intermediate state
  /// (King has moved to destination square, Rook is still unmoved).
  void simulateCastlingIntermediate({
    required Side side,
    required bool kingside,
  }) {
    final pos = Chess.fromSetup(
      Setup.parseFen('$currentPlacement w - - 0 1'),
      ignoreImpossibleCheck: true,
    );
    final Board testBoard;
    if (side == Side.white) {
      if (kingside) {
        // e1 to g1, rook remains on h1
        testBoard = pos.board
            .removePieceAt(Square.e1)
            .setPieceAt(
              Square.g1,
              const Piece(color: Side.white, role: Role.king),
            );
      } else {
        // e1 to c1, rook remains on a1
        testBoard = pos.board
            .removePieceAt(Square.e1)
            .setPieceAt(
              Square.c1,
              const Piece(color: Side.white, role: Role.king),
            );
      }
    } else {
      if (kingside) {
        // e8 to g8, rook remains on h8
        testBoard = pos.board
            .removePieceAt(Square.e8)
            .setPieceAt(
              Square.g8,
              const Piece(color: Side.black, role: Role.king),
            );
      } else {
        // e8 to c8, rook remains on a8
        testBoard = pos.board
            .removePieceAt(Square.e8)
            .setPieceAt(
              Square.c8,
              const Piece(color: Side.black, role: Role.king),
            );
      }
    }
    currentPlacement = ChessnutCodec.extractPlacement(testBoard.fen);
    emitCurrentFenNotification();
  }

  /// Simulates a temporary piece lift from a square (represented by empty square).
  void simulatePieceLift(Square square) {
    final boardBytes = ChessnutCodec.placementToBoardBytes(currentPlacement);
    final idx = ChessnutCodec.squareToChessnutIndex(square);
    final byteIndex = idx ~/ 2;
    if (idx % 2 == 0) {
      boardBytes[byteIndex] &= 0xF0;
    } else {
      boardBytes[byteIndex] &= 0x0F;
    }
    currentPlacement = ChessnutCodec.boardBytesToPlacement(boardBytes);
    emitCurrentFenNotification();
  }

  /// Simulates board battery update.
  void simulateBattery(int level, {bool charging = false}) {
    boardBatteryLevel = level;
    boardCharging = charging;
    final response = Uint8List(5);
    response[0] = 0x41;
    response[1] = 0x03;
    response[2] = 0x0C;
    response[3] = charging ? 1 : 0;
    response[4] = level;
    onCommandResponse?.call(response);
  }

  /// Simulates piece battery update.
  void simulatePieceBattery(int pieceIndex, int battery) {
    pieceBatteries[pieceIndex] = battery;
  }

  void simulateAvailability(AvailabilityState availability) {
    availabilityState = availability;
    _availabilityController.add(availability);
  }

  /// Simulates Bluetooth disconnection.
  void simulateDisconnect() {
    isConnected = false;
    _connectionController.add(false);
  }

  /// Simulates Bluetooth reconnection.
  void simulateReconnect() {
    isConnected = true;
    _connectionController.add(true);
  }

  @override
  Stream<bool> connectionStateStream(String deviceId) =>
      _connectionController.stream;

  @override
  void dispose() {
    _scanTimeoutTimer?.cancel();
    _scanController.close();
    _availabilityController.close();
    _connectionController.close();
  }
}
