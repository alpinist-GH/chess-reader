import 'dart:async';
import 'dart:typed_data';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
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
class ChessnutController extends Notifier<ChessnutState> with WidgetsBindingObserver {
  ChessnutTransport get _transport => ref.read(chessnutTransportProvider);

  Timer? _stabilityTimer;
  Timer? _graceTimer;
  Timer? _batteryPollTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _explicitlyDisconnected = false;

  String? _inFlightTargetPlacement;
  String? _pendingTargetPlacement;
  String? _currentSynchronizedPlacement;
  int _lastRecognizedRevision = -1;

  StreamSubscription<BleDevice>? _scanSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<AvailabilityState>? _availabilitySubscription;

  final List<BleDevice> discoveredDevices = [];

  @override
  ChessnutState build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
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
    _stabilityTimer?.cancel();
    _graceTimer?.cancel();
    _batteryPollTimer?.cancel();
    _reconnectTimer?.cancel();
  }

  void _listenToAvailability() {
    _availabilitySubscription = _transport.availabilityStream.listen((avail) {
      if (avail == AvailabilityState.poweredOff) {
        state = state.copyWith(
          statusMessage: 'Bluetooth is powered off. Please enable Bluetooth.',
        );
      } else if (avail == AvailabilityState.unauthorized) {
        state = state.copyWith(
          statusMessage: 'Bluetooth permissions denied. Please grant permissions.',
        );
      }
    });
  }

  void _checkInitialAutoReconnect() {
    // Read persisted settings
    Future.microtask(() {
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
    if (state.isConnected) {
      // Pause synchronization and clear pending motion
      pause();
      _reconnectTimer?.cancel();
    }
  }

  void _onAppForegrounded() {
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

  void _onSessionPositionChanged(GameSessionState? prev, GameSessionState next) {
    // Collision rule: App-origin change invalidates in-flight physical settling buffer
    if (next.origin == PositionOrigin.app) {
      _stabilityTimer?.cancel();
      _graceTimer?.cancel();
      _lastRecognizedRevision = next.revision;
      if (state.pendingTurnRecovery != null) {
        state = state.copyWith(clearPendingTurnRecovery: true);
      }
    }

    // Book lifecycle change (opening/closing book) pauses synchronization
    if (next.origin == PositionOrigin.bookReset) {
      pause();
      return;
    }

    // If connected and active (synchronized or aligning), sync new app position
    if (state.isConnected &&
        (state.syncState == ChessnutSyncState.synchronized ||
            state.syncState == ChessnutSyncState.aligning ||
            state.syncState == ChessnutSyncState.moving)) {
      final appPlacement = ChessnutCodec.extractPlacement(next.fen);
      _queueTargetPosition(appPlacement, isAppOrigin: next.origin == PositionOrigin.app);
    }
  }

  // --- Scan and Connection Management ---

  Future<void> startScan() async {
    discoveredDevices.clear();
    state = state.copyWith(
      connectionState: ChessnutConnectionState.scanning,
      statusMessage: 'Scanning for Chessnut Move boards...',
      clearLastError: true,
    );

    final permsOk = await _transport.checkAndRequestPermissions();
    if (!permsOk) {
      state = state.copyWith(
        connectionState: ChessnutConnectionState.error,
        lastError: 'Bluetooth permissions were not granted.',
      );
      return;
    }

    _scanSubscription?.cancel();
    _scanSubscription = _transport.scanResults.listen((device) {
      final existingIndex =
          discoveredDevices.indexWhere((d) => d.deviceId == device.deviceId);
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
    } catch (e) {
      state = state.copyWith(
        connectionState: ChessnutConnectionState.error,
        lastError: 'Failed to start scan: $e',
      );
    }
  }

  Future<void> stopScan() async {
    await _transport.stopScan();
    _scanSubscription?.cancel();
    if (state.connectionState == ChessnutConnectionState.scanning) {
      state = state.copyWith(
        connectionState: ChessnutConnectionState.disconnected,
        statusMessage: 'Scan stopped.',
      );
    }
  }

  Future<void> connectToDevice(String deviceId, {String? nameHint}) async {
    _explicitlyDisconnected = false;
    _reconnectTimer?.cancel();
    await stopScan();

    state = state.copyWith(
      connectionState: ChessnutConnectionState.connecting,
      connectedDeviceId: deviceId,
      connectedDeviceName: nameHint ?? 'Chessnut Board',
      statusMessage: 'Connecting to board...',
      clearLastError: true,
    );

    try {
      await _transport.connect(deviceId, timeout: const Duration(seconds: 12));

      // Validate MTU on Android / verify transport capacity
      final mtu = await _transport.requestMtu(
        deviceId,
        ChessnutConstants.desiredAndroidMtu,
      );

      // Validate required GATT services
      final servicesValid =
          await _transport.validateRequiredServices(deviceId);
      if (!servicesValid) {
        await _transport.disconnect(deviceId);
        state = state.copyWith(
          connectionState: ChessnutConnectionState.error,
          lastError:
              'Device is missing required Chessnut Move GATT services.',
        );
        return;
      }

      // Subscribe to FEN and command responses
      await _transport.subscribeToNotifications(
        deviceId: deviceId,
        onFenReport: _handleIncomingFenReport,
        onCommandResponse: _handleIncomingCommandResponse,
      );

      // Listen to disconnect events
      _connectionSubscription?.cancel();
      _connectionSubscription =
          _transport.connectionStateStream(deviceId).listen((isConnected) {
        if (!isConnected) {
          _onDisconnected();
        }
      });

      // Enable real-time FEN notifications
      await _transport.writeCommand(
        deviceId,
        ChessnutCodec.encodeEnableFenReportingCommand(),
      );

      // Remember device in settings
      ref.read(settingsProvider.notifier).setChessnutDevice(deviceId);

      _reconnectAttempts = 0;
      state = state.copyWith(
        connectionState: ChessnutConnectionState.connected,
        syncState: ChessnutSyncState.paused, // Initially paused per spec
        negotiatedMtu: mtu,
        statusMessage:
            'Connected (Paused). Press Start/Resume to synchronize.',
      );

      // Initial battery query after connection state is connected
      await queryBattery();
      _startBatteryPollingTimer();
    } catch (e) {
      state = state.copyWith(
        connectionState: ChessnutConnectionState.error,
        lastError: 'Connection failed: $e',
      );
      _scheduleReconnect(deviceId);
    }
  }

  void _onDisconnected() {
    _cleanupTimers();
    state = state.copyWith(
      connectionState: ChessnutConnectionState.disconnected,
      syncState: ChessnutSyncState.paused,
      clearBoardBattery: true,
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
    if (_explicitlyDisconnected) return;
    _reconnectTimer?.cancel();

    // Bounded exponential backoff: 2s, 4s, 8s, max 16s
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
    if (state.isConnected || _explicitlyDisconnected) return;
    await connectToDevice(deviceId);
  }

  Future<void> disconnect() async {
    _explicitlyDisconnected = true;
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
    if (deviceId == null || !state.isConnected) return;
    try {
      await _transport.writeCommand(
        deviceId,
        ChessnutCodec.encodeBatteryQueryCommand(),
      );
      await _transport.writeCommand(
        deviceId,
        ChessnutCodec.encodePieceStatusQueryCommand(),
      );
    } catch (_) {}
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

    final session = ref.read(gameSessionProvider);
    final placement = ChessnutCodec.extractPlacement(session.fen);

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

    await _sendTargetCommand(placement);
  }

  /// User action: Pause synchronization.
  Future<void> pause() async {
    _stabilityTimer?.cancel();
    _graceTimer?.cancel();
    _pendingTargetPlacement = null;

    state = state.copyWith(
      syncState: ChessnutSyncState.paused,
      statusMessage: 'Synchronization paused.',
    );
  }

  /// User action: Stop physical motion immediately.
  Future<void> stop() async {
    final deviceId = state.connectedDeviceId;
    _pendingTargetPlacement = null;
    _inFlightTargetPlacement = null;
    _stabilityTimer?.cancel();
    _graceTimer?.cancel();

    if (deviceId != null && state.isConnected) {
      try {
        await _transport.writeCommand(
          deviceId,
          ChessnutCodec.encodeStopCommand(),
        );
        await _transport.writeCommand(
          deviceId,
          ChessnutCodec.encodeClearLedsCommand(),
        );
      } catch (_) {}
    }

    state = state.copyWith(
      syncState: ChessnutSyncState.paused,
      statusMessage: 'Movement stopped.',
      mismatchedSquares: const {},
      clearMismatchedPlacement: true,
    );
  }

  /// User action: Override for unvalidated / imperfect diagram.
  Future<void> sendDiagramAnyway() async {
    final placement = state.unvalidatedPlacement;
    if (placement == null || !state.isConnected) return;

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

    await _sendTargetCommand(placement);
  }

  void _queueTargetPosition(String placement, {bool isAppOrigin = false}) {
    // Placement deduplication: same piece placement requires zero motion
    if ((_inFlightTargetPlacement ?? _currentSynchronizedPlacement) == placement) {
      return;
    }

    // Target piece inventory check
    final invCheck = ChessnutCodec.validateInventory(placement);
    if (!invCheck.isValid) {
      pause();
      state = state.copyWith(
        statusMessage: 'Position exceeds board inventory: ${invCheck.errorMessage}',
        lastError: invCheck.errorMessage,
        canSendDiagramAnyway: true,
        unvalidatedPlacement: placement,
      );
      return;
    }

    // Retain only the latest pending target
    _pendingTargetPlacement = placement;

    // If rapid navigation occurred with an in-flight motion, abort/retarget immediately
    if (isAppOrigin && _inFlightTargetPlacement != null) {
      _sendTargetCommand(placement);
      return;
    }

    if (state.syncState == ChessnutSyncState.synchronized) {
      _sendTargetCommand(placement);
    }
  }

  Future<void> _sendTargetCommand(String placement) async {
    final deviceId = state.connectedDeviceId;
    if (deviceId == null || !state.isConnected) return;

    _inFlightTargetPlacement = placement;
    _pendingTargetPlacement = null;

    state = state.copyWith(
      syncState: ChessnutSyncState.moving,
      statusMessage: 'Pieces moving...',
    );

    final cmd = ChessnutCodec.encodeTargetPositionCommand(
      placement,
      force: false, // Non-force mode allows manual interruption
    );

    try {
      await _transport.writeCommand(deviceId, cmd);
    } catch (e) {
      _inFlightTargetPlacement = null;
      state = state.copyWith(
        syncState: ChessnutSyncState.error,
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
    final pieces = ChessnutCodec.decodePieceStatusResponse(packet);
    if (pieces != null) {
      state = state.copyWith(pieceStatuses: pieces);
      return;
    }
  }

  void _handleIncomingFenReport(Uint8List packet) {
    final placement = ChessnutCodec.decodeFenReport(packet);
    if (placement == null) return;

    final session = ref.read(gameSessionProvider);
    final appPlacement = ChessnutCodec.extractPlacement(session.fen);

    // If board reached the in-flight target, transition to synchronized
    if (_inFlightTargetPlacement != null && placement == _inFlightTargetPlacement) {
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
    _stabilityTimer = Timer(ChessnutConstants.stabilityDuration, () {
      _processStablePhysicalPlacement(placement);
    });
  }

  void _processStablePhysicalPlacement(String reportedPlacement) {
    final session = ref.read(gameSessionProvider);

    // Collision check: Ignore results if session revision has changed
    if (_lastRecognizedRevision > session.revision) {
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

          ref.read(gameSessionProvider.notifier).playMove(
                move,
                origin: PositionOrigin.physical,
              );

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

        ref.read(gameSessionProvider.notifier).undo(
              origin: PositionOrigin.physical,
            );

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
    if (session.turnRecoverable) {
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
          ignoreImpossibleCheck: true,
        );

        final matchingMoves = <NormalMove>[];
        for (final move in _generateAllLegalMoves(oppositePos)) {
          final nextPos = oppositePos.playUnchecked(move);
          if (ChessnutCodec.extractPlacement(nextPos.fen) == reportedPlacement) {
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
    final intermediateHint = _detectIntermediateHint(session, reportedPlacement);
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
      _graceTimer = Timer(ChessnutConstants.mismatchGraceDuration, () {
        _triggerMismatch(reportedPlacement);
      });
    }
  }

  String? _detectIntermediateHint(
    GameSessionState session,
    String reportedPlacement,
  ) {
    if (!session.legal) return null;
    final pos = session.position;

    // Check White O-O intermediate (King on g1, Rook still on h1)
    if (pos.turn == Side.white &&
        pos.castles.rookOf(Side.white, CastlingSide.king) != null) {
      final whiteK = pos.board.kingOf(Side.white);
      if (whiteK == Square.e1) {
        final testBoard = pos.board
            .removePieceAt(Square.e1)
            .setPieceAt(Square.g1, const Piece(color: Side.white, role: Role.king));
        final expectedFen = ChessnutCodec.extractPlacement(testBoard.fen);
        if (reportedPlacement == expectedFen) {
          return 'Complete castling: move rook from h1 to f1';
        }
      }
    }

    // Check White O-O-O intermediate (King on c1, Rook still on a1)
    if (pos.turn == Side.white &&
        pos.castles.rookOf(Side.white, CastlingSide.queen) != null) {
      final whiteK = pos.board.kingOf(Side.white);
      if (whiteK == Square.e1) {
        final testBoard = pos.board
            .removePieceAt(Square.e1)
            .setPieceAt(Square.c1, const Piece(color: Side.white, role: Role.king));
        final expectedFen = ChessnutCodec.extractPlacement(testBoard.fen);
        if (reportedPlacement == expectedFen) {
          return 'Complete castling: move rook from a1 to d1';
        }
      }
    }

    // Check Black O-O intermediate (King on g8, Rook still on h8)
    if (pos.turn == Side.black &&
        pos.castles.rookOf(Side.black, CastlingSide.king) != null) {
      final blackK = pos.board.kingOf(Side.black);
      if (blackK == Square.e8) {
        final testBoard = pos.board
            .removePieceAt(Square.e8)
            .setPieceAt(Square.g8, const Piece(color: Side.black, role: Role.king));
        final expectedFen = ChessnutCodec.extractPlacement(testBoard.fen);
        if (reportedPlacement == expectedFen) {
          return 'Complete castling: move rook from h8 to f8';
        }
      }
    }

    // Check Black O-O-O intermediate (King on c8, Rook still on a8)
    if (pos.turn == Side.black &&
        pos.castles.rookOf(Side.black, CastlingSide.queen) != null) {
      final blackK = pos.board.kingOf(Side.black);
      if (blackK == Square.e8) {
        final testBoard = pos.board
            .removePieceAt(Square.e8)
            .setPieceAt(Square.c8, const Piece(color: Side.black, role: Role.king));
        final expectedFen = ChessnutCodec.extractPlacement(testBoard.fen);
        if (reportedPlacement == expectedFen) {
          return 'Complete castling: move rook from a8 to d8';
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

    // Illuminate mismatched squares in red on the board
    final deviceId = state.connectedDeviceId;
    if (deviceId != null && state.isConnected && diff.isNotEmpty) {
      try {
        _transport.writeCommand(
          deviceId,
          ChessnutCodec.encodeMismatchLedsCommand(diff),
        );
      } catch (_) {}
    }
  }

  void _clearBoardLeds() {
    final deviceId = state.connectedDeviceId;
    if (deviceId != null && state.isConnected) {
      try {
        _transport.writeCommand(
          deviceId,
          ChessnutCodec.encodeClearLedsCommand(),
        );
      } catch (_) {}
    }
  }

  /// User action: Confirm proposed side-to-move turn correction.
  void confirmTurnRecovery() {
    final proposal = state.pendingTurnRecovery;
    if (proposal == null) return;

    final session = ref.read(gameSessionProvider);
    // Bind to current connection and revision
    if (proposal.deviceId != state.connectedDeviceId ||
        proposal.revision != session.revision) {
      state = state.copyWith(clearPendingTurnRecovery: true);
      return;
    }

    ref.read(gameSessionProvider.notifier).applyTurnCorrection(
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
  Future<void> sendAppPositionToBoard() async {
    _clearBoardLeds();
    final session = ref.read(gameSessionProvider);
    final appPlacement = ChessnutCodec.extractPlacement(session.fen);

    state = state.copyWith(
      syncState: ChessnutSyncState.aligning,
      statusMessage: 'Sending app position to board...',
      mismatchedSquares: const {},
      clearMismatchedPlacement: true,
    );

    await _sendTargetCommand(appPlacement);
  }

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
