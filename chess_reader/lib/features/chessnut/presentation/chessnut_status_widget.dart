import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_screen.dart';
import '../model/chessnut_state.dart';
import '../state/chessnut_controller.dart';
import 'chessnut_icon.dart';
import 'chessnut_quick_settings_screen.dart';

/// Compact board-panel status indicator and controls for Chessnut Move board.
///
/// Renders nothing until a device has been connected or remembered at least
/// once — the initial connect entry point is [ChessnutConnectIconButton],
/// shown instead in the board panel's icon row so there's only one "connect"
/// control (the toolbar's is the other) rather than two competing ones.
class ChessnutStatusWidget extends ConsumerWidget {
  const ChessnutStatusWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chessnutControllerProvider);
    final controller = ref.read(chessnutControllerProvider.notifier);
    if (!controller.isSupported) return const SizedBox.shrink();

    if (state.connectionState == ChessnutConnectionState.disconnected &&
        state.connectedDeviceId == null) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Status and battery row
            Row(
              children: [
                _buildConnectionStatusIcon(context, state),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _getStatusTitle(state),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (state.boardBattery != null) ...[
                  _buildBatteryBadge(context, state),
                  const SizedBox(width: 8),
                ],
                _buildActionButtons(context, state, controller),
              ],
            ),

            if (state.isConnected && state.syncState == ChessnutSyncState.paused &&
                (state.lastError != null || state.statusMessage != null))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(state.lastError ?? state.statusMessage!,
                    style: Theme.of(context).textTheme.bodySmall),
              ),

            // Low battery warning
            if (state.boardBattery?.isLow == true || state.isAnyPieceBatteryLow)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(Icons.battery_alert,
                        size: 16, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Board or piece battery is low (< 15%). Charge to prevent movement stalls.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.error,
                            ),
                      ),
                    ),
                  ],
                ),
              ),

            // Intermediate Castling / En Passant Hint
            if (state.intermediateHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.onPrimaryContainer),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          state.intermediateHint!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Restricted Side-to-Move Recovery Confirmation Banner
            if (state.pendingTurnRecovery != null)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Diagram side-to-move correction detected. '
                      'Physical board played ${state.pendingTurnRecovery!.move.uci}. '
                      'Correct diagram turn and accept move?',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onTertiaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: controller.dismissTurnRecovery,
                          child: const Text('Dismiss'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: controller.confirmTurnRecovery,
                          child: const Text('Confirm turn'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

            // Mismatch Banner
            if (state.syncState == ChessnutSyncState.mismatch)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Physical piece placement does not match the app position. '
                      'Misplaced squares are illuminated in red on the board.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onErrorContainer,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: controller.stop,
                          child: const Text('Clear red LEDs'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: controller.sendAppPositionToBoard,
                          child: const Text('Send app position'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

            // Send Diagram Anyway Override Button
            if (state.canSendDiagramAnyway)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Detected diagram is unvalidated.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.send, size: 16),
                      label: const Text('Send diagram anyway'),
                      onPressed: controller.sendDiagramAnyway,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionStatusIcon(BuildContext context, ChessnutState state) {
    if (state.connectionState == ChessnutConnectionState.connecting ||
        state.connectionState == ChessnutConnectionState.scanning) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (state.connectionState == ChessnutConnectionState.error) {
      return Icon(Icons.error_outline,
          size: 18, color: Theme.of(context).colorScheme.error);
    }
    if (!state.isConnected) {
      return const Icon(Icons.bluetooth_disabled, size: 18);
    }

    // Connected: show sync icon
    return switch (state.syncState) {
      ChessnutSyncState.synchronized =>
        const Icon(Icons.check_circle, size: 18, color: Colors.green),
      ChessnutSyncState.moving => const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ChessnutSyncState.aligning => const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ChessnutSyncState.mismatch =>
        Icon(Icons.warning_amber_rounded, size: 18, color: Colors.amber[800]),
      ChessnutSyncState.paused =>
        const Icon(Icons.pause_circle_outline, size: 18, color: Colors.blueGrey),
      ChessnutSyncState.error =>
        Icon(Icons.error, size: 18, color: Theme.of(context).colorScheme.error),
    };
  }

  String _getStatusTitle(ChessnutState state) {
    if (!state.isConnected) {
      return state.statusMessage ?? 'Disconnected';
    }
    return switch (state.syncState) {
      ChessnutSyncState.synchronized => 'In sync',
      ChessnutSyncState.moving => 'Pieces moving...',
      ChessnutSyncState.aligning => 'Aligning board...',
      ChessnutSyncState.mismatch => 'Position mismatch',
      ChessnutSyncState.paused => 'Paused',
      ChessnutSyncState.error => state.lastError ?? 'Sync error',
    };
  }

  Widget _buildBatteryBadge(BuildContext context, ChessnutState state) {
    final bat = state.boardBattery;
    if (bat == null) return const SizedBox.shrink();

    final isLow = bat.isLow || state.isAnyPieceBatteryLow;
    final color = isLow ? Theme.of(context).colorScheme.error : null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          bat.charging ? Icons.battery_charging_full : Icons.battery_std,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 2),
        Text(
          '${bat.level}%',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: color,
              ),
        ),
      ],
    );
  }

  Widget _buildActionButtons(
    BuildContext context,
    ChessnutState state,
    ChessnutController controller,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.isConnected) ...[
          if (state.syncState == ChessnutSyncState.paused ||
              state.syncState == ChessnutSyncState.mismatch)
            IconButton(
              tooltip: 'Start / Resume synchronization',
              icon: const Icon(Icons.play_arrow),
              onPressed: controller.startOrResume,
            )
          else if (state.syncState == ChessnutSyncState.synchronized ||
              state.syncState == ChessnutSyncState.moving ||
              state.syncState == ChessnutSyncState.aligning) ...[
            IconButton(
              tooltip: 'Pause synchronization',
              icon: const Icon(Icons.pause),
              onPressed: controller.pause,
            ),
            IconButton(
              tooltip: 'Stop piece movement immediately',
              icon: const Icon(Icons.stop),
              onPressed: controller.stop,
            ),
          ],
        ],
        PopupMenuButton<String>(
          tooltip: 'Chessnut options',
          icon: const Icon(Icons.more_vert, size: 20),
          onSelected: (action) {
            if (action == 'disconnect') {
              controller.disconnect();
            } else if (action == 'scan') {
              controller.startScan();
            } else if (action == 'settings') {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            }
          },
          itemBuilder: (context) => [
            if (state.isConnected)
              const PopupMenuItem(
                value: 'disconnect',
                child: Text('Disconnect'),
              )
            else
              const PopupMenuItem(
                value: 'scan',
                child: Text('Scan again'),
              ),
            const PopupMenuItem(
              value: 'settings',
              child: Text('Settings...'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Icon-only entry point into the Chessnut connect flow, meant to sit among
/// the board panel's other icon-row controls (undo, flip, FEN, ...) before a
/// device is connected or remembered. Once one is, [ChessnutStatusWidget]'s
/// status card takes over and this renders nothing.
class ChessnutConnectIconButton extends ConsumerWidget {
  const ChessnutConnectIconButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chessnutControllerProvider);
    final controller = ref.read(chessnutControllerProvider.notifier);
    if (!controller.isSupported) return const SizedBox.shrink();
    if (state.connectionState != ChessnutConnectionState.disconnected ||
        state.connectedDeviceId != null) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: 'Connect Chessnut board',
      icon: const ChessnutIcon(),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ChessnutQuickSettingsScreen()),
      ),
    );
  }
}
