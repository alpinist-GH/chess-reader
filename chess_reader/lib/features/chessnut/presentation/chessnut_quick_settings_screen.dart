import 'package:flutter/material.dart';

import 'chessnut_settings_section.dart';

/// Standalone Chessnut Move connection screen, reached directly from the
/// main toolbar rather than buried inside general Settings.
class ChessnutQuickSettingsScreen extends StatelessWidget {
  const ChessnutQuickSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chessnut Move Board')),
      body: ListView(
        children: const [ChessnutSettingsSection(showDivider: false)],
      ),
    );
  }
}
