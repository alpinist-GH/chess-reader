import 'ocr_box.dart';

/// Joins recognized text lines into a single page string in reading order.
///
/// The detector returns line boxes in arbitrary order. We group them into
/// visual rows (boxes whose vertical spans overlap belong to the same row),
/// order rows top→bottom and lines within a row left→right, then join. A wide
/// vertical gap between consecutive rows becomes a blank line so the HTML
/// builder's `_formatText` renders a paragraph break (`\n{2,}` → `<p>`); narrow
/// gaps become single newlines (wrapped lines, collapsed to spaces downstream).
String linesToPageText(List<RecognizedLine> lines) {
  final kept = [
    for (final l in lines)
      if (l.text.trim().isNotEmpty) l
  ];
  if (kept.isEmpty) return '';

  // Group into rows by vertical overlap (greedy over y-sorted lines).
  kept.sort((a, b) => a.box.top.compareTo(b.box.top));
  final rows = <List<RecognizedLine>>[];
  for (final line in kept) {
    final row = rows.isEmpty ? null : rows.last;
    if (row != null && _verticallyOverlaps(row, line.box)) {
      row.add(line);
    } else {
      rows.add([line]);
    }
  }

  // Median line height drives the paragraph-gap threshold, so it scales with
  // the page's font size rather than a hard-coded pixel count.
  final heights = [for (final l in kept) l.box.height]..sort();
  final medianHeight = heights[heights.length ~/ 2];
  final paragraphGap = medianHeight * 1.2;

  final buf = StringBuffer();
  double? prevBottom;
  for (final row in rows) {
    row.sort((a, b) => a.box.left.compareTo(b.box.left));
    final top = row.map((l) => l.box.top).reduce((a, b) => a < b ? a : b);
    if (prevBottom != null) {
      buf.write(top - prevBottom > paragraphGap ? '\n\n' : '\n');
    }
    buf.write([for (final l in row) l.text.trim()].join(' '));
    prevBottom = row.map((l) => l.box.bottom).reduce((a, b) => a > b ? a : b).toDouble();
  }
  return buf.toString();
}

/// Whether [box] shares vertical extent with any line already in [row].
bool _verticallyOverlaps(List<RecognizedLine> row, TextBox box) {
  for (final l in row) {
    final overlap =
        (l.box.bottom < box.bottom ? l.box.bottom : box.bottom) -
            (l.box.top > box.top ? l.box.top : box.top);
    // Require the overlap to cover a third of the shorter line, so two stacked
    // lines that merely touch are not merged into one row.
    final shorter = l.box.height < box.height ? l.box.height : box.height;
    if (overlap > shorter / 3) return true;
  }
  return false;
}
