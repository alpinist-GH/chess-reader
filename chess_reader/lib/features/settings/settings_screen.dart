import 'package:chessground/chessground.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/app_settings.dart';

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
        ],
      ),
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
