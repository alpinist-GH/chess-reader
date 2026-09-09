import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entitlements/pro_entitlement.dart';
import '../../../core/entitlements/pro_purchase_dialog.dart';
import '../../../core/entitlements/pro_trial.dart';
import '../../../core/settings/app_settings.dart';
import '../model/chessnut_state.dart';
import '../state/chessnut_controller.dart';

const _kChessnutSyncDescription = 'Sync a physical Chessnut Move board with '
    'the app — piece moves on the board move in the reader, and vice versa.';

/// Chessnut Move section within Settings for discovery, connection,
/// remembered board management, and auto-reconnect preferences.
class ChessnutSettingsSection extends ConsumerWidget {
  const ChessnutSettingsSection({super.key, this.showDivider = true});

  /// Whether to lead with a [Divider], appropriate when embedded after other
  /// sections (the general Settings screen) but not on a standalone page.
  final bool showDivider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    final chessnutState = ref.watch(chessnutControllerProvider);
    final controller = ref.read(chessnutControllerProvider.notifier);
    if (!controller.isSupported) return const SizedBox.shrink();
    final isPro = ref.watch(proEntitlementProvider);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        'Chessnut Move Board',
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );

    if (!isPro) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showDivider) const Divider(),
          header,
          const _ProLockedCard(),
        ],
      );
    }

    // Only touch the Bluetooth adapter once an eligible user actually views
    // this section, not when the app starts.
    controller.engageFeature();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showDivider) const Divider(),
        header,

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
                    onPressed: () async {
                      final proceed = await presentProFeatureGate(
                        context,
                        ref,
                        featureName: 'Chessnut Move sync',
                        featureDescription: _kChessnutSyncDescription,
                      );
                      if (!context.mounted || !proceed) return;
                      ref.read(proTrialRemainingProvider.notifier).consumeIfEligible();
                      controller.connectToDevice(
                        settings.chessnutDeviceId!,
                        nameHint: 'Chessnut Move',
                      );
                    },
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
            subtitle: const Text(
              'Automatically reconnect when Chessnut settings are opened',
            ),
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
                      onPressed: () async {
                        final proceed = await presentProFeatureGate(
                          context,
                          ref,
                          featureName: 'Chessnut Move sync',
                          featureDescription: _kChessnutSyncDescription,
                        );
                        if (!context.mounted || !proceed) return;
                        ref.read(proTrialRemainingProvider.notifier).consumeIfEligible();
                        controller.connectToDevice(
                          device.deviceId,
                          nameHint: device.name,
                        );
                      },
                      child: const Text('Connect'),
                    ),
            );
          }),
      ],
    );
  }
}

/// Upsell shown in place of the connect/scan controls when the user hasn't
/// purchased Pro. Board discovery/sync stays disabled until then.
class _ProLockedCard extends ConsumerWidget {
  const _ProLockedCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lock_outline,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  const Text('Pro feature',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Sync a physical Chessnut Move board with the app — piece '
                'moves on the board move in the reader, and vice versa. '
                'Part of the Pro upgrade, alongside play vs computer.',
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => showProPurchaseDialog(context, ref),
                  child: const Text('Upgrade to Pro'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
