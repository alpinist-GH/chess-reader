import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entitlements/pro_purchase_dialog.dart';
import '../../../core/entitlements/pro_trial.dart';
import '../../../core/state/game_session.dart';
import '../domain/computer_opponent_models.dart';
import '../state/computer_opponent_provider.dart';

/// Shows the "Play vs Computer" setup sheet, after a Pro feature gate (an
/// info dialog with the remaining trial count, or the full purchase dialog
/// once credits are exhausted).
Future<void> showComputerOpponentDialog(BuildContext context, WidgetRef ref) async {
  final proceed = await presentProFeatureGate(
    context,
    ref,
    featureName: 'Play vs Computer',
    featureDescription:
        'Play a full game against the built-in Stockfish engine.',
  );
  if (!proceed || !context.mounted) return;

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
                ref.read(proTrialRemainingProvider.notifier).consumeIfEligible();
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
