import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../reader/state/reading_analysis.dart';

Set<Shape> readingAnalysisArrows(ReadingAnalysisState tree) {
  final cursor = tree.cursor;
  if (cursor == null) return const {};

  final arrows = <(Square, Square), Arrow>{};
  void add(int id, Color color) {
    final node = tree.nodes[id];
    final move = node.uci == null ? null : Move.parse(node.uci!);
    if (move is! NormalMove) return;
    // Dartchess can encode castling as king-to-rook in UCI.
    final target = node.label.contains('O-O-O')
        ? Square.fromCoords(File.c, move.from.rank)
        : node.label.contains('O-O')
        ? Square.fromCoords(File.g, move.from.rank)
        : move.to;
    arrows.putIfAbsent((
      move.from,
      target,
    ), () => Arrow(orig: move.from, dest: target, color: color));
  }

  add(cursor, const Color(0x994278D8));
  final children = tree.children(cursor);
  if (children.isNotEmpty) {
    add(children.first, const Color(0x992E8B57));
    for (final id in children.skip(1)) {
      add(id, const Color(0x99BD7219));
    }
  }
  return arrows.values.toSet();
}
