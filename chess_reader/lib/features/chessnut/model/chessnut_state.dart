import 'package:dartchess/dartchess.dart';

/// State of the Bluetooth connection to the Chessnut Move board.
enum ChessnutConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  disconnecting,
  error,
}

/// State of board synchronization with the app.
enum ChessnutSyncState {
  /// Connected but synchronization is not running (e.g. initial connect, paused by user,
  /// book change, app backgrounded). Physical moves do not alter the app.
  paused,

  /// In the process of setting the board to the app position.
  aligning,

  /// Board and app positions match, ready for play.
  synchronized,

  /// Board is physically executing a piece movement.
  moving,

  /// Physical board placement differs from the app and is not a valid legal move.
  mismatch,

  /// An error occurred during transport or synchronization.
  error,
}

/// Board battery information.
class ChessnutBatteryState {
  const ChessnutBatteryState({
    required this.level,
    required this.charging,
  });

  final int level; // 0 - 100
  final bool charging;

  bool get isLow => level < 15;
}

/// Individual motorized piece status.
class ChessnutPieceStatus {
  const ChessnutPieceStatus({
    required this.pieceIndex,
    required this.pieceChar,
    required this.x,
    required this.y,
    required this.battery,
  });

  final int pieceIndex; // 0..33
  final String pieceChar; // 'P', 'R', 'N', 'B', 'Q', 'K', 'p', 'r', 'n', 'b', 'q', 'k'
  final int x; // 0..255
  final int y; // 0..255
  final int battery; // 0..100

  bool get isLowBattery => battery < 15;
}

/// Inventory validation result for a target position.
class ChessnutInventoryCheck {
  const ChessnutInventoryCheck.valid()
      : isValid = true,
        errorMessage = null;

  const ChessnutInventoryCheck.invalid(this.errorMessage)
      : isValid = false;

  final bool isValid;
  final String? errorMessage;
}

/// A proposal to recover an inferred wrong side-to-move on a newly imported diagram.
class TurnRecoveryProposal {
  const TurnRecoveryProposal({
    required this.deviceId,
    required this.revision,
    required this.reportedPlacement,
    required this.correctedPreMove,
    required this.move,
  });

  final String deviceId;
  final int revision;
  final String reportedPlacement;
  final Position correctedPreMove;
  final NormalMove move;
}

/// Complete state snapshot of the Chessnut integration.
class ChessnutState {
  const ChessnutState({
    this.connectionState = ChessnutConnectionState.disconnected,
    this.syncState = ChessnutSyncState.paused,
    this.connectedDeviceId,
    this.connectedDeviceName,
    this.boardBattery,
    this.pieceStatuses,
    this.negotiatedMtu,
    this.statusMessage,
    this.lastError,
    this.pendingTurnRecovery,
    this.mismatchedPlacement,
    this.mismatchedSquares = const {},
    this.intermediateHint,
    this.canSendDiagramAnyway = false,
    this.unvalidatedPlacement,
  });

  final ChessnutConnectionState connectionState;
  final ChessnutSyncState syncState;
  final String? connectedDeviceId;
  final String? connectedDeviceName;
  final ChessnutBatteryState? boardBattery;
  final List<ChessnutPieceStatus>? pieceStatuses;
  final int? negotiatedMtu;
  final String? statusMessage;
  final String? lastError;
  final TurnRecoveryProposal? pendingTurnRecovery;
  final String? mismatchedPlacement;
  final Set<int> mismatchedSquares; // 0..63 indices
  final String? intermediateHint;
  final bool canSendDiagramAnyway;
  final String? unvalidatedPlacement;

  bool get isConnected =>
      connectionState == ChessnutConnectionState.connected;

  bool get isAnyPieceBatteryLow =>
      pieceStatuses?.any((p) => p.isLowBattery) ?? false;

  ChessnutState copyWith({
    ChessnutConnectionState? connectionState,
    ChessnutSyncState? syncState,
    String? connectedDeviceId,
    bool clearConnectedDeviceId = false,
    String? connectedDeviceName,
    bool clearConnectedDeviceName = false,
    ChessnutBatteryState? boardBattery,
    bool clearBoardBattery = false,
    List<ChessnutPieceStatus>? pieceStatuses,
    bool clearPieceStatuses = false,
    int? negotiatedMtu,
    bool clearNegotiatedMtu = false,
    String? statusMessage,
    bool clearStatusMessage = false,
    String? lastError,
    bool clearLastError = false,
    TurnRecoveryProposal? pendingTurnRecovery,
    bool clearPendingTurnRecovery = false,
    String? mismatchedPlacement,
    bool clearMismatchedPlacement = false,
    Set<int>? mismatchedSquares,
    String? intermediateHint,
    bool clearIntermediateHint = false,
    bool? canSendDiagramAnyway,
    String? unvalidatedPlacement,
    bool clearUnvalidatedPlacement = false,
  }) {
    return ChessnutState(
      connectionState: connectionState ?? this.connectionState,
      syncState: syncState ?? this.syncState,
      connectedDeviceId: clearConnectedDeviceId
          ? null
          : (connectedDeviceId ?? this.connectedDeviceId),
      connectedDeviceName: clearConnectedDeviceName
          ? null
          : (connectedDeviceName ?? this.connectedDeviceName),
      boardBattery: clearBoardBattery ? null : (boardBattery ?? this.boardBattery),
      pieceStatuses: clearPieceStatuses ? null : (pieceStatuses ?? this.pieceStatuses),
      negotiatedMtu: clearNegotiatedMtu ? null : (negotiatedMtu ?? this.negotiatedMtu),
      statusMessage: clearStatusMessage ? null : (statusMessage ?? this.statusMessage),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      pendingTurnRecovery: clearPendingTurnRecovery
          ? null
          : (pendingTurnRecovery ?? this.pendingTurnRecovery),
      mismatchedPlacement: clearMismatchedPlacement
          ? null
          : (mismatchedPlacement ?? this.mismatchedPlacement),
      mismatchedSquares: mismatchedSquares ?? this.mismatchedSquares,
      intermediateHint: clearIntermediateHint
          ? null
          : (intermediateHint ?? this.intermediateHint),
      canSendDiagramAnyway:
          canSendDiagramAnyway ?? this.canSendDiagramAnyway,
      unvalidatedPlacement: clearUnvalidatedPlacement
          ? null
          : (unvalidatedPlacement ?? this.unvalidatedPlacement),
    );
  }
}
