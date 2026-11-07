import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/game_session.dart';
import '../reader/state/book_providers.dart';

/// "Set position here": paste a FEN to anchor the board (and, downstream,
/// move resolution) to an arbitrary position — the manual counterpart of the
/// Phase 5 diagram anchors.
Future<void> showFenAnchorDialog(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController(
    text: ref.read(gameSessionProvider).fen,
  );
  String? error;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Set position from FEN'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: 'FEN',
              errorText: error,
              border: const OutlineInputBorder(),
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
              final ok = ref
                  .read(gameSessionProvider.notifier)
                  .loadFen(controller.text.trim());
              if (ok) {
                ref.read(activeLineProvider.notifier).clear();
                Navigator.of(context).pop();
              } else {
                setState(() => error = 'Invalid FEN');
              }
            },
            child: const Text('Set position'),
          ),
        ],
      ),
    ),
  );
}
