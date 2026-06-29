import 'package:dartchess/dartchess.dart';

/// Resolves a single move written in **English descriptive notation** (the
/// pre-1980 style used in older books: `P-K4`, `Kt-QB3`, `B-KKt5`, `PxQP`,
/// `Castles`) into a concrete [Move] against a live [Position].
///
/// Descriptive notation is fundamentally board-relative and ambiguous on its
/// own — `K4` is e4 for White but e5 for Black, and `PxP` only names *which*
/// capture once you know the position — so unlike algebraic SAN it cannot be
/// parsed without the board. The strategy here mirrors how a human reads it:
/// translate the move into a set of constraints (piece moved, destination
/// file/rank, what was captured) and keep the single legal move that satisfies
/// them. If zero or more than one legal move matches, we give up (null) rather
/// than guess — the caller treats that as unresolved, and a wrong move is worse
/// than a missing one.
class DescriptiveNotation {
  DescriptiveNotation._();

  /// Files are named from White's side and are the same for both players:
  /// QR=a … KR=h. A short name (`R`, `Kt`, `B`) is ambiguous between the
  /// queen's- and king's-side file, so it maps to a set; legality disambiguates.
  static const Map<String, Set<int>> _fileSets = {
    'QR': {0}, 'QKT': {1}, 'QN': {1}, 'QB': {2}, 'Q': {3},
    'K': {4}, 'KB': {5}, 'KKT': {6}, 'KN': {6}, 'KR': {7},
    'R': {0, 7}, 'KT': {1, 6}, 'N': {1, 6}, 'B': {2, 5},
  };

  /// File tokens to try when reading the leading file of a square, longest
  /// first so `QKt` wins over `Q`.
  static const List<String> _fileTokensByLength = [
    'QKT', 'QKN', 'KKT', 'KKN', 'QN', 'KN', 'QR', 'QB', 'KR', 'KB', 'KT', 'N',
    'Q', 'K', 'R', 'B',
  ];

  /// Returns the move for [raw] in [pos], or null if it is not a descriptive
  /// move or cannot be resolved unambiguously.
  static Move? toMove(Position pos, String raw) {
    final move = _clean(raw);
    if (move == null) return null;

    final castle = _castle(pos, move);
    if (castle != null) return castle;

    return _resolveMove(pos, move);
  }

  /// Normalizes a candidate token: strips check/mate/e.p. suffixes, removes
  /// spaces, collapses repeated dashes, upper-cases. Returns null for clearly
  /// non-move text.
  static String? _clean(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    // Drop trailing annotations: "ch", "dis ch", "dbl ch", "mate", "+", "#",
    // "e.p.", "!", "?".
    s = s.replaceAll(RegExp(r'\s*(?:e\.?p\.?|dbl\s*ch|dis\.?\s*ch|ch|mate)\b',
        caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'[+#!?]+$'), '');
    s = s.replaceAll(RegExp(r'\s+'), '');
    s = s.replaceAll('×', 'x');
    s = s.replaceAll(RegExp(r'-{2,}'), '-');
    s = s.toUpperCase();
    return s.isEmpty ? null : s;
  }

  static Move? _castle(Position pos, String move) {
    final m = move.replaceAll('0', 'O');
    final isCastle = m == 'CASTLES' ||
        m.startsWith('CASTLES') ||
        m == 'O-O' ||
        m == 'O-O-O';
    if (!isCastle) return null;
    bool? queenside;
    if (m == 'O-O-O' || m.contains('QR') || m.endsWith('Q')) {
      queenside = true;
    } else if (m == 'O-O' || m.contains('KR') || m.endsWith('K')) {
      queenside = false;
    }
    // Bare "Castles": prefer kingside (the historical default), fall back to
    // whichever is actually legal.
    final kingside = pos.parseSan('O-O');
    final queen = pos.parseSan('O-O-O');
    if (queenside == true) return queen;
    if (queenside == false) return kingside;
    return kingside ?? queen;
  }

  static Move? _resolveMove(Position pos, String move) {
    final sep = move.contains('X')
        ? 'X'
        : move.contains('-')
            ? '-'
            : null;
    if (sep == null) return null;
    final parts = move.split(sep);
    if (parts.length != 2) return null;

    final mover = _piece(parts[0]);
    if (mover == null) return null;

    // Trailing promotion: "P-Q8=Q" or "P-Q8(Q)".
    var rhs = parts[1];
    Role? promotion;
    final promoMatch =
        RegExp(r'(?:=|\()(KT|N|Q|R|B)\)?$').firstMatch(rhs);
    if (promoMatch != null) {
      promotion = _roleFromLetter(promoMatch.group(1)!);
      rhs = rhs.substring(0, promoMatch.start);
    }

    if (sep == '-') {
      final dest = _square(rhs);
      if (dest == null) return null;
      return _match(pos, mover,
          destFiles: dest.$1, destRank: dest.$2, promotion: promotion);
    } else {
      // Capture: the right-hand side names the captured piece (and maybe its
      // file), e.g. "QP", "Kt", "KtP", "R".
      final captured = _piece(rhs);
      if (captured == null) return null;
      return _match(pos, mover,
          capture: true,
          capturedRole: captured.role,
          capturedFiles: captured.files,
          promotion: promotion);
    }
  }

  /// Finds the unique legal move matching the given constraints. [mover]
  /// constrains the moving piece (role, and optionally its origin file).
  static Move? _match(
    Position pos,
    _Piece mover, {
    Set<int>? destFiles,
    int? destRank,
    bool capture = false,
    Role? capturedRole,
    Set<int>? capturedFiles,
    Role? promotion,
  }) {
    final white = pos.turn == Side.white;
    final found = <Move>[];

    pos.legalMoves.forEach((from, dests) {
      final role = pos.board.roleAt(from);
      if (role != mover.role) return;
      if (mover.files != null && !mover.files!.contains(from & 7)) return;

      for (final to in dests.squares) {
        final toFile = to & 7;
        final toRank = to >> 3;
        final isPromotion = role == Role.pawn && (toRank == 7 || toRank == 0);
        final isCapture =
            pos.board.pieceAt(to) != null || (role == Role.pawn && (from & 7) != toFile);

        if (capture) {
          if (!isCapture) continue;
          final capRole =
              pos.board.roleAt(to) ?? Role.pawn; // pawn => en passant
          if (capturedRole != null && capRole != capturedRole) continue;
          if (capturedFiles != null && !capturedFiles.contains(toFile)) continue;
        } else {
          if (destFiles != null && !destFiles.contains(toFile)) continue;
          // Descriptive ranks count from the mover's own side.
          final descRank = white ? toRank + 1 : 8 - toRank;
          if (destRank != null && descRank != destRank) continue;
        }

        if (isPromotion) {
          final promo = promotion ?? Role.queen;
          found.add(NormalMove(from: from, to: to, promotion: promo));
        } else {
          if (promotion != null) continue;
          found.add(NormalMove(from: from, to: to));
        }
      }
    });

    return found.length == 1 ? found.first : null;
  }

  /// Parses a piece designator, optionally qualified by side or file, e.g.
  /// `P`, `Kt`, `QKt`, `KB`, `KP` (king's pawn), `QP`, `KtP`. The [_Piece.files]
  /// set constrains the relevant file (origin for a mover, target for a capture);
  /// null means unconstrained.
  static _Piece? _piece(String s) {
    if (s.isEmpty) return null;
    if (s == 'P') return const _Piece(Role.pawn, null);
    if (s.endsWith('P')) {
      // (file?)P — a pawn, possibly named by its file.
      return _Piece(Role.pawn, _fileSets[s.substring(0, s.length - 1)]);
    }
    switch (s) {
      case 'K':
        return const _Piece(Role.king, null);
      case 'Q':
        return const _Piece(Role.queen, null);
      case 'R':
        return const _Piece(Role.rook, null);
      case 'B':
        return const _Piece(Role.bishop, null);
      case 'KT':
      case 'N':
        return const _Piece(Role.knight, null);
      case 'KR':
        return const _Piece(Role.rook, {7});
      case 'QR':
        return const _Piece(Role.rook, {0});
      case 'KB':
        return const _Piece(Role.bishop, {5});
      case 'QB':
        return const _Piece(Role.bishop, {2});
      case 'KKT':
      case 'KN':
        return const _Piece(Role.knight, {6});
      case 'QKT':
      case 'QN':
        return const _Piece(Role.knight, {1});
    }
    return null;
  }

  /// Parses a destination square `<file><rank>`, e.g. `K4`, `QB3`, `KKt5`.
  /// Returns (file set, descriptive rank 1-8).
  static (Set<int>, int)? _square(String s) {
    for (final tok in _fileTokensByLength) {
      if (s.startsWith(tok) && s.length == tok.length + 1) {
        final rank = int.tryParse(s.substring(tok.length));
        final files = _fileSets[tok];
        if (rank != null && rank >= 1 && rank <= 8 && files != null) {
          return (files, rank);
        }
      }
    }
    return null;
  }

  static Role? _roleFromLetter(String s) {
    switch (s) {
      case 'KT':
      case 'N':
        return Role.knight;
      case 'Q':
        return Role.queen;
      case 'R':
        return Role.rook;
      case 'B':
        return Role.bishop;
    }
    return null;
  }
}

class _Piece {
  const _Piece(this.role, this.files);
  final Role role;
  final Set<int>? files;
}
