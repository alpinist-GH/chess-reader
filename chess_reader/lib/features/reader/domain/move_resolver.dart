import 'package:dartchess/dartchess.dart';

import '../../../core/models/move_token.dart';
import 'descriptive_notation.dart';

/// A token successfully resolved against the game context: playing [move]
/// from [positionBefore] yields [positionAfter], which is what the board
/// shows when the user taps this token in the book.
class ResolvedMove {
  const ResolvedMove({
    required this.token,
    required this.move,
    required this.positionBefore,
    required this.positionAfter,
  });

  final MoveToken token;
  final Move move;
  final Position positionBefore;
  final Position positionAfter;
}

class ResolvedLine {
  const ResolvedLine({required this.moves, required this.unresolved});

  /// Tokens resolved into legal moves, in reading order.
  final List<ResolvedMove> moves;

  /// Tokens that looked like SAN but were illegal in context. These render
  /// non-clickable: wrong is worse than missing.
  final List<MoveToken> unresolved;
}

/// Resolves tokens against the evolving game context.
///
/// Annotated books are not linear PGNs: prose interleaves variations
/// ("40 axb4? loses to 40...Ra1+. However, 40 Rc1 is essential"), pages
/// start mid-game, and multiple games share a page. The ladder, per token:
///
/// 1. **Game start**: `1.` + white hint that parses from the initial
///    position reseeds the context (new game).
/// 2. **Move-number resync**: the position seen the first time each
///    (number, color) appeared is remembered; when the same number reappears
///    (a variation revisiting the branch point) or the current position
///    disagrees with the hint, resolution retries from the remembered
///    position.
/// 3. **Plain continuation** from the current position.
/// 4. Otherwise the token is unresolved; the context does not advance, so a
///    prose false positive cannot poison the rest of the page.
class MoveResolver {
  MoveResolver._();

  /// How many resolved moves a remembered branch point stays valid for.
  static const _historyPlies = 60;

  /// Parses a token against [pos], dispatching descriptive notation
  /// (`P-K4`) to its board-aware resolver and everything else to algebraic SAN.
  static Move? _parse(Position pos, MoveToken token) => token.isDescriptive
      ? DescriptiveNotation.toMove(pos, token.san)
      : pos.parseSan(token.san);

  static ResolvedLine resolve(List<MoveToken> tokens, {Position? start}) {
    var position = start ?? Chess.initial;
    final moves = <ResolvedMove>[];
    final unresolved = <MoveToken>[];

    // First position seen for each (moveNumber, isWhite) — the branch point
    // a variation returns to. Entries expire after [_historyPlies] resolved
    // moves: a "26" from one game must not hijack another game's "26"
    // hundreds of moves later.
    final seen = <(int, bool), (Position, int)>{};

    for (final token in tokens) {
      final n = token.moveNumber;
      final white = token.isWhiteHint;

      Position? base;

      // Rung 1: explicit game start.
      if (n == 1 && white == true && _parse(Chess.initial, token) != null) {
        final hintMatches =
            position.fullmoves == 1 && position.turn == Side.white;
        if (!hintMatches || _parse(position, token) == null) {
          base = Chess.initial;
          seen.clear();
        }
      }

      // Rung 2: number disagreement or revisit → resync to the remembered
      // branch point (if it has not expired).
      if (base == null && n != null && white != null) {
        final hintMatchesHere =
            position.fullmoves == n && (position.turn == Side.white) == white;
        final remembered = seen[(n, white)];
        if (!hintMatchesHere &&
            remembered != null &&
            moves.length - remembered.$2 <= _historyPlies) {
          if (_parse(remembered.$1, token) != null) {
            base = remembered.$1;
          }
        }
      }

      // Rung 3: plain continuation.
      base ??= position;
      var move = _parse(base, token);
      if (move == null && base != position) {
        base = position;
        move = _parse(base, token);
      }

      if (move == null) {
        unresolved.add(token);
        continue;
      }

      if (n != null && white != null) {
        seen.putIfAbsent((n, white), () => (base!, moves.length));
      }
      final next = base.play(move);
      moves.add(ResolvedMove(
        token: token,
        move: move,
        positionBefore: base,
        positionAfter: next,
      ));
      position = next;
    }
    return ResolvedLine(moves: moves, unresolved: unresolved);
  }
}
