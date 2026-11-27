import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../reader/state/book_providers.dart';
import '../reader/state/reading_analysis.dart';

void _selectMove(WidgetRef ref, int id) {
  ref.read(activeLineProvider.notifier).clear();
  ref.read(readingAnalysisProvider.notifier).select(id);
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

class ReadingAnalysisPanel extends ConsumerStatefulWidget {
  const ReadingAnalysisPanel({super.key});

  @override
  ConsumerState<ReadingAnalysisPanel> createState() =>
      _ReadingAnalysisPanelState();
}

enum _MoveAction { promote, delete }

enum _AnalysisAction { start, main, copy, clear }

class _ReadingAnalysisPanelState extends ConsumerState<ReadingAnalysisPanel> {
  final _selectedKey = GlobalKey();
  String? _sideError;

  void _revealSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _selectedKey.currentContext;
      if (target != null) Scrollable.ensureVisible(target, alignment: 0.25);
    });
  }

  String _formatLocation(String location, {required bool isEpub}) {
    if (location.startsWith('Diagram:')) {
      final page = location.substring('Diagram:'.length).split(':').first;
      return int.tryParse(page) == null
          ? 'Book diagram'
          : 'Diagram · ${isEpub ? 'Chapter' : 'Page'} $page';
    }
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

  Future<bool> _confirm(String title, String description, String action) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(description),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  void initState() {
    super.initState();
    _revealSelection();
  }

  @override
  Widget build(BuildContext context) {
    final tree = ref.watch(readingAnalysisProvider);
    final cursor = tree.cursor;
    if (cursor == null) return const SizedBox.shrink();
    ref.listen(readingAnalysisProvider.select((tree) => tree.cursor), (_, _) {
      _revealSelection();
    });
    final actions = ref.read(readingAnalysisProvider.notifier);
    final isEpub =
        ref.watch(openedBookProvider)?.toLowerCase().endsWith('.epub') ?? false;
    final root = tree.root;
    final children = <int, List<int>>{};
    for (var id = 0; id < tree.nodes.length; id++) {
      final parent = tree.nodes[id].parent;
      if (parent != null) (children[parent] ??= []).add(id);
    }
    final hasMoves = children.containsKey(root);
    final location = tree.nodes[root].location;
    final editableSide =
        location == 'FEN' ||
        location == 'Diagram / position' ||
        location.startsWith('Diagram:');
    final startingSide = Setup.parseFen(tree.nodes[root].fen).turn;
    final mainLine = <int>{root};
    var main = root;
    while (children.containsKey(main)) {
      main = children[main]!.first;
      mainLine.add(main);
    }

    Widget move(int id, {required bool first, required bool rootMove}) {
      final node = tree.nodes[id];
      final notation = RegExp(r'^(\d+\.{1,3})(.+)$').firstMatch(node.label);
      final label = notation == null
          ? node.label
          : first || notation[1]!.endsWith('.') && !notation[1]!.endsWith('...')
          ? '${notation[1]} ${notation[2]}'
          : notation[2]!;
      return Row(
        key: id == cursor ? _selectedKey : null,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                backgroundColor: id == cursor
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : null,
                foregroundColor: id == cursor
                    ? Theme.of(context).colorScheme.onSecondaryContainer
                    : null,
              ),
              onPressed: () => _selectMove(ref, id),
              child: Text(label),
            ),
          ),
          if (!rootMove)
            PopupMenuButton<_MoveAction>(
              tooltip: 'Options for ${node.label}',
              iconSize: 17,
              padding: EdgeInsets.zero,

              itemBuilder: (_) => [
                if (!mainLine.contains(id))
                  const PopupMenuItem(
                    value: _MoveAction.promote,
                    child: Text('Promote to main line'),
                  ),
                PopupMenuItem(
                  value: _MoveAction.delete,
                  child: Text(
                    children.containsKey(id)
                        ? 'Delete move and continuation'
                        : 'Delete move',
                  ),
                ),
              ],
              onSelected: (action) async {
                if (action == _MoveAction.promote) {
                  actions.promoteToMain(id);
                  _revealSelection();
                  return;
                }
                if (children.containsKey(id) &&
                    !await _confirm(
                      'Delete move and continuation?',
                      'This removes ${node.label} and every move played after it in this branch.',
                      'Delete',
                    )) {
                  return;
                }
                if (mounted &&
                    identical(
                      ref.read(readingAnalysisProvider).nodes,
                      tree.nodes,
                    )) {
                  actions.deleteMove(id);
                  _revealSelection();
                }
              },
            ),
        ],
      );
    }

    final rows = <Widget>[move(root, first: true, rootMove: true)];
    void addLine(int id, int depth, {int? variation}) {
      final run = <int>[];
      var current = id;
      while (true) {
        run.add(current);
        final next = children[current];
        if (next == null || next.length != 1) break;
        current = next.first;
      }
      rows.add(
        Padding(
          padding: EdgeInsets.only(left: depth.clamp(0, 5) * 12.0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: depth == 0
                  ? null
                  : Border(
                      left: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
            ),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (variation != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      'V$variation',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                for (var i = 0; i < run.length; i++)
                  move(run[i], first: i == 0, rootMove: false),
              ],
            ),
          ),
        ),
      );
      final next = children[current];
      if (next == null) return;
      for (final alternative in next.skip(1)) {
        addLine(
          alternative,
          depth + 1,
          variation: tree.nodes[alternative].variation,
        );
      }
      addLine(next.first, depth);
    }

    final firstMoves = children[root];
    if (firstMoves != null) {
      for (final alternative in firstMoves.skip(1)) {
        addLine(alternative, 1, variation: tree.nodes[alternative].variation);
      }
      addLine(firstMoves.first, 0);
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButton<int>(
                    value: root,
                    isExpanded: true,
                    items: [
                      for (var id = 0; id < tree.nodes.length; id++)
                        if (tree.nodes[id].parent == null)
                          DropdownMenuItem(
                            value: id,
                            child: Text(
                              '${tree.nodes[id].label} · ${_formatLocation(tree.nodes[id].location, isEpub: isEpub)}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                    ],
                    onChanged: (id) {
                      if (id != null) {
                        setState(() => _sideError = null);
                        _selectMove(ref, id);
                      }
                    },
                  ),
                ),
                PopupMenuButton<_AnalysisAction>(
                  tooltip: 'Analysis actions',
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _AnalysisAction.start,
                      enabled: cursor != root,
                      child: const Text('Go to start'),
                    ),
                    PopupMenuItem(
                      value: _AnalysisAction.main,
                      enabled: tree.main != null && cursor != tree.main,
                      child: const Text('Main line'),
                    ),
                    PopupMenuItem(
                      value: _AnalysisAction.copy,
                      enabled: hasMoves,
                      child: const Text('Copy PGN'),
                    ),
                    PopupMenuItem(
                      value: _AnalysisAction.clear,
                      enabled: hasMoves,
                      child: const Text('Clear analysis…'),
                    ),
                  ],
                  onSelected: (action) async {
                    if (!mounted ||
                        !identical(ref.read(readingAnalysisProvider), tree)) {
                      return;
                    }
                    switch (action) {
                      case _AnalysisAction.start:
                        _selectMove(ref, root);
                      case _AnalysisAction.main:
                        _selectMove(ref, tree.main!);
                      case _AnalysisAction.copy:
                        await Clipboard.setData(
                          ClipboardData(text: actions.exportPgn()),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            const SnackBar(content: Text('PGN copied')),
                          );
                        }
                      case _AnalysisAction.clear:
                        if (await _confirm(
                              'Clear analysis?',
                              'All moves and variations for this starting position will be removed.',
                              'Clear',
                            ) &&
                            mounted &&
                            identical(
                              ref.read(readingAnalysisProvider),
                              tree,
                            )) {
                          actions.clearAnalysis();
                        }
                    }
                  },
                ),
              ],
            ),
            if (editableSide)
              Row(
                children: [
                  const Expanded(child: Text('Starting side to move')),
                  DropdownButton<Side>(
                    value: startingSide,
                    items: const [
                      DropdownMenuItem(value: Side.white, child: Text('White')),
                      DropdownMenuItem(value: Side.black, child: Text('Black')),
                    ],
                    onChanged: (side) {
                      if (side == null || side == startingSide) return;
                      ref.read(activeLineProvider.notifier).clear();
                      final changed = actions.setStartingSide(side);
                      setState(() {
                        _sideError = changed
                            ? null
                            : '${side == Side.white ? 'White' : 'Black'} cannot move first in this position.';
                      });
                    },
                  ),
                ],
              ),
            if (editableSide && _sideError != null) Text(_sideError!),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: rows,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
