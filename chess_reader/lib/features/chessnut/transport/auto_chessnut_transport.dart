import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'chessnut_transport.dart';
import 'evo_board_channel.dart';
import 'evo_board_protocol.dart';
import 'universal_ble_transport.dart';

/// Picks how to reach a board. On a Chessnut Evo's own Android screen the
/// board is read and lit through the device's board service; everywhere else
/// (phones, tablets, desktops, other boards) it uses Bluetooth.
class AutoChessnutTransport implements ChessnutTransport {
  AutoChessnutTransport({
    ChessnutTransport? ble,
    EvoBoardPort? evo,
    bool? isAndroid,
    this.pollInterval = const Duration(milliseconds: 300),
  }) : _ble = ble ?? UniversalBleTransport(),
       _evo = evo ?? EvoBoardChannel(),
       _isAndroid = isAndroid ?? Platform.isAndroid {
    _bleScanSubscription = _ble.scanResults.listen(_scan.add);
  }

  final ChessnutTransport _ble;
  final EvoBoardPort _evo;
  final bool _isAndroid;

  /// How often the Evo's position is requested while connected.
  final Duration pollInterval;
  final _scan = StreamController<BleDevice>.broadcast();
  final _connection = StreamController<bool>.broadcast();
  StreamSubscription<BleDevice>? _bleScanSubscription;
  StreamSubscription<Map<Object?, Object?>>? _eventSubscription;
  Timer? _pollTimer;
  Future<bool>? _evoPresent;
  bool _evoDetected = false;
  void Function(Uint8List)? _fenCallback;
  bool _disposed = false;
  int _pollEpoch = 0;
  bool _polling = false;

  Future<bool> _hasEvo() => _evoPresent ??= _detectEvo();

  Future<bool> _detectEvo() async {
    final present = _isAndroid && await _evo.isAvailable();
    _evoDetected = present;
    return present;
  }

  static bool _isEvo(String deviceId) => deviceId == EvoBoardChannel.deviceId;

  @override
  bool get motionProtocolVerified =>
      !_evoDetected && _ble.motionProtocolVerified;

  @override
  Map<String, int>? get availablePieces =>
      _evoDetected ? null : _ble.availablePieces;

  @override
  set availablePieces(Map<String, int>? value) => _ble.availablePieces = value;

  @override
  Stream<BleDevice> get scanResults => _scan.stream;

  @override
  Stream<AvailabilityState> get availabilityStream =>
      _ble.availabilityStream.where((_) => !_evoDetected);

  @override
  Future<AvailabilityState> getAvailabilityState() async => await _hasEvo()
      ? AvailabilityState.poweredOn
      : _ble.getAvailabilityState();

  @override
  Future<bool> checkAndRequestPermissions() async =>
      await _hasEvo() ? true : _ble.checkAndRequestPermissions();

  @override
  Future<void> startScan({Duration? timeout}) async {
    if (await _hasEvo()) {
      scheduleMicrotask(() {
        if (_disposed) return;
        _scan.add(
          BleDevice(deviceId: EvoBoardChannel.deviceId, name: 'Chessnut Evo'),
        );
      });
      return;
    }
    await _ble.startScan(timeout: timeout);
  }

  @override
  Future<void> stopScan() async {
    if (_evoDetected) return;
    await _ble.stopScan();
  }

  @override
  Future<void> connect(String deviceId, {Duration? timeout}) async {
    if (!_isEvo(deviceId)) return _ble.connect(deviceId, timeout: timeout);
    await _evo.connect();
    await _eventSubscription?.cancel();
    _eventSubscription = _evo.events.listen((event) {
      if (event['event'] == 'disconnected') {
        _stopPolling();
        if (!_disposed) _connection.add(false);
      } else if (event['event'] == 'fen') {
        _emitReport(event['fen'] as String?);
      }
    });
  }

  @override
  Future<void> disconnect(String deviceId) async {
    if (!_isEvo(deviceId)) return _ble.disconnect(deviceId);
    _stopPolling();
    _fenCallback = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    try {
      await _evo.disconnect();
    } catch (_) {}
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async =>
      _isEvo(deviceId) ? expectedMtu : _ble.requestMtu(deviceId, expectedMtu);

  @override
  Future<bool> validateRequiredServices(String deviceId) async =>
      _isEvo(deviceId) ? true : _ble.validateRequiredServices(deviceId);

  @override
  Future<void> subscribeToNotifications({
    required String deviceId,
    required void Function(Uint8List value) onFenReport,
    required void Function(Uint8List value) onCommandResponse,
  }) async {
    if (!_isEvo(deviceId)) {
      return _ble.subscribeToNotifications(
        deviceId: deviceId,
        onFenReport: onFenReport,
        onCommandResponse: onCommandResponse,
      );
    }
    _fenCallback = onFenReport;
    // The service only calls back on a change. The controller wants the
    // position on request too, as a Bluetooth board streams it, so ask often.
    _stopPolling();
    final epoch = _pollEpoch;
    Future<void> poll() async {
      if (_disposed || epoch != _pollEpoch || _polling) return;
      _polling = true;
      try {
        final fen = await _evo.getFen();
        if (!_disposed && epoch == _pollEpoch) _emitReport(fen);
      } catch (_) {
        // The service may be reconnecting.
      } finally {
        _polling = false;
      }
    }

    _pollTimer = Timer.periodic(pollInterval, (_) => poll());
    await poll();
  }

  void _emitReport(String? fen) {
    final callback = _fenCallback;
    if (callback == null) return;
    final report = EvoBoardProtocol.fenToReport(fen);
    if (report != null) callback(report);
  }

  void _stopPolling() {
    _pollEpoch++;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  Future<void> writeCommand(String deviceId, Uint8List data) async {
    if (!_isEvo(deviceId)) return _ble.writeCommand(deviceId, data);
    // Only the LED command means anything on the Evo: it has no motors and
    // reports its position by itself.
    if (data.length >= 2 && data[0] == 0x43 && data[1] == 0x20) {
      final led = EvoBoardProtocol.ledArguments(
        EvoBoardProtocol.litSquares(data),
      );
      await _evo.setLed(led.on, led.rgb);
    }
  }

  @override
  Stream<bool> connectionStateStream(String deviceId) => _isEvo(deviceId)
      ? _connection.stream
      : _ble.connectionStateStream(deviceId);

  @override
  void dispose() {
    _disposed = true;
    _stopPolling();
    _fenCallback = null;
    if (_evoDetected) unawaited(_evo.disconnect().catchError((_) {}));
    _eventSubscription?.cancel();
    _bleScanSubscription?.cancel();
    _scan.close();
    _connection.close();
    _ble.dispose();
  }
}
