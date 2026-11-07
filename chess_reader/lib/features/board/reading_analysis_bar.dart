import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../reader/state/reading_analysis.dart';
import '../reader/state/book_providers.dart';

class ReadingAnalysisBar extends ConsumerWidget {
  const ReadingAnalysisBar({super.key});

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

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              tooltip: 'Previous saved move',
              icon: const Icon(Icons.chevron_left),
              onPressed: tree.nodes[cursor].parent == null
                  ? null
                  : () => select(tree.nodes[cursor].parent!),
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
        if (siblings.length > 1)
          _BranchChoices(
            label: 'Alternatives',
            ids: siblings,
            tree: tree,
            onSelect: select,
          ),
        if (children.isNotEmpty)
          _BranchChoices(
            label: children.length > 1 ? 'Branches' : 'Continue',
            ids: children,
            tree: tree,
            onSelect: select,
          ),
      ],
    );
  }
}

class _BranchChoices extends StatelessWidget {
  const _BranchChoices({
    required this.label,
    required this.ids,
    required this.tree,
    required this.onSelect,
  });
  final String label;
  final List<int> ids;
  final ReadingAnalysisState tree;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('$label:', style: Theme.of(context).textTheme.labelMedium),
        for (var i = 0; i < ids.length; i++)
          ChoiceChip(
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
          ),
      ],
    ),
  );
}

class _SavedLinesDialog extends ConsumerWidget {
  const _SavedLinesDialog();

  String _formatLocation(String location) {
    if (location.startsWith('int:')) {
      return 'Page ${location.substring(4)}';
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
                          ? Text(_formatLocation(node.location))
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
