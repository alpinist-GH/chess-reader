import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/app_settings.dart';
import '../model/chessnut_state.dart';
import '../state/chessnut_controller.dart';

/// Chessnut Move section within Settings for discovery, connection,
/// remembered board management, and auto-reconnect preferences.
class ChessnutSettingsSection extends ConsumerWidget {
  const ChessnutSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    final chessnutState = ref.watch(chessnutControllerProvider);
    final controller = ref.read(chessnutControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Chessnut Move Board',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ),

        // Status message or error banner
        if (chessnutState.statusMessage != null || chessnutState.lastError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              chessnutState.lastError ?? chessnutState.statusMessage ?? '',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: chessnutState.lastError != null
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
            ),
          ),

        // Remembered device tile
        if (settings.chessnutDeviceId != null) ...[
          ListTile(
            leading: const Icon(Icons.memory),
            title: Text(chessnutState.connectedDeviceName ?? 'Chessnut Move Board'),
            subtitle: Text('ID: ${settings.chessnutDeviceId}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (chessnutState.isConnected)
                  OutlinedButton(
                    onPressed: controller.disconnect,
                    child: const Text('Disconnect'),
                  )
                else
                  FilledButton.tonal(
                    onPressed: () => controller.connectToDevice(
                      settings.chessnutDeviceId!,
                      nameHint: 'Chessnut Move',
                    ),
                    child: const Text('Connect'),
                  ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Forget this board',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: controller.forgetDevice,
                ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('Auto-reconnect'),
            subtitle: const Text('Automatically reconnect when app is opened'),
            value: settings.chessnutAutoReconnect,
            onChanged: (v) => settingsNotifier.setChessnutAutoReconnect(v),
          ),
        ],

        // Scan button & controls
        ListTile(
          title: const Text('Scan for boards'),
          subtitle: const Text('Discover nearby Chessnut Move electronic boards'),
          trailing: chessnutState.connectionState == ChessnutConnectionState.scanning
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : FilledButton.icon(
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Scan'),
                  onPressed: controller.startScan,
                ),
        ),

        // Discovered devices list
        if (controller.discoveredDevices.isNotEmpty)
          ...controller.discoveredDevices.map((device) {
            final isCurrent = chessnutState.connectedDeviceId == device.deviceId;
            return ListTile(
              leading: const Icon(Icons.bluetooth),
              title: Text(device.name?.isNotEmpty == true
                  ? device.name!
                  : 'Unnamed BLE Device'),
              subtitle: Text(
                '${device.deviceId}${device.rssi != null ? ' (${device.rssi} dBm)' : ''}',
              ),
              trailing: isCurrent && chessnutState.isConnected
                  ? const Chip(
                      label: Text('Connected'),
                      backgroundColor: Colors.greenAccent,
                    )
                  : FilledButton.tonal(
                      onPressed: () => controller.connectToDevice(
                        device.deviceId,
                        nameHint: device.name,
                      ),
                      child: const Text('Connect'),
                    ),
            );
          }),
      ],
    );
  }
}
