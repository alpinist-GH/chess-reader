import 'dart:async';
import 'dart:typed_data';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../../core/settings/app_settings.dart';
import '../../../core/state/game_session.dart';
import '../codec/chessnut_codec.dart';
import '../model/chessnut_constants.dart';
import '../model/chessnut_state.dart';
import '../transport/chessnut_transport.dart';
import '../transport/universal_ble_transport.dart';

/// Provider for the underlying BLE transport. Overridable in tests.
final chessnutTransportProvider = Provider<ChessnutTransport>((ref) {
  final transport = UniversalBleTransport();
  ref.onDispose(transport.dispose);
  return transport;
});

/// Riverpod controller managing Chessnut Move connection, synchronization,
/// physical move recognition, inventory checks, battery monitoring, and LED alerts.
class ChessnutController extends Notifier<ChessnutState>
    with WidgetsBindingObserver {
  ChessnutTransport get _transport => ref.read(chessnutTransportProvider);

  bool _disposed = false;
  bool _foreground = true;
  AvailabilityState? _availability;
  bool get isSupported => _availability != AvailabilityState.unsupported;
  bool get _bluetoothAvailable =>
      _availability == null || _availability == AvailabilityState.poweredOn;
  int _connectionEpoch = 0;
  int _scanEpoch = 0;
  bool _connectionBusy = false;
  int _motionEpoch = 0;
  String? _latestReportedPlacement;
  Timer? _motionTimer;
  Timer? _scanTimer;
  Timer? _stabilityTimer;
  Timer? _graceTimer;
  Timer? _completionTimer;
  Timer? _batteryPollTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _explicitlyDisconnected = false;
  Completer<void>? _pieceStatusCompleter;

  String? _inFlightTargetPlacement;
  String? _pendingTargetPlacement;
  String? _currentSynchronizedPlacement;

  /// True only for the fresh "just connected, never yet manually engaged"
  /// paused state. Distinguishes that specific state — where a matching
  /// physical report can safely skip Start/Resume because nothing has
  /// happened yet — from every other reason the connection can be paused
  /// (explicit Pause/Stop, book reset, backgrounding, error/timeout
  /// recovery), all of which intentionally require explicit
  /// resynchronization per the plan and must not be silently reversed by
  /// a report that merely happens to still match.
  bool _autoSyncEligible = false;

  StreamSubscription<BleDevice>? _scanSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<AvailabilityState>? _availabilitySubscription;

  final List<BleDevice> discoveredDevices = [];

  @override
  ChessnutState build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _disposed = true;
      _connectionEpoch++;
      WidgetsBinding.instance.removeObserver(this);
      _cleanupTimers();
      _scanSubscription?.cancel();
      _connectionSubscription?.cancel();
      _availabilitySubscription?.cancel();
    });

    _listenToAppSession();
    _listenToAvailability();
    _checkInitialAutoReconnect();

    return const ChessnutState();
  }

  void _cleanupTimers() {
    _motionTimer?.cancel();
    _scanTimer?.cancel();
    _stabilityTimer?.cancel();
    _graceTimer?.cancel();
    _completionTimer?.cancel();
    _batteryPollTimer?.cancel();
    _reconnectTimer?.cancel();
  }

  void _listenToAvailability() {
    _availabilitySubscription = _transport.availabilityStream.listen(
      _onAvailability,
    );
    Future.microtask(() async {
      if (_disposed) return;
      try {
        final availability = await _transport.getAvailabilityState();
        if (!_disposed) _onAvailability(availability);
      } catch (
        _
      ) {} // A transient query failure does not mean BLE is unsupported.
    });
  }

  void _onAvailability(AvailabilityState availability) {
    if (_disposed) return;
    final previous = _availability;
    _availability = availability;
    if (!_bluetoothAvailable) {
      _reconnectTimer?.cancel();
      if (state.isConnected ||
          state.connectionState == ChessnutConnectionState.connecting) {
        _onDisconnected();
      }
      state = state.copyWith(
        statusMessage: switch (availability) {
          AvailabilityState.poweredOff =>
            'Bluetooth is powered off. Please enable Bluetooth.',
          AvailabilityState.unauthorized =>
            'Bluetooth permissions denied. Please grant permissions.',
          AvailabilityState.unsupported =>
            'Bluetooth is not supported on this device.',
          _ => 'Bluetooth is unavailable. Try again when it is ready.',
        },
      );
    } else if (_foreground &&
        previous != null &&
        previous != AvailabilityState.poweredOn) {
      _onAppForegrounded();
    }
  }

  void _checkInitialAutoReconnect() {
    // Read persisted settings
    Future.microtask(() {
      if (_disposed || !_foreground) return;
      final settings = ref.read(settingsProvider);
      if (settings.chessnutAutoReconnect && settings.chessnutDeviceId != null) {
        connectToDevice(settings.chessnutDeviceId!, nameHint: 'Chessnut Move');
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _onAppBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
      _onAppForegrounded();
    }
  }

  void _onAppBackgrounded() {
    _foreground = false;
    _reconnectTimer?.cancel();
    if (state.isConnected) {
      // Pause synchronization and clear pending motion
      pause();
      _reconnectTimer?.cancel();
    }
  }

  void _onAppForegrounded() {
    _foreground = true;
    if (!state.isConnected && !_explicitlyDisconnected) {
      final settings = ref.read(settingsProvider);
      if (settings.chessnutAutoReconnect && settings.chessnutDeviceId != null) {
        _attemptReconnect(settings.chessnutDeviceId!);
      }
    }
  }

  /// Observes changes from GameSession.
  void _listenToAppSession() {
    ref.listen<GameSessionState>(gameSessionProvider, (prev, next) {
      _onSessionPositionChanged(prev, next);
    });
  }

  void _onSessionPositionChanged(
    GameSessionState? prev,
    GameSessionState next,
  ) {
    if (prev?.revision == next.revision) return;
    if (next.origin == PositionOrigin.physical) {
      _currentSynchronizedPlacement = ChessnutCodec.extractPlacement(next.fen);
      return; // Physical moves and takebacks must never echo motor commands.
    }
    _latestReportedPlacement = null;
    state = state.copyWith(
      canSendDiagramAnyway: false,
      clearUnvalidatedPlacement: true,
    );
    // Every app or lifecycle revision invalidates physical recognition.
    _stabilityTimer?.cancel();
    _graceTimer?.cancel();
    state = state.copyWith(
      clearPendingTurnRecovery: true,
      clearIntermediateHint: true,
    );

    // Book lifecycle change (opening/closing book) pauses synchronization
    if (next.origin == PositionOrigin.bookReset) {
      pause();
      return;
    }

    // If connected and active (synchronized or aligning), sync new app position
    if (state.isConnected &&
        (state.syncState == ChessnutSyncState.synchronized ||
            state.syncState == ChessnutSyncState.aligning ||
            state.syncState == ChessnutSyncState.moving ||
            state.syncState == ChessnutSyncState.mismatch)) {
      final appPlacement = ChessnutCodec.extractPlacement(next.fen);
      if (!next.legal) {
        pause();
        state = state.copyWith(
          canSendDiagramAnyway: true,
          unvalidatedPlacement: appPlacement,
          statusMessage: 'Diagram is unvalidated. Confirm before sending.',
        );
        return;
      }
      _queueTargetPosition(appPlacement);
    }
  }

  // --- Scan and Connection Management ---

  Future<void> startScan() async {
    if (state.isConnected ||
        state.connectionState == ChessnutConnectionState.connecting) {
      return;
    }
    final scan = ++_scanEpoch;
    bool current() => !_disposed && scan == _scanEpoch;
    discoveredDevices.clear();
    state = state.copyWith(
      connectionState: ChessnutConnectionState.scanning,
      statusMessage: 'Scanning for Chessnut Move boards...',
      clearLastError: true,
    );

    final permsOk = await _transport.checkAndRequestPermissions();
    if (!current()) return;
    if (!permsOk) {
      state = state.copyWith(
        connectionState: ChessnutConnectionState.error,
        lastError: 'Bluetooth permissions were not granted.',
      );
      return;
    }

    _scanSubscription?.cancel();
    _scanSubscription = _transport.scanResults.listen((device) {
      if (!current()) return;
      final existingIndex = discoveredDevices.indexWhere(
        (d) => d.deviceId == device.deviceId,
      );
      if (existingIndex >= 0) {
        discoveredDevices[existingIndex] = device;
      } else {
        discoveredDevices.add(device);
      }
      // Notify listeners via a statusMessage update
      state = state.copyWith(
        statusMessage: 'Found ${discoveredDevices.length} device(s)',
      );
    });

    try {
      await _transport.startScan(timeout: const Duration(seconds: 15));
      if (!current()) return;
      _scanTimer?.cancel();
      _scanTimer = Timer(const Duration(seconds: 15), stopScan);
    } catch (e) {
      if (!current()) return;
      state = state.copyWith(
        connectionState: ChessnutConnectionState.error,
        lastError: 'Failed to start scan: $e',
      );
    }
  }

  Future<void> stopScan() async {
    _scanEpoch++;
    _scanTimer?.cancel();
    await _transport.stopScan();
    if (_disposed) return;
    _scanSubscription?.cancel();
    if (state.connectionState == ChessnutConnectionState.scanning) {
      state = state.copyWith(
        connectionState: ChessnutConnectionState.disconnected,
        statusMessage: 'Scan stopped.',
      );
    }
  }

  Future<void> connectToDevice(String deviceId, {String? nameHint}) async {
    if (_disposed ||
        _connectionBusy ||
        !_foreground ||
        state.isConnected ||
        state.connectionState == ChessnutConnectionState.connecting) {
      return;
    }
    _connectionBusy = true;
    try {
      _explicitlyDisconnected = false;
      _reconnectTimer?.cancel();
      final epoch = ++_connectionEpoch;
      bool current() => !_disposed && epoch == _connectionEpoch;
      state = state.copyWith(
        connectionState: ChessnutConnectionState.connecting,
      );
      await stopScan();
      if (!current()) return;

      state = state.copyWith(
        connectionState: ChessnutConnectionState.connecting,
        connectedDeviceId: deviceId,
        connectedDeviceName: nameHint ?? 'Chessnut Board',
        statusMessage: 'Connecting to board...',
        clearLastError: true,
      );

      try {
        if (!await _transport.checkAndRequestPermissions()) {
          throw StateError('Bluetooth permissions were not granted.');
        }
        if (!current()) return;
        await _connectionSubscription?.cancel();
        if (!current()) return;
        _connectionSubscription = _transport
            .connectionStateStream(deviceId)
            .listen((connected) {
              if (current() && !connected) _onDisconnected();
            });
        final transport = _transport;
        await transport.connect(deviceId, timeout: const Duration(seconds: 12));
        if (!current()) {
          try {
            await transport.disconnect(deviceId);
          } catch (_) {}
          return;
        }

        // Validate required GATT services
        final servicesValid = await _transport.validateRequiredServices(
          deviceId,
        );
        if (!current()) return;
        if (!servicesValid) {
          throw StateError(
            'Device is missing required Chessnut Move GATT services.',
          );
        }

        // Query negotiated transport capacity (Android: requests a larger
        // MTU; Apple/Windows: MTU is OS-managed, so this reads back the
        // value already negotiated during connection/service discovery).
        // Queried after service discovery rather than immediately on
        // connect, since on CoreBluetooth the negotiated value can still
        // reflect the pre-negotiation default if read too early.
        var mtu = await _transport.requestMtu(
          deviceId,
          ChessnutConstants.desiredAndroidMtu,
        );
        if (!current()) return;
        if (mtu < ChessnutConstants.pieceStatusReportMinMtu) {
          // One retry after a short delay: negotiation can still be
          // settling immediately after service discovery completes.
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (!current()) return;
          mtu = await _transport.requestMtu(
            deviceId,
            ChessnutConstants.desiredAndroidMtu,
          );
          if (!current()) return;
        }

        // Subscribe to FEN and command responses
        await _transport.subscribeToNotifications(
          deviceId: deviceId,
          onFenReport: (packet) {
            if (current()) _handleIncomingFenReport(packet);
          },
          onCommandResponse: (packet) {
            if (current()) _handleIncomingCommandResponse(packet);
          },
        );

        if (!current()) return;

        // Enable real-time FEN notifications
        await _transport.writeCommand(
          deviceId,
          ChessnutCodec.encodeEnableFenReportingCommand(),
        );

        if (!current()) return;
        // Remember device in settings
        ref.read(settingsProvider.notifier).setChessnutDevice(deviceId);

        _reconnectAttempts = 0;
        _autoSyncEligible = true;
        state = state.copyWith(
          connectionState: ChessnutConnectionState.connected,
          syncState: ChessnutSyncState.paused, // Initially paused per spec
          negotiatedMtu: mtu,
          statusMessage:
              'Connected (Paused). Press Start/Resume to synchronize.',
        );

        // Initial battery query after connection state is connected
        await queryBattery();
        if (current()) _startBatteryPollingTimer();
      } catch (e) {
        if (!current()) return;
        await _connectionSubscription?.cancel();
        try {
          await _transport.disconnect(deviceId);
        } catch (_) {}
        if (!current()) return;
        state = state.copyWith(
          connectionState: ChessnutConnectionState.error,
          lastError: 'Connection failed: $e',
        );
        _scheduleReconnect(deviceId);
      }
    } finally {
      _connectionBusy = false;
    }
  }

  void _onDisconnected() {
    if (_disposed) return;
    _connectionEpoch++;
    _motionEpoch++;
    _autoSyncEligible = false;
    _inFlightTargetPlacement = null;
    _pendingTargetPlacement = null;
    _currentSynchronizedPlacement = null;
    _latestReportedPlacement = null;
    _transport.availablePieces = null;
    if (_pieceStatusCompleter != null && !_pieceStatusCompleter!.isCompleted) {
      _pieceStatusCompleter!.complete();
    }
    _pieceStatusCompleter = null;
    _cleanupTimers();
    state = state.copyWith(
      connectionState: ChessnutConnectionState.disconnected,
      syncState: ChessnutSyncState.paused,
      clearBoardBattery: true,
      clearPieceStatuses: true,
      clearNegotiatedMtu: true,
      clearPendingTurnRecovery: true,
      clearUnvalidatedPlacement: true,
      canSendDiagramAnyway: false,
      clearIntermediateHint: true,
      mismatchedSquares: const {},
      clearMismatchedPlacement: true,
      statusMessage: 'Disconnected from board.',
    );

    if (!_explicitlyDisconnected) {
      final settings = ref.read(settingsProvider);
      if (settings.chessnutAutoReconnect && settings.chessnutDeviceId != null) {
        _scheduleReconnect(settings.chessnutDeviceId!);
      }
    }
  }

  void _scheduleReconnect(String deviceId) {
    final settings = ref.read(settingsProvider);
    if (_disposed ||
        !_bluetoothAvailable ||
        !_foreground ||
        _explicitlyDisconnected ||
        !settings.chessnutAutoReconnect ||
        settings.chessnutDeviceId != deviceId) {
      return;
    }
    _reconnectTimer?.cancel();

    // Bounded exponential backoff: 2s, 4s, 8s, max 16s
    if (_reconnectAttempts >= 5) {
      state = state.copyWith(
        statusMessage: 'Reconnect failed. Scan again to find the board.',
      );
      return;
    }
    final delaySeconds = (2 << _reconnectAttempts).clamp(2, 16);
    _reconnectAttempts++;

    state = state.copyWith(
      statusMessage: 'Reconnecting in $delaySeconds seconds...',
    );

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _attemptReconnect(deviceId);
    });
  }

  Future<void> _attemptReconnect(String deviceId) async {
    final settings = ref.read(settingsProvider);
    if (_disposed ||
        !_foreground ||
        state.isConnected ||
        _explicitlyDisconnected ||
        !settings.chessnutAutoReconnect ||
        settings.chessnutDeviceId != deviceId) {
      return;
    }
    await connectToDevice(deviceId);
  }

  Future<void> disconnect() async {
    _explicitlyDisconnected = true;
    _connectionEpoch++;
    await pause();
    _reconnectTimer?.cancel();
    final deviceId = state.connectedDeviceId;
    if (deviceId != null) {
      state = state.copyWith(
        connectionState: ChessnutConnectionState.disconnecting,
        statusMessage: 'Disconnecting...',
      );
      try {
        await _transport.disconnect(deviceId);
      } catch (_) {}
    }
    _onDisconnected();
  }

  Future<void> forgetDevice() async {
    ref.read(settingsProvider.notifier).setChessnutDevice(null);
    await disconnect();
    state = const ChessnutState();
  }

  // --- Battery & Piece Status ---

  Future<void> queryBattery() async {
    final deviceId = state.connectedDeviceId;
    if (deviceId == null ||
        !state.isConnected ||
        _inFlightTargetPlacement != null) {
      return;
    }
    final epoch = _connectionEpoch;
    try {
      await _transport.writeCommand(
        deviceId,
        ChessnutCodec.encodeBatteryQueryCommand(),
      );
      if (!_disposed &&
          epoch == _connectionEpoch &&
          (state.negotiatedMtu ?? 0) >=
              ChessnutConstants.pieceStatusReportMinMtu) {
        await _transport.writeCommand(
          deviceId,
          ChessnutCodec.encodePieceStatusQueryCommand(),
        );
      }
    } catch (_) {}
  }

  /// Requests a fresh piece-status report and waits for it to be decoded
  /// (updating [ChessnutTransport.availablePieces]) before returning, rather
  /// than authorizing motion from a report that may be up to
  /// [ChessnutConstants.batteryPollInterval] stale. Leaves availability
  /// unchanged (typically still null / last-known) on timeout or failure;
  /// the caller treats null as unverified and refuses to move.
  Future<void> _refreshAvailablePieces(String deviceId) async {
    if ((state.negotiatedMtu ?? 0) < ChessnutConstants.pieceStatusReportMinMtu) {
      return;
    }
    final completer = Completer<void>();
    _pieceStatusCompleter = completer;
    try {
      await _transport.writeCommand(
        deviceId,
        ChessnutCodec.encodePieceStatusQueryCommand(),
      );
      await completer.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      // Write failure or no response in time.
    } finally {
      if (identical(_pieceStatusCompleter, completer)) {
        _pieceStatusCompleter = null;
      }
    }
  }

  void _startBatteryPollingTimer() {
    _batteryPollTimer?.cancel();
    _batteryPollTimer = Timer.periodic(
      ChessnutConstants.batteryPollInterval,
      (_) => queryBattery(),
    );
  }

  // --- Outgoing App to Board Synchronization ---

  /// User action: Start or Resume synchronization.
  Future<void> startOrResume() async {
    if (!state.isConnected) return;
    _autoSyncEligible = false;

    final session = ref.read(gameSessionProvider);
    final placement = ChessnutCodec.extractPlacement(session.fen);

    if (!session.legal) {
      final inventory = ChessnutCodec.validateInventory(placement);
      state = state.copyWith(
        syncState: ChessnutSyncState.paused,
        canSendDiagramAnyway: inventory.isValid,
        unvalidatedPlacement: placement,
        lastError: inventory.errorMessage,
        statusMessage: 'Diagram is unvalidated. Confirm before sending.',
      );
      return;
    }

    // Validate inventory limits
    final invCheck = ChessnutCodec.validateInventory(placement);
    if (!invCheck.isValid) {
      state = state.copyWith(
        syncState: ChessnutSyncState.paused,
        lastError: invCheck.errorMessage,
        statusMessage: 'Cannot synchronize: ${invCheck.errorMessage}',
        canSendDiagramAnyway: !session.legal,
        unvalidatedPlacement: placement,
      );
      return;
    }

    state = state.copyWith(
      syncState: ChessnutSyncState.aligning,
      statusMessage: 'Aligning physical board with app...',
      clearLastError: true,
      canSendDiagramAnyway: false,
      clearUnvalidatedPlacement: true,
      clearPendingTurnRecovery: true,
    );

    // Resuming (after any pause, backgrounding, or reconnect) is exactly
    // when a piece is most likely to have gone missing unnoticed; confirm
    // inventory now rather than trusting a report that may be up to
    // batteryPollInterval stale. Deliberately not done on every rapid
    // navigation send: that path must stay synchronous (see
    // _sendTargetCommand) so back-to-back position changes correctly
    // collapse into a single in-flight command plus one pending target.
    final deviceId = state.connectedDeviceId;
    if (deviceId != null) {
      await _refreshAvailablePieces(deviceId);
    }

    await _sendTargetCommand(placement);
  }

  /// User action: Pause synchronization.
  Future<void> pause() async {
    _autoSyncEligible = false;
    final wasMoving = _inFlightTargetPlacement != null;
    final deviceId = state.connectedDeviceId;
    _motionEpoch++;
    _motionTimer?.cancel();
    _stabilityTimer?.cancel();
    _graceTimer?.cancel();
    _completionTimer?.cancel();
    _pendingTargetPlacement = null;
    _inFlightTargetPlacement = null;
    _latestReportedPlacement = null;
    state = state.copyWith(
      syncState: ChessnutSyncState.paused,
      clearPendingTurnRecovery: true,
      clearIntermediateHint: true,
      statusMessage: wasMoving
          ? 'Synchronization paused. Physical stop is not confirmed.'
          : 'Synchronization paused.',
    );
    if (wasMoving &&
        deviceId != null &&
        state.isConnected &&
        _transport.motionProtocolVerified) {
      try {
        await _transport.writeCommand(
          deviceId,
          ChessnutCodec.encodeStopCommand(),
        );
      } catch (_) {} // A successful write alone is not stop confirmation.
    }
  }

  /// User action: request a verified stop command, without claiming completion.
  Future<void> stop() async {
    final wasMoving = _inFlightTargetPlacement != null;
    await pause();
    if (!wasMoving && state.isConnected && _transport.motionProtocolVerified) {
      await _writeLedOrStop(ChessnutCodec.encodeStopCommand());
    }
    _clearBoardLeds();
    state = state.copyWith(
      mismatchedSquares: const {},
      clearMismatchedPlacement: true,
    );
  }

  /// User action: Override for unvalidated / imperfect diagram.
  Future<void> sendDiagramAnyway() async {
    final placement = state.unvalidatedPlacement;
    if (placement == null ||
        !state.isConnected ||
        placement !=
            ChessnutCodec.extractPlacement(ref.read(gameSessionProvider).fen)) {
      return;
    }

    final invCheck = ChessnutCodec.validateInventory(placement);
    if (!invCheck.isValid) {
      state = state.copyWith(
        lastError: 'Cannot send diagram: ${invCheck.errorMessage}',
      );
      return;
    }

    state = state.copyWith(
      syncState: ChessnutSyncState.aligning,
      statusMessage: 'Sending unvalidated diagram to board...',
      canSendDiagramAnyway: false,
      clearUnvalidatedPlacement: true,
    );

    // See startOrResume: confirm inventory now rather than trusting a
    // report that may be up to batteryPollInterval stale, since this is a
    // deliberate one-off override rather than the rapid navigation path.
    final deviceId = state.connectedDeviceId;
    if (deviceId != null) {
      await _refreshAvailablePieces(deviceId);
    }

    await _sendTargetCommand(placement);
  }

  void _queueTargetPosition(String placement) {
    // Placement deduplication: same piece placement requires zero motion
    if ((_inFlightTargetPlacement ?? _currentSynchronizedPlacement) ==
        placement) {
      _pendingTargetPlacement = null;
      return;
    }

    // Target piece inventory check
    final invCheck = ChessnutCodec.validateInventory(placement);
    if (!invCheck.isValid) {
      pause();
      state = state.copyWith(
        statusMessage:
            'Position exceeds board inventory: ${invCheck.errorMessage}',
        lastError: invCheck.errorMessage,
        canSendDiagramAnyway: true,
        unvalidatedPlacement: placement,
      );
      return;
    }

    // Retain only the latest pending target
    _pendingTargetPlacement = placement;

    if (state.syncState == ChessnutSyncState.synchronized ||
        state.syncState == ChessnutSyncState.mismatch) {
      _sendTargetCommand(placement);
    }
  }

  Future<void> _sendTargetCommand(String placement) async {
    final deviceId = state.connectedDeviceId;
    if (deviceId == null || !state.isConnected) return;

    if (!_foreground) return;
    final inventory = ChessnutCodec.validateInventory(placement);
    String? error;
    if (!inventory.isValid) {
      error = inventory.errorMessage;
    } else if ((state.negotiatedMtu ?? 0) <
        ChessnutConstants.pieceStatusReportMinMtu) {
      error = 'Bluetooth capacity is insufficient for complete board reports.';
    } else if (!_transport.motionProtocolVerified) {
      error =
          'Automatic movement awaits hardware validation of completion and stopping.';
    }

    final available = _transport.availablePieces;
    if (error == null) {
      if (available == null) {
        error =
            'Piece availability is unknown. Verify the physical inventory first.';
      } else {
        final required = <String, int>{};
        for (final piece in placement.split('')) {
          if (ChessnutCodec.nominalPieceOrder.contains(piece)) {
            required[piece] = (required[piece] ?? 0) + 1;
          }
        }
        for (final entry in required.entries) {
          if (entry.value > (available[entry.key] ?? 0)) {
            error =
                'Required piece unavailable: ${entry.key} (need ${entry.value}).';
            break;
          }
        }
      }
    }
    if (error != null) {
      await pause();
      state = state.copyWith(lastError: error, statusMessage: error);
      return;
    }
    if (_inFlightTargetPlacement != null) {
      _pendingTargetPlacement = placement == _inFlightTargetPlacement
          ? null
          : placement;
      return;
    }
    _stabilityTimer?.cancel();
    _graceTimer?.cancel();
    _latestReportedPlacement = null;
    final epoch = _connectionEpoch;
    final motion = ++_motionEpoch;
    _inFlightTargetPlacement = placement;
    _pendingTargetPlacement = null;
    _motionTimer?.cancel();
    _motionTimer = Timer(const Duration(seconds: 30), () {
      if (!_disposed &&
          epoch == _connectionEpoch &&
          motion == _motionEpoch &&
          _inFlightTargetPlacement != null) {
        pause();
        state = state.copyWith(
          lastError: 'Movement completion timed out. Resume to resynchronize.',
        );
      }
    });

    state = state.copyWith(
      syncState: ChessnutSyncState.moving,
      statusMessage: 'Pieces moving...',
      clearLastError: true,
      clearPendingTurnRecovery: true,
    );

    final cmd = ChessnutCodec.encodeTargetPositionCommand(
      placement,
      force: false, // Non-force mode allows manual interruption
    );

    try {
      await _transport.writeCommand(deviceId, cmd);
    } catch (e) {
      if (_disposed || epoch != _connectionEpoch || motion != _motionEpoch) {
        return;
      }
      await pause();
      state = state.copyWith(
        syncState: ChessnutSyncState.paused,
        lastError: 'Failed to send move command: $e',
      );
    }
  }

  // --- Incoming Board to App Recognition ---

  void _handleIncomingCommandResponse(Uint8List packet) {
    // Battery response
    final battery = ChessnutCodec.decodeBatteryResponse(packet);
    if (battery != null) {
      state = state.copyWith(boardBattery: battery);
      return;
    }

    // Piece status response
    final isPieceStatusResponse =
        packet.length >= 3 &&
        packet[0] == 0x41 &&
        packet[1] == 0x89 &&
        packet[2] == 0x0B;
    if (isPieceStatusResponse) {
      final pieces = ChessnutCodec.decodePieceStatusResponse(packet);
      if (pieces != null) {
        state = state.copyWith(pieceStatuses: pieces);
        // (0, 0) is the confirmed sentinel for a piece lifted fully off the
        // board; any other coordinate (including an off-board reserve slot)
        // counts as available.
        final available = <String, int>{};
        for (final p in pieces) {
          if (p.x == 0 && p.y == 0) continue;
          available[p.pieceChar] = (available[p.pieceChar] ?? 0) + 1;
        }
        _transport.availablePieces = available;
      } else {
        // Header matched but per-piece identities were missing, duplicated,
        // or out of range: the report cannot be trusted to attribute
        // coordinates to the correct pieces, so treat availability as
        // unverified rather than authorizing motion from it.
        _transport.availablePieces = null;
      }
      _pieceStatusCompleter?.complete();
      _pieceStatusCompleter = null;
      return;
    }
  }

  void _handleIncomingFenReport(Uint8List packet) {
    final placement = ChessnutCodec.decodeFenReport(packet);
    if (placement == null || !state.isConnected) return;
    if (_latestReportedPlacement != placement) {
      _stabilityTimer?.cancel();
      _graceTimer?.cancel();
      _completionTimer?.cancel();
      state = state.copyWith(
        clearPendingTurnRecovery: true,
        clearIntermediateHint: true,
      );
    } else {
      return; // Repeated reports must not starve the stability timer.
    }
    _latestReportedPlacement = placement;

    final session = ref.read(gameSessionProvider);
    final appPlacement = ChessnutCodec.extractPlacement(session.fen);

    // If the board reports the in-flight target, don't trust a single
    // packet: the hardware has no distinct motion-completion notification
    // (confirmed on real hardware — the write ack is a generic "command
    // received" reply, not a completion signal, and FEN reports stream
    // continuously through a move). Require the reported placement to stay
    // stable for the same interval used to confirm physical moves before
    // treating the move as complete.
    if (_inFlightTargetPlacement != null &&
        placement == _inFlightTargetPlacement) {
      final target = placement;
      final motion = _motionEpoch;
      final epoch = _connectionEpoch;
      _completionTimer?.cancel();
      _completionTimer = Timer(ChessnutConstants.stabilityDuration, () {
        if (_disposed ||
            epoch != _connectionEpoch ||
            motion != _motionEpoch ||
            _inFlightTargetPlacement != target ||
            _latestReportedPlacement != target) {
          return; // Stale, superseded, or the placement moved on again.
        }
        _completeMotion(target);
      });
      return;
    }

    // If placement matches current app position, clear any mismatch
    if (placement == appPlacement) {
      _stabilityTimer?.cancel();
      _graceTimer?.cancel();
      _currentSynchronizedPlacement = placement;
      if (state.syncState == ChessnutSyncState.mismatch ||
          state.syncState == ChessnutSyncState.aligning) {
        state = state.copyWith(
          syncState: ChessnutSyncState.synchronized,
          statusMessage: 'Synchronized with board.',
          mismatchedSquares: const {},
          clearMismatchedPlacement: true,
          clearIntermediateHint: true,
        );
        _clearBoardLeds();
      } else if (state.syncState == ChessnutSyncState.paused &&
          _autoSyncEligible) {
        // No motion required to match the app: skip the Start/Resume
        // gate entirely rather than waiting for an explicit user tap.
        // Only applies to the fresh post-connect paused state — every
        // other reason for being paused (explicit Pause/Stop, book
        // reset, backgrounding, error/timeout recovery) clears
        // _autoSyncEligible and still requires an explicit Start/Resume.
        _autoSyncEligible = false;
        state = state.copyWith(
          syncState: ChessnutSyncState.synchronized,
          statusMessage: 'Synchronized automatically (board already matched).',
          clearLastError: true,
          canSendDiagramAnyway: false,
          clearUnvalidatedPlacement: true,
          mismatchedSquares: const {},
          clearMismatchedPlacement: true,
          clearIntermediateHint: true,
        );
        _clearBoardLeds();
      }
      return;
    }

    // Only process physical moves when synchronized and idle
    if (state.syncState != ChessnutSyncState.synchronized &&
        state.syncState != ChessnutSyncState.mismatch) {
      return;
    }

    // Timer 1: 350ms Stability Timer
    _stabilityTimer?.cancel();
    final revision = session.revision;
    final epoch = _connectionEpoch;
    _stabilityTimer = Timer(ChessnutConstants.stabilityDuration, () {
      if (!_disposed &&
          epoch == _connectionEpoch &&
          revision == ref.read(gameSessionProvider).revision &&
          placement == _latestReportedPlacement) {
        _processStablePhysicalPlacement(placement);
      }
    });
  }

  void _completeMotion(String placement) {
    _motionTimer?.cancel();
    _inFlightTargetPlacement = null;
    _currentSynchronizedPlacement = placement;

    // If a newer pending target arrived while in-flight, send it now
    if (_pendingTargetPlacement != null) {
      final nextTarget = _pendingTargetPlacement!;
      _pendingTargetPlacement = null;
      _sendTargetCommand(nextTarget);
      return;
    }

    state = state.copyWith(
      syncState: ChessnutSyncState.synchronized,
      statusMessage: 'Synchronized with board.',
      mismatchedSquares: const {},
      clearMismatchedPlacement: true,
    );
    _clearBoardLeds();
  }

  void _processStablePhysicalPlacement(String reportedPlacement) {
    final session = ref.read(gameSessionProvider);

    if (!state.isConnected ||
        (state.syncState != ChessnutSyncState.synchronized &&
            state.syncState != ChessnutSyncState.mismatch)) {
      return;
    }

    // 1. Legal-move matching
    if (session.legal) {
      for (final move in _generateAllLegalMoves(session.position)) {
        final nextPos = session.position.playUnchecked(move);
        final nextPlacement = ChessnutCodec.extractPlacement(nextPos.fen);
        if (nextPlacement == reportedPlacement) {
          // Found exact matching legal move!
          _stabilityTimer?.cancel();
          _graceTimer?.cancel();
          _clearBoardLeds();

          ref
              .read(gameSessionProvider.notifier)
              .playMove(move, origin: PositionOrigin.physical);

          state = state.copyWith(
            syncState: ChessnutSyncState.synchronized,
            statusMessage: 'Move recognized.',
            mismatchedSquares: const {},
            clearMismatchedPlacement: true,
            clearIntermediateHint: true,
          );
          return;
        }
      }
    }

    // 2. Physical Takeback (Seamless Undo) matching
    final prev = ref.read(gameSessionProvider.notifier).previousPosition;
    if (prev != null) {
      final prevPlacement = ChessnutCodec.extractPlacement(prev.$1.fen);
      if (prevPlacement == reportedPlacement) {
        // Physical takeback detected!
        _stabilityTimer?.cancel();
        _graceTimer?.cancel();
        _clearBoardLeds();

        ref
            .read(gameSessionProvider.notifier)
            .undo(origin: PositionOrigin.physical);

        state = state.copyWith(
          syncState: ChessnutSyncState.synchronized,
          statusMessage: 'Takeback recognized.',
          mismatchedSquares: const {},
          clearMismatchedPlacement: true,
          clearIntermediateHint: true,
        );
        return;
      }
    }

    // 3. Restricted side-to-move recovery for newly imported diagrams
    if (session.legal && session.turnRecoverable) {
      final candidateSetup = Setup(
        board: session.position.board,
        turn: session.position.turn.opposite,
        castlingRights: session.position.castles.castlingRights,
        epSquare: session.position.epSquare,
        halfmoves: session.position.halfmoves,
        fullmoves: session.position.fullmoves,
      );

      try {
        final oppositePos = Chess.fromSetup(
          candidateSetup,
          ignoreImpossibleCheck: false,
        );

        final matchingMoves = <NormalMove>[];
        for (final move in _generateAllLegalMoves(oppositePos)) {
          final nextPos = oppositePos.playUnchecked(move);
          if (ChessnutCodec.extractPlacement(nextPos.fen) ==
              reportedPlacement) {
            matchingMoves.add(move);
          }
        }

        if (matchingMoves.length == 1) {
          // Exactly one candidate move from opposite turn
          _stabilityTimer?.cancel();
          _graceTimer?.cancel();

          state = state.copyWith(
            pendingTurnRecovery: TurnRecoveryProposal(
              deviceId: state.connectedDeviceId ?? '',
              revision: session.revision,
              reportedPlacement: reportedPlacement,
              correctedPreMove: oppositePos,
              move: matchingMoves.first,
            ),
            statusMessage:
                'Opposite-turn move detected. Confirm turn correction?',
          );
          return;
        }
      } catch (_) {}
    }

    // 4. Intermediate castling and en passant detection
    final intermediateHint = _detectIntermediateHint(
      session,
      reportedPlacement,
    );
    if (intermediateHint != null) {
      // Hold mismatch grace timer and show subtle hint
      _graceTimer?.cancel();
      state = state.copyWith(
        intermediateHint: intermediateHint,
        statusMessage: intermediateHint,
      );
      return;
    }

    // 5. Timer 2: Grace period (~1.75s) before mismatch UI and red LEDs
    if (_graceTimer == null || !_graceTimer!.isActive) {
      final revision = session.revision;
      final epoch = _connectionEpoch;
      _graceTimer = Timer(ChessnutConstants.mismatchGraceDuration, () {
        if (!_disposed &&
            epoch == _connectionEpoch &&
            revision == ref.read(gameSessionProvider).revision &&
            reportedPlacement == _latestReportedPlacement) {
          _triggerMismatch(reportedPlacement);
        }
      });
    }
  }

  String? _detectIntermediateHint(
    GameSessionState session,
    String reportedPlacement,
  ) {
    if (!session.legal) return null;
    final pos = session.position;

    for (final move in _generateAllLegalMoves(pos)) {
      final piece = pos.board.pieceAt(move.from);
      if (piece == null) continue;
      if (piece.role == Role.king &&
          pos.board.pieceAt(move.to) ==
              Piece(color: pos.turn, role: Role.rook)) {
        final kingside = move.to.file > move.from.file;
        final kingTo = Square(move.from.rank * 8 + (kingside ? 6 : 2));
        final rookTo = Square(move.from.rank * 8 + (kingside ? 5 : 3));
        final intermediate = pos.board
            .removePieceAt(move.from)
            .setPieceAt(kingTo, piece);
        if (reportedPlacement == intermediate.fen) {
          return 'Complete castling: move rook from ${move.to.name} to ${rookTo.name}';
        }
      }
      if (piece.role == Role.pawn &&
          move.to == pos.epSquare &&
          move.from.file != move.to.file &&
          pos.board.pieceAt(move.to) == null) {
        final intermediate = pos.board
            .removePieceAt(move.from)
            .setPieceAt(move.to, piece);
        if (reportedPlacement == intermediate.fen) {
          final captured = Square(move.from.rank * 8 + move.to.file);
          return 'Complete en passant: remove pawn from ${captured.name}';
        }
      }
    }

    return null;
  }

  void _triggerMismatch(String reportedPlacement) {
    final session = ref.read(gameSessionProvider);
    final appPlacement = ChessnutCodec.extractPlacement(session.fen);
    final diff = ChessnutCodec.diffPlacements(appPlacement, reportedPlacement);

    state = state.copyWith(
      syncState: ChessnutSyncState.mismatch,
      mismatchedPlacement: reportedPlacement,
      mismatchedSquares: diff,
      clearIntermediateHint: true,
      statusMessage: 'Physical pieces do not match app position.',
    );

    if (diff.isNotEmpty) {
      _writeLedOrStop(ChessnutCodec.encodeMismatchLedsCommand(diff));
    }
  }

  Future<void> _writeLedOrStop(Uint8List command) async {
    final deviceId = state.connectedDeviceId;
    if (deviceId == null ||
        !state.isConnected ||
        (state.negotiatedMtu ?? 0) < command.length + 3) {
      return;
    }
    try {
      await _transport.writeCommand(deviceId, command);
    } catch (_) {}
  }

  void _clearBoardLeds() {
    _writeLedOrStop(ChessnutCodec.encodeClearLedsCommand());
  }

  /// User action: Confirm proposed side-to-move turn correction.
  void confirmTurnRecovery() {
    final proposal = state.pendingTurnRecovery;
    if (proposal == null) return;

    final session = ref.read(gameSessionProvider);
    // Bind to current connection and revision
    if (!state.isConnected ||
        !session.legal ||
        !session.turnRecoverable ||
        (state.syncState != ChessnutSyncState.synchronized &&
            state.syncState != ChessnutSyncState.mismatch) ||
        proposal.reportedPlacement != _latestReportedPlacement ||
        proposal.deviceId != state.connectedDeviceId ||
        proposal.revision != session.revision) {
      state = state.copyWith(clearPendingTurnRecovery: true);
      return;
    }

    ref
        .read(gameSessionProvider.notifier)
        .applyTurnCorrection(
          correctedPreMove: proposal.correctedPreMove,
          move: proposal.move,
        );

    state = state.copyWith(
      syncState: ChessnutSyncState.synchronized,
      clearPendingTurnRecovery: true,
      statusMessage: 'Turn corrected and move accepted.',
    );
  }

  /// User action: Reject or cancel proposed turn recovery.
  void dismissTurnRecovery() {
    state = state.copyWith(clearPendingTurnRecovery: true);
  }

  /// User action: In mismatch state, push the app position to physical board.
  Future<void> sendAppPositionToBoard() => startOrResume();

  static List<NormalMove> _generateAllLegalMoves(Position pos) {
    final moves = <NormalMove>[];
    pos.legalMoves.forEach((from, dests) {
      final role = pos.board.roleAt(from);
      for (final to in dests.squares) {
        final toRank = to.rank;
        final isPromo = role == Role.pawn && (toRank == 0 || toRank == 7);
        if (isPromo) {
          moves.add(NormalMove(from: from, to: to, promotion: Role.queen));
          moves.add(NormalMove(from: from, to: to, promotion: Role.rook));
          moves.add(NormalMove(from: from, to: to, promotion: Role.bishop));
          moves.add(NormalMove(from: from, to: to, promotion: Role.knight));
        } else {
          moves.add(NormalMove(from: from, to: to));
        }
      }
    });
    return moves;
  }
}

final chessnutControllerProvider =
    NotifierProvider<ChessnutController, ChessnutState>(ChessnutController.new);
