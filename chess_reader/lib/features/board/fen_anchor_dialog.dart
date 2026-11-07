import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/game_session.dart';
import '../reader/data/diagram_corrections.dart';
import '../reader/state/book_providers.dart';
import '../reader/state/conversion_provider.dart';
import '../reader/state/diagram_corrections_provider.dart';

/// Piece placement (first FEN field), which is all that identifies a diagram's
/// position independent of side to move, castling and move counters.
String _placement(String fen) => fen.trim().split(RegExp(r'\s+')).first;

/// "Set position here": paste a FEN to anchor the board (and, downstream,
/// move resolution) to an arbitrary position — the manual counterpart of the
/// Phase 5 diagram anchors.
///
/// When the board is still showing the diagram the user last loaded from the
/// book, the edit can also be saved as a correction of that diagram: it is
/// remembered across sessions, shown in the reading views, and included when
/// the processed book is exported.
Future<void> showFenAnchorDialog(BuildContext context, WidgetRef ref) async {
  final currentFen = ref.read(gameSessionProvider).fen;
  final controller = TextEditingController(text: currentFen);
  final openBook = ref.read(openedBookProvider);
  var diagram = ref.read(activeDiagramProvider);
  if (diagram != null &&
      (diagram.path != openBook ||
          _placement(diagram.fen) != _placement(currentFen))) {
    diagram = null; // The board has moved on from the diagram.
  }
  var remember = true;
  String? error;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Set position from FEN'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'FEN',
                  errorText: error,
                  border: const OutlineInputBorder(),
                ),
              ),
              if (diagram != null) ...[
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: remember,
                  onChanged: (v) => setState(() => remember = v ?? true),
                  title: const Text('Save as correction for this diagram'),
                  subtitle: const Text(
                    'Kept when the book is reopened and included when you '
                    'export the processed book.',
                  ),
                ),
                if (diagram.corrected)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.restore),
                      label: const Text('Reset to detected position'),
                      onPressed: () async {
                        final d = diagram!;
                        final detected = _detectedFen(ref, d);
                        if (detected == null) {
                          // Detection of this page is still running; resetting
                          // now would drop the correction but leave it shown.
                          setState(
                            () => error =
                                'Detection is still running; try again shortly.',
                          );
                          return;
                        }
                        try {
                          await ref
                              .read(diagramCorrectionsProvider(d.path).notifier)
                              .remove(d.key);
                        } catch (e) {
                          setState(() => error = 'Could not save: $e');
                          return;
                        }
                        ref
                            .read(gameSessionProvider.notifier)
                            .loadFen(detected, turnRecoverable: true);
                        ref.read(activeLineProvider.notifier).clear();
                        ref
                            .read(activeDiagramProvider.notifier)
                            .set(
                              ActiveDiagram(
                                path: d.path,
                                key: d.key,
                                fen: detected,
                                corrected: false,
                              ),
                            );
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final fen = controller.text.trim();
              final ok = ref.read(gameSessionProvider.notifier).loadFen(fen);
              if (!ok) {
                setState(() => error = 'Invalid FEN');
                return;
              }
              ref.read(activeLineProvider.notifier).clear();
              final d = diagram;
              if (d != null && remember) {
                try {
                  await ref
                      .read(diagramCorrectionsProvider(d.path).notifier)
                      .set(d.key, fen);
                } catch (e) {
                  // The board shows the edit, but it would be lost on reopen.
                  setState(() => error = 'Position set, but not saved: $e');
                  return;
                }
                ref
                    .read(activeDiagramProvider.notifier)
                    .set(
                      ActiveDiagram(
                        path: d.path,
                        key: d.key,
                        fen: fen,
                        corrected: true,
                      ),
                    );
              } else {
                // The board no longer shows that diagram.
                ref.read(activeDiagramProvider.notifier).set(null);
              }
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Set position'),
          ),
        ],
      ),
    ),
  );
}

/// What the detector originally read for [d], from the uncorrected conversion.
String? _detectedFen(WidgetRef ref, ActiveDiagram d) {
  final raw = ref.read(conversionProvider(d.path)).value;
  if (raw == null) return null;
  for (final page in raw.pages) {
    for (final diagram in page.diagrams) {
      if (diagramKey(page.index, diagram) == d.key) return diagram.fen;
    }
  }
  return null;
}
