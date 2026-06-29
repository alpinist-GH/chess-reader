/// A chess move detected in book text, before legality resolution.
class MoveToken {
  const MoveToken({
    required this.san,
    required this.start,
    required this.end,
    this.moveNumber,
    this.isWhiteHint,
    this.isDescriptive = false,
  });

  /// Normalized SAN (figurines already mapped to letters), suffixes like
  /// `!?` stripped, e.g. `Nf3`, `exd5`, `O-O`, `e8=Q+`.
  ///
  /// When [isDescriptive] is true this instead holds the raw English
  /// descriptive move (`P-K4`, `Kt-QB3`, `PxQP`, `Castles`), which the resolver
  /// converts against the live board rather than via [Position.parseSan].
  final String san;

  /// Offset range in the ORIGINAL (un-normalized) text, so the UI can place
  /// tap targets over exactly what the book shows.
  final int start;
  final int end;

  /// Move number from the closest preceding number marker (`12.` / `12...`),
  /// if any. Used by the resolver as a resync hint.
  final int? moveNumber;

  /// True when the token followed `12.`, false after `12...`, null when the
  /// color cannot be inferred from the text.
  final bool? isWhiteHint;

  /// True when [san] holds an English-descriptive move rather than algebraic SAN.
  final bool isDescriptive;

  @override
  String toString() =>
      'MoveToken($san @$start-$end, n=$moveNumber, white=$isWhiteHint'
      '${isDescriptive ? ', descriptive' : ''})';
}
