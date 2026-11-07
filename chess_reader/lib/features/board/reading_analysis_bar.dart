import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../reader/state/reading_analysis.dart';
import '../reader/state/book_providers.dart';

class ReadingAnalysisBar extends ConsumerWidget {
  const ReadingAnalysisBar({super.key, this.compact = false});

  /// Leaves branch choices to the arrows and Saved lines, for a short panel.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tree = ref.watch(readingAnalysisProvider);
    final cursor = tree.cursor;
    if (cursor == null) return const SizedBox.shrink();
    final actions = ref.read(readingAnalysisProvider.notifier);
    final children = tree.children(cursor);
    final parent = tree.nodes[cursor].parent;
    final siblings = parent == null ? const <int>[] : tree.children(parent);
    void select(int id) {
      ref.read(activeLineProvider.notifier).clear();
      actions.select(id);
    }

    // Stays within two short rows: the phone board panel has little height.
    final hasBranches =
        !compact && (siblings.length > 1 || children.length > 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ScrollingRow(
          children: [
            IconButton(
              tooltip: 'Previous saved move',
              icon: const Icon(Icons.chevron_left),
              visualDensity: VisualDensity.compact,
              onPressed: parent == null ? null : () => select(parent),
            ),
            TextButton.icon(
              icon: const Icon(Icons.account_tree_outlined),
              label: const Text('Saved lines'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _SavedLinesDialog(),
              ),
            ),
            IconButton(
              tooltip: 'Next saved move',
              icon: const Icon(Icons.chevron_right),
              visualDensity: VisualDensity.compact,
              onPressed: children.isEmpty ? null : () => select(children.first),
            ),
            TextButton.icon(
              icon: const Icon(Icons.keyboard_return),
              label: const Text('Return to main line'),
              onPressed: tree.main == null || tree.main == cursor
                  ? null
                  : () {
                      ref.read(activeLineProvider.notifier).clear();
                      actions.backToMain();
                    },
            ),
          ],
        ),
        if (hasBranches)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ScrollingRow(
              children: [
                if (siblings.length > 1)
                  ..._branchChoices(
                    context,
                    'Alternatives',
                    siblings,
                    tree,
                    select,
                  ),
                if (children.isNotEmpty)
                  ..._branchChoices(
                    context,
                    children.length > 1 ? 'Branches' : 'Continue',
                    children,
                    tree,
                    select,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _branchChoices(
    BuildContext context,
    String label,
    List<int> ids,
    ReadingAnalysisState tree,
    ValueChanged<int> onSelect,
  ) => [
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text('$label:', style: Theme.of(context).textTheme.labelMedium),
    ),
    for (var i = 0; i < ids.length; i++)
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(
            '${tree.nodes[ids[i]].label}${ids.length > 1
                ? i == 0
                      ? ' · Main'
                      : ' · Variation'
                : ''}',
          ),
          selected: tree.cursor == ids[i],
          onSelected: (_) => onSelect(ids[i]),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
  ];
}

/// One centered row that scrolls sideways instead of wrapping when too wide.
class ScrollingRow extends StatelessWidget {
  const ScrollingRow({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: children,
        ),
      ),
    ),
  );
}

class _SavedLinesDialog extends ConsumerWidget {
  const _SavedLinesDialog();

  String _formatLocation(String location, {required bool isEpub}) {
    if (location.startsWith('int:')) {
      return '${isEpub ? 'Chapter' : 'Page'} ${location.substring(4)}';
    }
    if (location.startsWith('String:pg')) {
      final idx = int.tryParse(location.substring(9));
      return 'Page ${idx != null ? idx + 1 : location.substring(9)}';
    }
    if (location.startsWith('String:ch')) {
      final idx = int.tryParse(location.substring(9));
      return 'Chapter ${idx != null ? idx + 1 : location.substring(9)}';
    }
    return location;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tree = ref.watch(readingAnalysisProvider);
    final isEpub =
        ref.watch(openedBookProvider)?.toLowerCase().endsWith('.epub') ?? false;
    final rows = <(int, int)>[];
    void visit(int id, int depth) {
      rows.add((id, depth));
      for (final child in tree.children(id)) {
        visit(child, depth + 1);
      }
    }

    for (var i = 0; i < tree.nodes.length; i++) {
      if (tree.nodes[i].parent == null) visit(i, 0);
    }
    return AlertDialog(
      title: const Text('Saved lines'),
      content: SizedBox(
        width: 440,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Moves are saved automatically in this book. Select any move to resume that line.',
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final (id, depth) = rows[index];
                  final node = tree.nodes[id];
                  final siblings = node.parent == null
                      ? const <int>[]
                      : tree.children(node.parent!);
                  return Padding(
                    padding: EdgeInsets.only(
                      left: (depth.clamp(0, 8) * 12).toDouble(),
                    ),
                    child: ListTile(
                      dense: true,
                      selected: tree.cursor == id,
                      leading: Icon(
                        node.parent == null
                            ? Icons.menu_book
                            : siblings.first == id
                            ? Icons.arrow_downward
                            : Icons.call_split,
                      ),
                      title: Text(node.label),
                      subtitle: node.parent == null
                          ? Text(_formatLocation(node.location, isEpub: isEpub))
                          : tree.main == id
                          ? const Text('Main-line return point')
                          : null,
                      trailing: tree.cursor == id
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () {
                        ref.read(activeLineProvider.notifier).clear();
                        ref.read(readingAnalysisProvider.notifier).select(id);
                        Navigator.of(context).pop();
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
