import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../model/chessnut_constants.dart';
import 'chessnut_transport.dart';

/// Concrete implementation of [ChessnutTransport] wrapping [UniversalBle].
class UniversalBleTransport implements ChessnutTransport {
  UniversalBleTransport() {
    _initCallbacks();
  }

  // No hardware captures establish these contracts yet. Keep motor commands
  // disabled until a verified implementation can supply them per connection.
  @override
  bool get motionProtocolVerified => false;
  @override
  Map<String, int>? get availablePieces => null;

  Timer? _scanTimer;
  bool _disposed = false;
  final _scanController = StreamController<BleDevice>.broadcast();
  final _connectionControllers = <String, StreamController<bool>>{};
  void Function(Uint8List value)? _fenReportCallback;
  void Function(Uint8List value)? _commandResponseCallback;
  String? _activeDeviceId;

  static bool _sameUuid(String a, String b) =>
      a.replaceAll('-', '').toLowerCase() ==
      b.replaceAll('-', '').toLowerCase();

  void _initCallbacks() {
    UniversalBle.onScanResult = (BleDevice device) {
      if (!_disposed) _scanController.add(device);
    };

    UniversalBle.onConnectionChange =
        (String deviceId, bool isConnected, String? error) {
          if (!_disposed && _connectionControllers.containsKey(deviceId)) {
            _connectionControllers[deviceId]?.add(isConnected);
          }
        };

    UniversalBle.onValueChange =
        (
          String deviceId,
          String characteristicId,
          Uint8List value,
          int? timestamp,
        ) {
          if (_disposed || deviceId != _activeDeviceId) return;

          if (_sameUuid(
            characteristicId,
            ChessnutConstants.fenCharacteristicUuid,
          )) {
            _fenReportCallback?.call(value);
          } else if (_sameUuid(
            characteristicId,
            ChessnutConstants.commandNotifyCharacteristicUuid,
          )) {
            _commandResponseCallback?.call(value);
          }
        };
  }

  @override
  Stream<BleDevice> get scanResults => _scanController.stream;

  @override
  Stream<AvailabilityState> get availabilityStream =>
      UniversalBle.availabilityStream;

  @override
  Future<AvailabilityState> getAvailabilityState() =>
      UniversalBle.getBluetoothAvailabilityState();

  @override
  Future<bool> checkAndRequestPermissions() async {
    try {
      final hasPerm = await UniversalBle.hasPermissions();
      if (!hasPerm) {
        await UniversalBle.requestPermissions();
        return await UniversalBle.hasPermissions();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> startScan({Duration? timeout}) async {
    // Also discover already connected system devices if supported
    try {
      final systemDevices = await UniversalBle.getSystemDevices();
      for (final dev in systemDevices) {
        _scanController.add(dev);
      }
    } catch (_) {
      // Ignored if platform doesn't support getSystemDevices
    }

    await UniversalBle.startScan();
    if (timeout != null) {
      _scanTimer?.cancel();
      _scanTimer = Timer(timeout, stopScan);
    }
  }

  @override
  Future<void> stopScan() async {
    _scanTimer?.cancel();
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
  }

  @override
  Future<void> connect(String deviceId, {Duration? timeout}) async {
    _activeDeviceId = deviceId;
    await UniversalBle.connect(deviceId, timeout: timeout);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    if (_activeDeviceId == deviceId) {
      _activeDeviceId = null;
    }
    await UniversalBle.disconnect(deviceId);
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    try {
      return await UniversalBle.requestMtu(deviceId, expectedMtu);
    } catch (_) {
      return 23; // Default BLE MTU fallback
    }
  }

  @override
  Future<bool> validateRequiredServices(String deviceId) async {
    try {
      final services = await UniversalBle.discoverServices(deviceId);
      var hasFenChar = false;
      var hasCmdWriteChar = false;
      var hasCmdNotifyChar = false;

      for (final s in services) {
        for (final c in s.characteristics) {
          // subscribeNotifications below requires notify, not indication-only.
          final notifies = c.properties.contains(CharacteristicProperty.notify);
          if (_sameUuid(s.uuid, ChessnutConstants.fenServiceUuid) &&
              notifies &&
              _sameUuid(c.uuid, ChessnutConstants.fenCharacteristicUuid)) {
            hasFenChar = true;
          } else if (_sameUuid(s.uuid, ChessnutConstants.commandServiceUuid) &&
              c.properties.contains(CharacteristicProperty.write) &&
              _sameUuid(
                c.uuid,
                ChessnutConstants.commandWriteCharacteristicUuid,
              )) {
            hasCmdWriteChar = true;
          } else if (_sameUuid(s.uuid, ChessnutConstants.commandServiceUuid) &&
              notifies &&
              _sameUuid(
                c.uuid,
                ChessnutConstants.commandNotifyCharacteristicUuid,
              )) {
            hasCmdNotifyChar = true;
          }
        }
      }

      return hasFenChar && hasCmdWriteChar && hasCmdNotifyChar;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> subscribeToNotifications({
    required String deviceId,
    required void Function(Uint8List value) onFenReport,
    required void Function(Uint8List value) onCommandResponse,
  }) async {
    _activeDeviceId = deviceId;
    _fenReportCallback = onFenReport;
    _commandResponseCallback = onCommandResponse;

    await UniversalBle.subscribeNotifications(
      deviceId,
      ChessnutConstants.fenServiceUuid,
      ChessnutConstants.fenCharacteristicUuid,
    );

    await UniversalBle.subscribeNotifications(
      deviceId,
      ChessnutConstants.commandServiceUuid,
      ChessnutConstants.commandNotifyCharacteristicUuid,
    );
  }

  @override
  Future<void> writeCommand(String deviceId, Uint8List data) async {
    await UniversalBle.write(
      deviceId,
      ChessnutConstants.commandServiceUuid,
      ChessnutConstants.commandWriteCharacteristicUuid,
      data,
    );
  }

  @override
  Stream<bool> connectionStateStream(String deviceId) {
    return _connectionControllers
        .putIfAbsent(deviceId, () => StreamController<bool>.broadcast())
        .stream;
  }

  @override
  void dispose() {
    _disposed = true;
    _scanTimer?.cancel();
    _fenReportCallback = null;
    _commandResponseCallback = null;
    _scanController.close();
    for (final c in _connectionControllers.values) {
      c.close();
    }
    _connectionControllers.clear();
  }
}
