import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../guess_move/domain/guess_move_models.dart';
import '../state/book_providers.dart';
import '../../guess_move/state/guess_move_provider.dart';

/// Horizontal strip showing the moves detected on the active page, with
/// previous/next stepping. SAN is shown in plain letters here; inline piece
/// images replace the letters in a later phase.
class MoveStrip extends ConsumerWidget {
  const MoveStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeLineProvider);
    if (active == null) {
      return const SizedBox.shrink();
    }
    final notifier = ref.read(activeLineProvider.notifier);
    final guessing = ref.watch(guessMoveProvider).phase != GuessMovePhase.idle;

    return Row(
      children: [
        IconButton(
          tooltip: 'Previous move',
          icon: const Icon(Icons.chevron_left),
          onPressed: !guessing && active.hasPrevious ? notifier.previous : null,
        ),
        Expanded(
          child: SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: active.moves.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (context, i) {
                final token = active.moves[i].token;
                final label = token.moveNumber != null
                    ? (token.isWhiteHint == false
                          ? '${token.moveNumber}...${token.san}'
                          : '${token.moveNumber}.${token.san}')
                    : token.san;
                return ChoiceChip(
                  label: Text(label),
                  selected: i == active.index,
                  visualDensity: VisualDensity.compact,
                  onSelected: guessing
                      ? null
                      : (_) =>
                            notifier.select(active.moves, i, active.sourceKey),
                );
              },
            ),
          ),
        ),
        IconButton(
          tooltip: 'Next move',
          icon: const Icon(Icons.chevron_right),
          onPressed: !guessing && active.hasNext ? notifier.next : null,
        ),
      ],
    );
  }
}
