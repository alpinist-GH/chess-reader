import 'package:chessground/chessground.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/app_settings.dart';
import '../purchase/billing_config.dart';
import '../purchase/paywall_view.dart';
import '../purchase/purchase_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Appearance'),
          ListTile(
            title: const Text('Theme'),
            trailing: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto),
                    tooltip: 'Follow system'),
                ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode),
                    tooltip: 'Light'),
                ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode),
                    tooltip: 'Dark'),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (s) => notifier.setThemeMode(s.first),
            ),
          ),
          const Divider(),
          const _SectionHeader('Board'),
          ListTile(
            title: const Text('Board position'),
            subtitle: const Text('Where the board sits beside the text'),
            trailing: SegmentedButton<BoardPlacement>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                    value: BoardPlacement.auto,
                    icon: Icon(Icons.auto_awesome),
                    tooltip: 'Auto (adapts to screen)'),
                ButtonSegment(
                    value: BoardPlacement.left,
                    icon: Icon(Icons.border_left),
                    tooltip: 'Left'),
                ButtonSegment(
                    value: BoardPlacement.right,
                    icon: Icon(Icons.border_right),
                    tooltip: 'Right'),
                ButtonSegment(
                    value: BoardPlacement.top,
                    icon: Icon(Icons.border_top),
                    tooltip: 'Top'),
                ButtonSegment(
                    value: BoardPlacement.bottom,
                    icon: Icon(Icons.border_bottom),
                    tooltip: 'Bottom'),
              ],
              selected: {settings.boardPlacement},
              onSelectionChanged: (s) => notifier.setBoardPlacement(s.first),
            ),
          ),
          ListTile(
            title: const Text('Piece set'),
            trailing: DropdownButton<PieceSet>(
              value: settings.pieceSet,
              onChanged: (v) => v != null ? notifier.setPieceSet(v) : null,
              items: [
                for (final s in PieceSet.values)
                  DropdownMenuItem(value: s, child: Text(s.label)),
              ],
            ),
          ),
          ListTile(
            title: const Text('Board theme'),
            trailing: DropdownButton<String>(
              value: settings.boardThemeName,
              onChanged: (v) => v != null ? notifier.setBoardTheme(v) : null,
              items: [
                for (final name in boardThemes.keys)
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
            ),
          ),
          const Divider(),
          const _SectionHeader('Engine (Stockfish)'),
          ListTile(
            title: const Text('Threads'),
            subtitle: Slider(
              value: settings.engineThreads.toDouble(),
              min: 1,
              max: 16,
              divisions: 15,
              label: '${settings.engineThreads}',
              onChanged: (v) => notifier.setEngineThreads(v.round()),
            ),
          ),
          ListTile(
            title: const Text('Search depth'),
            subtitle: Slider(
              value: settings.engineDepth.toDouble(),
              min: 10,
              max: 40,
              divisions: 30,
              label: '${settings.engineDepth}',
              onChanged: (v) => notifier.setEngineDepth(v.round()),
            ),
          ),
          const Divider(),
          const _SectionHeader('Reading'),
          ListTile(
            title: const Text('EPUB text size'),
            subtitle: Slider(
              value: settings.textScale,
              min: 0.8,
              max: 1.8,
              divisions: 10,
              label: '${(settings.textScale * 100).round()}%',
              onChanged: (v) => notifier.setTextScale(v),
            ),
          ),
          if (kBillingEnabled) ...[
            const Divider(),
            const _SectionHeader('ChessBook Pro'),
            const _ProSection(),
          ],
        ],
      ),
    );
  }
}

/// Purchase status + buy/restore, shown only on store builds. Lets a user who
/// hasn't hit the paywall yet unlock early, and gives everyone a Restore path.
class _ProSection extends ConsumerWidget {
  const _ProSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(purchaseControllerProvider);
    final controller = ref.read(purchaseControllerProvider.notifier);

    if (state.proUnlocked) {
      return const ListTile(
        leading: Icon(Icons.workspace_premium),
        title: Text('Pro unlocked'),
        subtitle: Text('Unlimited book conversions. Thank you!'),
      );
    }

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.workspace_premium_outlined),
          title: const Text('Unlock unlimited conversions'),
          subtitle: Text('${state.freeRemaining} free '
              '${state.freeRemaining == 1 ? 'conversion' : 'conversions'} left'),
          trailing: FilledButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('ChessBook Pro')),
                body: const PaywallView(),
              ),
            )),
            child: const Text('Unlock'),
          ),
        ),
        ListTile(
          title: const Text('Restore purchase'),
          trailing: TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final ok = await controller.restore();
              messenger.showSnackBar(SnackBar(
                content: Text(ok
                    ? 'Purchase restored.'
                    : 'No previous purchase found.'),
              ));
            },
            child: const Text('Restore'),
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
