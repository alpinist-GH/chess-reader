/// Chessnut board families that share the same BLE protocol and app.
///
/// Only the Move has motors. Go, Evo and Air report piece positions and light
/// squares, but the player moves the pieces by hand.
enum ChessnutBoardModel {
  move('Chessnut Move', canMovePieces: true),
  go('Chessnut Go', canMovePieces: false),
  evo('Chessnut Evo', canMovePieces: false),
  air('Chessnut Air', canMovePieces: false),

  /// An advertised name that names no known model. It keeps the original
  /// Move behavior so existing boards are unaffected by the model detection.
  unknown('Chessnut', canMovePieces: true);

  const ChessnutBoardModel(this.displayName, {required this.canMovePieces});

  final String displayName;

  /// Whether the board can physically move its own pieces.
  final bool canMovePieces;

  /// Go, Evo and Air have not been verified on hardware yet.
  bool get isExperimental => this == go || this == evo || this == air;

  /// The Go lights squares with the 8-byte row bitmap (`0A 08`) on the command
  /// characteristic and ignores the Move/Evo `43 20` command. Verified on a
  /// Chessnut Go; the Air is untested and keeps the `43 20` command.
  bool get usesBitmapLeds => this == go;

  static ChessnutBoardModel fromAdvertisedName(String? name) {
    final lower = (name ?? '').toLowerCase();
    if (lower.contains('move')) return move;
    if (lower.contains('evo')) return evo;
    if (lower.contains('air')) return air;
    if (RegExp(r'(^|[^a-z])go($|[^a-z])').hasMatch(lower)) return go;
    return unknown;
  }
}

/// Whether a Bluetooth advertisement belongs to a Chessnut board: every model
/// advertises a name that starts with "Chessnut", and boards also advertise
/// their position service. Phones, watches and trackers match neither.
bool isChessnutAdvertisement({
  String? name,
  String? rawName,
  List<String> services = const [],
}) {
  bool named(String? value) =>
      value != null && value.toLowerCase().contains('chessnut');
  if (named(name) || named(rawName)) return true;
  const service = '1b7e8261287741c3b46ecf057c562023';
  return services.any(
    (uuid) => uuid.replaceAll('-', '').toLowerCase() == service,
  );
}
