import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/computer_opponent_models.dart';
import '../state/computer_opponent_provider.dart';

/// Status banner and controls shown during or at the conclusion of a game vs computer.
class ComputerGameBar extends ConsumerWidget {
  const ComputerGameBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opponent = ref.watch(computerOpponentProvider);
    if (opponent.phase == ComputerGamePhase.idle ||
        opponent.phase == ComputerGamePhase.setup) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (opponent.isFinished) {
      final result = opponent.result;
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  result?.winner == GameWinner.human
                      ? Icons.emoji_events
                      : (result?.winner == GameWinner.draw
                          ? Icons.handshake
                          : Icons.sentiment_dissatisfied),
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    result?.description ?? 'Game finished.',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.menu_book),
                  label: const Text('Return to Book'),
                  onPressed: () =>
                      ref.read(computerOpponentProvider.notifier).returnToBook(),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Rematch'),
                  onPressed: () =>
                      ref.read(computerOpponentProvider.notifier).rematch(),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Swap Colors'),
                  onPressed: () => ref
                      .read(computerOpponentProvider.notifier)
                      .rematch(swapColors: true),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (opponent.phase == ComputerGamePhase.error) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    opponent.errorMessage ?? 'Engine error occurred.',
                    style: TextStyle(color: colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Nothing to retry when the failure happened before a game was
                // ever set up (entitlement, unusable start position).
                if (opponent.savedReaderContext == null)
                  FilledButton(
                    onPressed: () => ref
                        .read(computerOpponentProvider.notifier)
                        .returnToBook(),
                    child: const Text('Dismiss'),
                  )
                else ...[
                  TextButton(
                    onPressed: () => ref
                        .read(computerOpponentProvider.notifier)
                        .returnToBook(),
                    child: const Text('End Game'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => ref
                        .read(computerOpponentProvider.notifier)
                        .retryEngine(),
                    child: const Text('Retry Engine'),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }

    // Active game status bar
    Widget statusContent;
    Widget? trailingAction;

    switch (opponent.phase) {
      case ComputerGamePhase.engineThinking:
        statusContent = Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Computer is thinking... (${opponent.strength.label})',
                style: theme.textTheme.bodyMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
        trailingAction = TextButton(
          onPressed: () => _confirmResign(context, ref),
          child: const Text('Resign'),
        );
        break;

      case ComputerGamePhase.awaitingPhysicalMove:
        statusContent = Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Moving computer\'s piece on the board...',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
        trailingAction = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => ref
                  .read(computerOpponentProvider.notifier)
                  .skipPhysicalWaiting(),
              child: const Text('Play on Screen'),
            ),
            TextButton(
              onPressed: () => _confirmResign(context, ref),
              child: const Text('Resign'),
            ),
          ],
        );
        break;

      case ComputerGamePhase.paused:
        statusContent = Row(
          children: [
            Icon(Icons.pause_circle_outline,
                color: colorScheme.secondary, size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Game paused'),
            ),
          ],
        );
        trailingAction = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.tonal(
              onPressed: () =>
                  ref.read(computerOpponentProvider.notifier).resumeGame(),
              child: const Text('Resume'),
            ),
            const SizedBox(width: 6),
            TextButton(
              onPressed: () => _confirmResign(context, ref),
              child: const Text('Resign'),
            ),
          ],
        );
        break;

      case ComputerGamePhase.humanTurn:
      default:
        final sideStr = opponent.humanSide.name;
        final sideLabel = sideStr[0].toUpperCase() + sideStr.substring(1);
        statusContent = Row(
          children: [
            Icon(Icons.play_circle_fill, color: colorScheme.primary, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Your turn ($sideLabel) • ${opponent.strength.label}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
        trailingAction = TextButton(
          onPressed: () => _confirmResign(context, ref),
          child: const Text('Resign'),
        );
        break;
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(child: statusContent),
          trailingAction,
        ],
      ),
    );
  }

  void _confirmResign(BuildContext context, WidgetRef ref) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resign Game?'),
        content: const Text(
          'Are you sure you want to resign this game against the computer?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop(true);
              ref.read(computerOpponentProvider.notifier).resign();
            },
            child: const Text('Resign'),
          ),
        ],
      ),
    );
  }
}
