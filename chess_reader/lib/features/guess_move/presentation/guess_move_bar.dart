import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/guess_move_models.dart';
import '../state/guess_move_provider.dart';

class GuessMoveBar extends ConsumerWidget {
  const GuessMoveBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guess = ref.watch(guessMoveProvider);
    if (guess.phase == GuessMovePhase.idle) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final isCorrect = guess.phase == GuessMovePhase.correct;
    final isActive = guess.phase == GuessMovePhase.active;
    final color = isCorrect
        ? colorScheme.secondaryContainer
        : isActive
        ? colorScheme.surfaceContainerHighest
        : colorScheme.errorContainer;
    final onColor = isCorrect
        ? colorScheme.onSecondaryContainer
        : isActive
        ? colorScheme.onSurfaceVariant
        : colorScheme.onErrorContainer;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isCorrect ? Icons.check_circle : Icons.school,
                color: onColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isActive
                      ? (guess.feedback ?? 'Find the next move')
                      : (guess.feedback ?? ''),
                  style: TextStyle(color: onColor, fontWeight: FontWeight.w600),
                ),
              ),
              if (guess.phase == GuessMovePhase.incorrect)
                TextButton(
                  onPressed: () => ref.read(guessMoveProvider.notifier).retry(),
                  child: Text('Try again', style: TextStyle(color: onColor)),
                ),
              if (guess.isFinished)
                TextButton(
                  onPressed: () =>
                      ref.read(guessMoveProvider.notifier).dismiss(),
                  child: Text('Close', style: TextStyle(color: onColor)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Score ${guess.score} · ${guess.correctMoves} correct · '
            '${guess.attempts} misses · ${guess.hintsUsed} hints',
            style: TextStyle(color: onColor, fontSize: 12),
          ),
          if (guess.hint != null)
            Text(guess.hint!, style: TextStyle(color: onColor, fontSize: 12)),
          if (guess.canRequestHint)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () =>
                    ref.read(guessMoveProvider.notifier).requestHint(),
                icon: const Icon(Icons.lightbulb_outline, size: 18),
                label: const Text('Hint'),
              ),
            ),
        ],
      ),
    );
  }
}
