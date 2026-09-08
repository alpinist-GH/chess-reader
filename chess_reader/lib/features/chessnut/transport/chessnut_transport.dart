import 'dart:typed_data';
import 'package:universal_ble/universal_ble.dart';

/// Abstract BLE transport interface for communicating with a Chessnut Move board.
abstract class ChessnutTransport {
  /// True only after completion, interruption, stop encoding and complete packet
  /// transfers have been validated for this connection/firmware.
  bool get motionProtocolVerified;

  /// Currently verified available pieces, including off-board reserves.
  /// Null means unknown; battery coordinates alone do not establish presence.
  Map<String, int>? get availablePieces;

  /// Stream of discovered BLE devices during scan.
  Stream<BleDevice> get scanResults;

  /// Stream of Bluetooth hardware availability state (poweredOn, poweredOff, unauthorized, unsupported).
  Stream<AvailabilityState> get availabilityStream;

  /// Retrieves current Bluetooth availability state.
  Future<AvailabilityState> getAvailabilityState();

  /// Checks and requests necessary OS-level Bluetooth permissions.
  Future<bool> checkAndRequestPermissions();

  /// Starts scanning for devices.
  Future<void> startScan({Duration? timeout});

  /// Stops an active scan.
  Future<void> stopScan();

  /// Connects to the specified [deviceId].
  Future<void> connect(String deviceId, {Duration? timeout});

  /// Disconnects from [deviceId].
  Future<void> disconnect(String deviceId);

  /// Requests ATT MTU (primarily for Android). Returns negotiated MTU.
  Future<int> requestMtu(String deviceId, int expectedMtu);

  /// Validates that the connected peripheral exports the required Chessnut services
  /// and characteristics.
  Future<bool> validateRequiredServices(String deviceId);

  /// Subscribes to FEN notifications and command responses.
  Future<void> subscribeToNotifications({
    required String deviceId,
    required void Function(Uint8List value) onFenReport,
    required void Function(Uint8List value) onCommandResponse,
  });

  /// Writes a command packet to the command write characteristic.
  Future<void> writeCommand(String deviceId, Uint8List data);

  /// Connection state stream for a given [deviceId].
  Stream<bool> connectionStateStream(String deviceId);

  /// Cleans up listeners and resources.
  void dispose();
}
