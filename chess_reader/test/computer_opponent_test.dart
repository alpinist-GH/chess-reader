import 'package:chess_reader/core/entitlements/pro_entitlement.dart';
import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/computer_opponent/domain/computer_opponent_models.dart';
import 'package:chess_reader/features/computer_opponent/state/computer_opponent_provider.dart';
import 'package:chess_reader/core/models/move_token.dart';
import 'package:chess_reader/features/engine/state/analysis_provider.dart';
import 'package:chess_reader/features/reader/domain/move_resolver.dart';
import 'package:chess_reader/features/reader/state/book_providers.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_uci_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late FakeUciEngine fakeEngine;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    fakeEngine = FakeUciEngine();

    container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        proEntitlementProvider.overrideWithValue(true),
        opponentEngineFactoryProvider.overrideWithValue(() => fakeEngine),
        analysisEngineFactoryProvider.overrideWithValue(() => FakeUciEngine()),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  group('ComputerOpponentNotifier startup and exclusive ownership', () {
    test('requires Pro entitlement to start', () async {
      final nonProContainer = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            container.read(sharedPrefsProvider),
          ),
          proEntitlementProvider.overrideWithValue(false),
          opponentEngineFactoryProvider.overrideWithValue(() => fakeEngine),
          analysisEngineFactoryProvider.overrideWithValue(() => FakeUciEngine()),
        ],
      );
      addTearDown(nonProContainer.dispose);

      final opponent = nonProContainer.read(computerOpponentProvider.notifier);
      final started = await opponent.startGame();
      expect(started, isFalse);
      expect(nonProContainer.read(computerOpponentProvider).phase,
          ComputerGamePhase.error);
      expect(nonProContainer.read(computerOpponentProvider).errorMessage,
          contains('Pro entitlement'));
    });

    test('pauses analysis engine when starting and restores on returnToBook',
        () async {
      // Enable analysis
      await container.read(analysisProvider.notifier).toggle();
      expect(container.read(analysisProvider).enabled, isTrue);

      // Start computer opponent game
      final opponent = container.read(computerOpponentProvider.notifier);
      final ok = await opponent.startGame(chosenSide: Side.white);
      expect(ok, isTrue);

      // Analysis should be paused/stopped for exclusive engine ownership
      expect(container.read(analysisProvider).enabled, isFalse);

      // Return to book should restore analysis
      await opponent.returnToBook();
      expect(container.read(analysisProvider).enabled, isTrue);
    });

    test('human as White starts on humanTurn; human as Black triggers search immediately',
        () async {
      fakeEngine.nextBestmove = 'e7e5';
      final opponent = container.read(computerOpponentProvider.notifier);

      // Human as White
      await opponent.startGame(chosenSide: Side.white);
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.humanTurn);
      expect(container.read(computerOpponentProvider).humanSide, Side.white);

      // Restart as Black
      fakeEngine.nextBestmove = 'e2e4';
      await opponent.startGame(chosenSide: Side.black);
      expect(container.read(computerOpponentProvider).humanSide, Side.black);

      // Wait for engine auto-response
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.humanTurn);
      expect(container.read(gameSessionProvider).position.turn, Side.black);
      expect(container.read(gameSessionProvider).lastMove,
          NormalMove.fromUci('e2e4'));
    });
  });

  group('In-game move flow and history tracking', () {
    test('sends full move history to the engine on successive searches',
        () async {
      fakeEngine.nextBestmove = 'e7e5';
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      // Human plays 1. e4
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));

      // Engine should receive full move list
      expect(fakeEngine.sentCommands,
          contains(predicate<String>((s) => s.contains('position startpos moves e2e4'))));

      // Wait for engine to answer 1... e5
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(gameSessionProvider).lastMove,
          NormalMove.fromUci('e7e5'));
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.humanTurn);

      // Human plays 2. Nf3
      fakeEngine.nextBestmove = 'b8c6';
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('g1f3'));

      // Engine should receive position startpos moves e2e4 e7e5 g1f3
      expect(
        fakeEngine.sentCommands,
        contains(predicate<String>(
            (s) => s.contains('position startpos moves e2e4 e7e5 g1f3'))),
      );
    });

    test('ignores stale engine replies and generation mismatches', () async {
      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      // Human plays e4
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.engineThinking);

      // Human resigns while engine was searching
      await opponent.resign();
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.finished);

      // Engine belatedly sends bestmove
      fakeEngine.pushLine('bestmove e7e5');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Game state must remain finished and not revert
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.finished);
      expect(container.read(gameSessionProvider).position.turn, Side.black);
    });
  });

  group('Draw adjudication and casual play rules', () {
    test('detects threefold repetition automatically', () async {
      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      // 1. Nf3 Nf6
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('g1f3'));
      fakeEngine.pushLine('bestmove g8f6');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 2. Ng1 Ng8 (position repeated 2nd time)
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('f3g1'));
      fakeEngine.pushLine('bestmove f6g8');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 3. Nf3 Nf6
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('g1f3'));
      fakeEngine.pushLine('bestmove g8f6');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 4. Ng1 Ng8 (position repeated 3rd time!)
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('f3g1'));
      fakeEngine.pushLine('bestmove f6g8');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final state = container.read(computerOpponentProvider);
      expect(state.phase, ComputerGamePhase.finished);
      expect(state.result?.outcome, ComputerGameOutcome.threefoldRepetition);
      expect(state.result?.winner, GameWinner.draw);
    });

    test('detects 50-move rule automatically', () async {
      // Setup a position with 99 halfmoves (pawn on a2 and h7, no captures possible)
      final nearFiftyMovePos = Chess.fromSetup(Setup.parseFen(
        '8/7p/8/8/8/8/P7/k1K5 w - - 99 50',
      ));
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(
        chosenSide: Side.white,
        startFrom: nearFiftyMovePos,
      );

      // White king moves (Kd2): halfmoves becomes 100
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('c1d2'));

      final state = container.read(computerOpponentProvider);
      expect(state.phase, ComputerGamePhase.finished);
      expect(state.result?.outcome, ComputerGameOutcome.fiftyMoveRule);
      expect(state.result?.winner, GameWinner.draw);
    });

    test('checkmate priority takes precedence over draw rules', () async {
      // Fool's mate setup: White played 1. f3 e5 2. g4
      final foolsMateSetup = Chess.fromSetup(Setup.parseFen(
        'rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2',
      ));
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(
        chosenSide: Side.black,
        startFrom: foolsMateSetup,
      );

      // Human as Black delivers mate: 2... Qh4#
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('d8h4'));

      final state = container.read(computerOpponentProvider);
      expect(state.phase, ComputerGamePhase.finished);
      expect(state.result?.outcome, ComputerGameOutcome.checkmate);
      expect(state.result?.winner, GameWinner.human);
    });
  });

  group('Lifecycle, Rematch, and Reader restoration', () {
    test('backgrounding pauses the game and cancels in-flight search',
        () async {
      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.engineThinking);

      // Simulate app backgrounding
      opponent.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.paused);
      expect(fakeEngine.sentCommands, contains('stop'));

      // Resuming game restarts search
      opponent.resumeGame();
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.engineThinking);
    });

    test('rematch preserves start position and strength with color swap option',
        () async {
      fakeEngine.nextBestmove = 'e7e5';
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(
        chosenSide: Side.white,
        strength: ComputerStrengthPreset.advanced,
      );

      await opponent.resign();
      expect(container.read(computerOpponentProvider).isFinished, isTrue);

      // Rematch with color swap
      fakeEngine.nextBestmove = 'e2e4';
      await opponent.rematch(swapColors: true);
      final state = container.read(computerOpponentProvider);
      expect(state.humanSide, Side.black);
      expect(state.strength, ComputerStrengthPreset.advanced);
    });

    test('returnToBook restores pre-game reader position and excursion',
        () async {
      final session = container.read(gameSessionProvider.notifier);

      // Book position + excursion
      final bookPos = Chess.initial.play(NormalMove.fromUci('d2d4'));
      session.setPosition(bookPos, lastMove: NormalMove.fromUci('d2d4'));
      session.playMove(NormalMove.fromUci('g8f6'));
      final excursionFen = container.read(gameSessionProvider).fen;

      // Start computer game from standard startpos
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(
        chosenSide: Side.white,
        startFrom: Chess.initial,
      );
      expect(container.read(gameSessionProvider).fen, kInitialFEN);

      // Play moves in computer game
      session.playMove(NormalMove.fromUci('e2e4'));

      // Exit game
      await opponent.returnToBook();
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.idle);
      expect(container.read(gameSessionProvider).fen, excursionFen);
      expect(container.read(gameSessionProvider).canUndo, isTrue);
    });
  });

  group('Regressions', () {
    ResolvedMove resolvedMove(String uci, Position before) => ResolvedMove(
          token: MoveToken(san: uci, start: 0, end: uci.length),
          move: NormalMove.fromUci(uci),
          positionBefore: before,
          positionAfter: before.play(NormalMove.fromUci(uci)),
        );

    test('a stopped search\'s belated bestmove is not played after resuming',
        () async {
      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e2e4'));
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.engineThinking);

      // Backgrounding stops the search, but the engine still owes an answer.
      opponent.didChangeAppLifecycleState(AppLifecycleState.paused);
      opponent.resumeGame();
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.engineThinking);

      // The stopped search finally answers: it must be swallowed.
      fakeEngine.pushLine('bestmove e7e5');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.engineThinking);
      expect(container.read(gameSessionProvider).lastMove,
          NormalMove.fromUci('e2e4'));

      // The resumed search's own answer is the one that gets played.
      fakeEngine.pushLine('bestmove g8f6');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(container.read(gameSessionProvider).lastMove,
          NormalMove.fromUci('g8f6'));
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.humanTurn);
    });

    test('returnToBook after a rematch still restores the book position',
        () async {
      final session = container.read(gameSessionProvider.notifier);
      final bookPos = Chess.initial.play(NormalMove.fromUci('d2d4'));
      session.setPosition(bookPos, lastMove: NormalMove.fromUci('d2d4'));
      final bookFen = container.read(gameSessionProvider).fen;

      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(
        chosenSide: Side.white,
        startFrom: Chess.initial,
      );
      await opponent.resign();
      await opponent.rematch();
      expect(container.read(computerOpponentProvider).isGameActive, isTrue);

      await opponent.returnToBook();
      expect(container.read(gameSessionProvider).fen, bookFen);
    });

    test('analysis is restored after a rematch, not only after the first game',
        () async {
      await container.read(analysisProvider.notifier).toggle();
      expect(container.read(analysisProvider).enabled, isTrue);

      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);
      await opponent.resign();
      await opponent.rematch();
      expect(container.read(analysisProvider).enabled, isFalse);

      await opponent.returnToBook();
      expect(container.read(analysisProvider).enabled, isTrue);
    });

    test('returnToBook restores the selected book line', () async {
      final line = [
        resolvedMove('d2d4', Chess.initial),
        resolvedMove('g8f6', Chess.initial.play(NormalMove.fromUci('d2d4'))),
      ];
      container.read(activeLineProvider.notifier).select(line, 1, 'page-1');
      // ...and then explored a variation off that book move.
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('c2c4'));
      final excursionFen = container.read(gameSessionProvider).fen;
      expect(container.read(activeLineProvider), isNotNull);

      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(
        chosenSide: Side.white,
        startFrom: Chess.initial,
      );
      // Book navigation is inert while the game owns the board.
      container.read(activeLineProvider.notifier).previous();
      expect(container.read(activeLineProvider)!.index, 1);

      await opponent.returnToBook();
      final restored = container.read(activeLineProvider);
      expect(restored, isNotNull);
      expect(restored!.index, 1);
      expect(restored.sourceKey, 'page-1');
      // The excursion, not the book move the line points at, is what comes back.
      expect(container.read(gameSessionProvider).fen, excursionFen);
      expect(container.read(gameSessionProvider).canUndo, isTrue);
    });

    test('a session jump during the human turn is not mistaken for a move',
        () async {
      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      // Something else moves the board wholesale (a restored snapshot, a
      // diagram anchor). `lastMove` is set, but it is not the human's move.
      container.read(gameSessionProvider.notifier).setPosition(
            Chess.initial.play(NormalMove.fromUci('d2d4')),
            lastMove: NormalMove.fromUci('d2d4'),
          );

      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.humanTurn);
      expect(container.read(computerOpponentProvider).history, isEmpty);
      expect(fakeEngine.sentCommands, isNot(contains('go movetime 1000')));
    });

    test('castling is sent to the engine in the standard king-move form',
        () async {
      // White to move with both sides able to castle short.
      final pos = Chess.fromSetup(Setup.parseFen(
        'rnbqk2r/pppp1ppp/5n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4',
      ));
      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white, startFrom: pos);

      // dartchess normalizes castling to king-takes-rook (e1h1); the engine
      // must still be told e1g1.
      container
          .read(gameSessionProvider.notifier)
          .playMove(NormalMove.fromUci('e1h1'));

      expect(
        fakeEngine.sentCommands,
        contains(predicate<String>((c) =>
            c.startsWith('position fen ') && c.endsWith(' moves e1g1'))),
      );
    });

    test('closing the book abandons the game without restoring its snapshot',
        () async {
      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);
      expect(container.read(computerOpponentProvider).isGameActive, isTrue);

      container.read(openedBookProvider.notifier).close();

      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.idle);
      expect(container.read(gameSessionProvider).fen, kInitialFEN);
      expect(container.read(activeLineProvider), isNull);
    });

    test('retryEngine reports a failure instead of throwing', () async {
      fakeEngine.autoRespondBestmove = false;
      final opponent = container.read(computerOpponentProvider.notifier);
      await opponent.startGame(chosenSide: Side.white);

      // Force the next engine start to blow up.
      fakeEngine.failOnStart = true;
      await opponent.rematch();
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.error);

      await opponent.retryEngine();
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.error);
      expect(container.read(computerOpponentProvider).errorMessage,
          contains('Failed to start chess engine'));

      fakeEngine.failOnStart = false;
      await opponent.retryEngine();
      expect(container.read(computerOpponentProvider).phase,
          ComputerGamePhase.humanTurn);
    });
  });
}
