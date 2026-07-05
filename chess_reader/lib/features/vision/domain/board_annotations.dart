/// Training annotations recovered from a book diagram: arrows drawn over the
/// board and marked squares (the "x" crosses of move-illustration diagrams).
///
/// Encoded as one compact, attribute-safe string ("Ae2e4;Df3g5;Xd5") that is
/// reused verbatim across the conversion cache JSON (`ann` key), the reader
/// HTML (`ann="..."` on `<chessdiagram>`), and in-memory transfer.
library;

enum BoardAnnotationKind { arrow, dashedArrow, mark }

/// One annotation over cells in the pipeline's row-major-from-a8 order
/// (cell 0 = a8, 7 = h8, 56 = a1, 63 = h1 — same indexing as the 64 labels).
class BoardAnnotation {
  const BoardAnnotation(this.kind, this.from, this.to)
      : assert(from >= 0 && from < 64 && to >= 0 && to < 64);

  const BoardAnnotation.mark(int cell)
      : this(BoardAnnotationKind.mark, cell, cell);

  final BoardAnnotationKind kind;

  /// For [BoardAnnotationKind.mark], `to == from`.
  final int from;
  final int to;

  @override
  bool operator ==(Object other) =>
      other is BoardAnnotation &&
      other.kind == kind &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(kind, from, to);

  @override
  String toString() => encodeAnnotations([this]);
}

String _squareName(int cell) {
  final file = cell % 8;
  final rank = 8 - cell ~/ 8;
  return '${String.fromCharCode(0x61 + file)}$rank';
}

int? _cellOf(String s) {
  if (s.length != 2) return null;
  final file = s.codeUnitAt(0) - 0x61;
  final rank = s.codeUnitAt(1) - 0x31;
  if (file < 0 || file > 7 || rank < 0 || rank > 7) return null;
  return (7 - rank) * 8 + file;
}

/// "Ae2e4;Df3g5;Xd5" — A = arrow, D = dashed arrow, X = marked square.
String encodeAnnotations(List<BoardAnnotation> annotations) =>
    annotations.map((a) => switch (a.kind) {
          BoardAnnotationKind.arrow =>
            'A${_squareName(a.from)}${_squareName(a.to)}',
          BoardAnnotationKind.dashedArrow =>
            'D${_squareName(a.from)}${_squareName(a.to)}',
          BoardAnnotationKind.mark => 'X${_squareName(a.from)}',
        }).join(';');

/// Tolerant inverse of [encodeAnnotations]: malformed tokens are dropped, so a
/// hand-edited or truncated attribute degrades to fewer annotations rather
/// than an error.
List<BoardAnnotation> decodeAnnotations(String encoded) {
  final out = <BoardAnnotation>[];
  for (final token in encoded.split(';')) {
    if (token.isEmpty) continue;
    final kind = switch (token[0]) {
      'A' => BoardAnnotationKind.arrow,
      'D' => BoardAnnotationKind.dashedArrow,
      'X' => BoardAnnotationKind.mark,
      _ => null,
    };
    if (kind == null) continue;
    final body = token.substring(1);
    if (kind == BoardAnnotationKind.mark) {
      final cell = _cellOf(body);
      if (cell != null) out.add(BoardAnnotation(kind, cell, cell));
    } else if (body.length == 4) {
      final from = _cellOf(body.substring(0, 2));
      final to = _cellOf(body.substring(2, 4));
      if (from != null && to != null && from != to) {
        out.add(BoardAnnotation(kind, from, to));
      }
    }
  }
  return out;
}
