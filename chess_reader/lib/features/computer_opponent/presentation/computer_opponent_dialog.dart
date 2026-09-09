import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entitlements/pro_entitlement.dart';
import '../../../core/state/game_session.dart';
import '../domain/computer_opponent_models.dart';
import '../state/computer_opponent_provider.dart';

/// Shows the "Play vs Computer" setup sheet or Pro unlock dialog.
Future<void> showComputerOpponentDialog(BuildContext context, WidgetRef ref) async {
  final isPro = ref.read(proEntitlementProvider);
  if (!isPro) {
    await _showProUpgradeDialog(context, ref);
    return;
  }

  final session = ref.read(gameSessionProvider);
  final canStartFromCurrent = session.legal &&
      !session.position.isCheckmate &&
      !session.position.isStalemate &&
      !session.position.isInsufficientMaterial;

  Side? selectedColor = Side.white; // null = Random
  bool startFromCurrent = canStartFromCurrent;
  var selectedStrength = ComputerStrengthPreset.casual;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;

        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.smart_toy_outlined, color: colorScheme.primary),
              const SizedBox(width: 8),
              const Text('Play vs Computer'),
            ],
          ),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your Color', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<Side?>(
                    segments: const [
                      ButtonSegment(
                        value: Side.white,
                        label: Text('White'),
                        icon: Icon(Icons.circle, color: Colors.white, size: 16),
                      ),
                      ButtonSegment(
                        value: Side.black,
                        label: Text('Black'),
                        icon: Icon(Icons.circle, color: Colors.black, size: 16),
                      ),
                      ButtonSegment(
                        value: null,
                        label: Text('Random'),
                        icon: Icon(Icons.shuffle, size: 16),
                      ),
                    ],
                    selected: {selectedColor},
                    onSelectionChanged: (set) {
                      setState(() => selectedColor = set.first);
                    },
                  ),
                  const SizedBox(height: 18),
                  Text('Starting Position', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  RadioGroup<bool>(
                    groupValue: startFromCurrent,
                    onChanged: (v) {
                      if (v != null && (v == false || canStartFromCurrent)) {
                        setState(() => startFromCurrent = v);
                      }
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RadioListTile<bool>(
                          title: const Text('Current board position'),
                          subtitle: Text(
                            canStartFromCurrent
                                ? (session.onBookLine
                                    ? 'Book position'
                                    : 'Variation excursion')
                                : 'Not available (position is finished or invalid)',
                          ),
                          value: true,
                        ),
                        const RadioListTile<bool>(
                          title: Text('Standard new game'),
                          subtitle: Text('Standard starting chess layout'),
                          value: false,
                        ),
                      ],
                    ),
                  ),
                  if (startFromCurrent && session.turnRecoverable) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline,
                              color: colorScheme.onSecondaryContainer, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Diagram side-to-move is inferred. Game will play with ${session.position.turn.name} to move.',
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Text('Opponent Strength', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  RadioGroup<ComputerStrengthPreset>(
                    groupValue: selectedStrength,
                    onChanged: (p) {
                      if (p != null) setState(() => selectedStrength = p);
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final preset in ComputerStrengthPreset.values)
                          RadioListTile<ComputerStrengthPreset>(
                            title: Text(preset.label),
                            subtitle: Text(preset.description),
                            value: preset,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                ref.read(computerOpponentProvider.notifier).startGame(
                      chosenSide: selectedColor,
                      strength: selectedStrength,
                      startFrom: startFromCurrent ? session.position : Chess.initial,
                    );
              },
              child: const Text('Start Game'),
            ),
          ],
        );
      },
    ),
  );
}

Future<void> _showProUpgradeDialog(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();

  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.lock_outline),
          SizedBox(width: 8),
          Text('Pro Feature'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Play vs Computer lets you play full games against Stockfish at adjustable, '
            'human-like strength from any book position, on-screen and with Chessnut Move LED move guidance.',
          ),
          const SizedBox(height: 16),
          const Text(
            'Pre-release testing unlock code:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Unlock code',
              hintText: 'chess',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final code = controller.text.trim();
            final ok = ref.read(proTestUnlockProvider.notifier).redeem(code);
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(ok ? 'Pro unlocked for testing!' : 'Invalid code.'),
            ));
            if (ok && context.mounted) {
              showComputerOpponentDialog(context, ref);
            }
          },
          child: const Text('Unlock Pro'),
        ),
      ],
    ),
  );
}
