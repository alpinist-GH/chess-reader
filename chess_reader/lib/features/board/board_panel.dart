import 'dart:math';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/settings/app_settings.dart';
import '../../core/entitlements/pro_entitlement.dart';
import '../../core/entitlements/pro_purchase_dialog.dart';
import '../../core/state/game_session.dart';
import '../chessnut/presentation/chessnut_status_widget.dart';
import '../computer_opponent/domain/computer_opponent_models.dart';
import '../computer_opponent/presentation/computer_game_bar.dart';
import '../computer_opponent/presentation/computer_opponent_dialog.dart';
import '../computer_opponent/state/computer_opponent_provider.dart';
import '../engine/presentation/engine_panel.dart';
import '../guess_move/domain/guess_move_models.dart';
import '../guess_move/presentation/guess_move_bar.dart';
import '../guess_move/state/guess_move_provider.dart';
import '../reader/state/book_providers.dart';
import 'external_links.dart';
import 'fen_anchor_dialog.dart';

/// Interactive chessground board bound to the [gameSessionProvider].
///
/// Both sides are playable (free play): the board is the user's analysis
/// surface, not a game against an opponent. Moves played here that leave the
/// book line enter the variation sandbox; "back to book" snaps back.
class BoardPanel extends ConsumerStatefulWidget {
  const BoardPanel({super.key});

  @override
  ConsumerState<BoardPanel> createState() => _BoardPanelState();
}

class _BoardPanelState extends ConsumerState<BoardPanel> {
  late final ChessboardController _controller;
  Side _orientation = Side.white;

  @override
  void initState() {
    super.initState();
    _controller = ChessboardController(
      game: _gameDataFor(ref.read(gameSessionProvider)),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  GameData _gameDataFor(GameSessionState s) {
    // Display-only boards (unvalidated diagram placements) render the pieces
    // but offer no legal moves or check highlight.
    if (!s.legal) {
      return GameData(
        fen: s.fen,
        playerSide: PlayerSide.none,
        validMoves: const {},
        sideToMove: Side.white,
      );
    }

    final opponent = ref.read(computerOpponentProvider);
    final guess = ref.read(guessMoveProvider);
    final PlayerSide playerSide;
    if (guess.phase == GuessMovePhase.active) {
      playerSide = s.position.turn == Side.white
          ? PlayerSide.white
          : PlayerSide.black;
    } else if (guess.phase != GuessMovePhase.idle) {
      playerSide = PlayerSide.none;
    } else if (opponent.ownsBoard) {
      if (opponent.phase == ComputerGamePhase.humanTurn &&
          s.position.turn == opponent.humanSide) {
        playerSide = opponent.humanSide == Side.white
            ? PlayerSide.white
            : PlayerSide.black;
      } else {
        playerSide = PlayerSide.none;
      }
    } else {
      playerSide = s.position.turn == Side.white
          ? PlayerSide.white
          : PlayerSide.black;
    }

    return GameData(
      fen: s.fen,
      lastMove: s.lastMove,
      playerSide: playerSide,
      validMoves: playerSide == PlayerSide.none
          ? const {}
          : makeLegalMoves(s.position),
      sideToMove: s.position.turn,
      kingSquareInCheck: s.position.isCheck
          ? s.position.board.kingOf(s.position.turn)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(gameSessionProvider, (previous, next) {
      _controller.updatePosition(_gameDataFor(next), resetPremove: true);
    });
    ref.listen(computerOpponentProvider, (previous, next) {
      if (previous?.phase != next.phase ||
          previous?.humanSide != next.humanSide) {
        if (next.isGameActive) {
          if (next.humanSide == Side.black && _orientation != Side.black) {
            setState(() => _orientation = Side.black);
          } else if (next.humanSide == Side.white &&
              _orientation != Side.white) {
            setState(() => _orientation = Side.white);
          }
        }
        _controller.updatePosition(
          _gameDataFor(ref.read(gameSessionProvider)),
          resetPremove: true,
        );
      }
    });
    ref.listen(guessMoveProvider, (previous, next) {
      if (previous?.phase != next.phase ||
          previous?.target?.move != next.target?.move) {
        _controller.updatePosition(
          _gameDataFor(ref.read(gameSessionProvider)),
          resetPremove: true,
        );
      }
    });

    final session = ref.watch(gameSessionProvider);
    final opponent = ref.watch(computerOpponentProvider);
    final guess = ref.watch(guessMoveProvider);
    final activeLine = ref.watch(activeLineProvider);
    final guessHasProAccess = ref.watch(proEntitlementProvider);
    final canStartGuess =
        activeLine != null &&
        activeLine.index < activeLine.moves.length - 1 &&
        session.legal &&
        activeLine.moves[activeLine.index + 1].positionBefore.fen ==
            session.fen;
    final settings = ref.watch(settingsProvider);
    final boardSettings = ChessboardSettings(
      pieceAssets: settings.pieceSet.assets,
      colorScheme: settings.boardColors,
      enableCoordinates: true,
    );

    return Column(
      children: [
        const EnginePanel(),
        const SizedBox(height: 8),
        Expanded(
          child: Center(
            child: LayoutBuilder(
              builder: (context, constraints) => Chessboard(
                controller: _controller,
                size: min(constraints.maxWidth, constraints.maxHeight),
                settings: boardSettings,
                orientation: _orientation,
                onMove: (move, {viaDragAndDrop}) =>
                    ref.read(gameSessionProvider.notifier).playMove(move),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (guess.phase != GuessMovePhase.idle)
          const GuessMoveBar()
        else if (opponent.showsGameBar)
          const ComputerGameBar()
        else if (!session.onBookLine)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.keyboard_return),
              label: const Text('Back to book'),
              onPressed: () =>
                  ref.read(gameSessionProvider.notifier).backToBook(),
            ),
          ),
        const ChessnutStatusWidget(),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              tooltip: 'Undo move',
              icon: const Icon(Icons.undo),
              onPressed:
                  (opponent.ownsBoard ||
                      guess.phase != GuessMovePhase.idle ||
                      !session.canUndo)
                  ? null
                  : () => ref.read(gameSessionProvider.notifier).undo(),
            ),
            IconButton(
              tooltip: 'Reset board',
              icon: const Icon(Icons.restart_alt),
              onPressed:
                  opponent.ownsBoard || guess.phase != GuessMovePhase.idle
                  ? null
                  : () => ref.read(gameSessionProvider.notifier).reset(),
            ),
            IconButton(
              tooltip: 'Flip board',
              icon: const Icon(Icons.swap_vert),
              onPressed: () =>
                  setState(() => _orientation = _orientation.opposite),
            ),
            IconButton(
              tooltip: 'Set position from FEN',
              icon: const Icon(Icons.edit_location_alt_outlined),
              onPressed:
                  opponent.ownsBoard || guess.phase != GuessMovePhase.idle
                  ? null
                  : () => showFenAnchorDialog(context, ref),
            ),
            IconButton(
              tooltip: opponent.ownsBoard
                  ? 'Game vs computer in progress'
                  : 'Play vs computer',
              icon: Icon(
                opponent.ownsBoard ? Icons.smart_toy : Icons.smart_toy_outlined,
                color: opponent.ownsBoard
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              onPressed:
                  opponent.ownsBoard || guess.phase != GuessMovePhase.idle
                  ? null
                  : () => showComputerOpponentDialog(context, ref),
            ),
            IconButton(
              tooltip: guess.phase == GuessMovePhase.idle && !guessHasProAccess
                  ? 'Guess the next move (Pro)'
                  : guess.phase == GuessMovePhase.idle
                  ? 'Guess the next move'
                  : 'Guess the move in progress',
              icon: Icon(
                guess.phase == GuessMovePhase.idle && !guessHasProAccess
                    ? Icons.lock_outline
                    : guess.phase == GuessMovePhase.idle
                    ? Icons.school_outlined
                    : Icons.school,
                color: guess.phase == GuessMovePhase.idle && !guessHasProAccess
                    ? Theme.of(context).colorScheme.primary
                    : guess.phase == GuessMovePhase.idle
                    ? null
                    : Theme.of(context).colorScheme.primary,
              ),
              onPressed:
                  opponent.ownsBoard || guess.phase != GuessMovePhase.idle
                  ? null
                  : canStartGuess
                  ? () async {
                      if (!ref.read(proEntitlementProvider)) {
                        final unlocked = await showProPurchaseDialog(
                          context,
                          ref,
                        );
                        if (!context.mounted || !unlocked) return;
                      }
                      ref.read(guessMoveProvider.notifier).start();
                    }
                  : null,
            ),
            const SizedBox(width: 12),
            IconButton(
              tooltip: 'Open in Lichess',
              icon: const Icon(Icons.open_in_new),
              onPressed: () =>
                  launchUrl(Uri.parse(lichessAnalysisUrl(session.fen))),
            ),
            IconButton(
              tooltip: 'Open in Chess.com',
              icon: const Icon(Icons.language),
              onPressed: () =>
                  launchUrl(Uri.parse(chessComAnalysisUrl(session.fen))),
            ),
          ],
        ),
      ],
    );
  }
}
