import 'package:chess_reader/core/entitlements/purchase_service.dart';

import 'fakes/fake_pro_store_gateway.dart';

import 'package:chess_reader/core/models/move_token.dart';
import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/reader/domain/move_resolver.dart';
import 'package:chess_reader/features/reader/state/book_providers.dart';
import 'package:chess_reader/features/reader/state/reading_analysis.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:chess_reader/features/board/board_panel.dart';
import 'package:chessground/chessground.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<ResolvedMove> line(List<String> sans, {Position start = Chess.initial}) {
  var position = start;
  return [
    for (final san in sans)
      (() {
        final before = position;
        final move = position.parseSan(san)!;
        position = position.playUnchecked(move);
        return ResolvedMove(
          token: MoveToken(san: san, start: 0, end: san.length),
          move: move,
          positionBefore: before,
          positionAfter: position,
        );
      })(),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer c;
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    c = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        proStoreGatewayProvider.overrideWithValue(FakeProStoreGateway()),
      ],
    );
    c.read(readingAnalysisProvider.notifier).open('book.pdf');
  });
  tearDown(() => c.dispose());

  test('branches survive undo, return to main, and reopening', () {
    final moves = line(['e4', 'e5', 'Nf3']);
    c.read(activeLineProvider.notifier).select(moves, 0, 1);
    final analysis = c.read(readingAnalysisProvider.notifier);
    final session = c.read(gameSessionProvider.notifier);
    session.playMove(Move.parse('c7c5')!);
    final sicilian = c.read(readingAnalysisProvider).cursor!;
    session.playMove(Move.parse('g1f3')!);
    final branch = c.read(readingAnalysisProvider).cursor!;
    session.undo();
    expect(c.read(readingAnalysisProvider).cursor, sicilian);
    session.undo();
    expect(c.read(gameSessionProvider).fen, moves.first.positionAfter.fen);
    analysis.backToMain();
    final tree = c.read(readingAnalysisProvider);
    expect(tree.children(tree.main!).length, 2);
    analysis.select(branch);
    expect(
      c.read(gameSessionProvider).position.fen,
      Chess.fromSetup(Setup.parseFen(tree.nodes[branch].fen)).fen,
    );
    final restored = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(restored.dispose);
    restored.read(readingAnalysisProvider.notifier).open('book.pdf');
    expect(restored.read(readingAnalysisProvider).cursor, branch);
    expect(
      restored.read(readingAnalysisProvider).nodes.length,
      tree.nodes.length,
    );
    expect(restored.read(gameSessionProvider).fen, tree.nodes[branch].fen);
    restored.read(readingAnalysisProvider.notifier).backToMain();
    expect(
      restored.read(gameSessionProvider).fen,
      moves.first.positionAfter.fen,
    );
  });

  testWidgets('saved lines controls return and reopen a retained variation', (
    tester,
  ) async {
    final moves = line(['e4', 'e5']);
    c.read(activeLineProvider.notifier).select(moves, 0, 1);
    c.read(gameSessionProvider.notifier).playMove(Move.parse('c7c5')!);
    final variationFen = c.read(gameSessionProvider).fen;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: BoardPanel())),
      ),
    );
    await tester.tap(find.text('Moves'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Analysis actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Main line'));
    await tester.pump();
    expect(c.read(gameSessionProvider).fen, moves.first.positionAfter.fen);
    await tester.ensureVisible(find.text('1... c5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1... c5'));
    await tester.pumpAndSettle();
    expect(c.read(gameSessionProvider).fen, variationFen);
    expect(c.read(activeLineProvider), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'new game preserves diagram analysis and isolates games on the same page',
    () {
      final analysis = c.read(readingAnalysisProvider.notifier);
      final session = c.read(gameSessionProvider.notifier);
      final original = line(['e4', 'e5']);
      session.setPosition(original.last.positionAfter);
      session.playMove(Move.parse('g1f3')!);
      final diagramCursor = c.read(readingAnalysisProvider).cursor!;
      final diagramFen = c.read(gameSessionProvider).fen;
      analysis.newGame(1);
      final firstRoot = c.read(readingAnalysisProvider).cursor!;
      expect(c.read(gameSessionProvider).fen, Chess.initial.fen);
      expect(c.read(gameSessionProvider).canUndo, isFalse);
      c.read(activeLineProvider.notifier).select(original, 0, 1);
      expect(
        c
            .read(readingAnalysisProvider)
            .nodes[c.read(readingAnalysisProvider).cursor!]
            .parent,
        firstRoot,
      );
      analysis.newGame(1);
      final secondRoot = c.read(readingAnalysisProvider).cursor!;
      expect(secondRoot, isNot(firstRoot));
      c.read(activeLineProvider.notifier).select(original, 0, 1);
      final tree = c.read(readingAnalysisProvider);
      expect(tree.nodes[tree.cursor!].parent, secondRoot);
      expect(tree.children(firstRoot), isNotEmpty);
      analysis.select(diagramCursor);
      expect(c.read(gameSessionProvider).fen, diagramFen);
      analysis.open('book.pdf');
      expect(c.read(gameSessionProvider).fen, diagramFen);
    },
  );

  testWidgets('Moves shows numbered branches and updates the same board', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    c.read(activeLineProvider.notifier).select(line(['e4', 'e5']), 0, 1);
    c.read(gameSessionProvider.notifier).playMove(Move.parse('c7c5')!);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: BoardPanel())),
      ),
    );
    await tester.tap(find.text('Moves'));
    await tester.pumpAndSettle();
    expect(find.text('V1'), findsOneWidget);
    await tester.ensureVisible(find.text('1. e4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1. e4'));
    await tester.pumpAndSettle();
    final arrows = tester
        .widget<Chessboard>(find.byType(Chessboard))
        .shapes
        .whereType<Arrow>();
    expect(
      arrows.map((arrow) => (arrow.orig, arrow.dest)),
      unorderedEquals([
        (Square.e2, Square.e4),
        (Square.e7, Square.e5),
        (Square.c7, Square.c5),
      ]),
    );
    expect(arrows.map((arrow) => arrow.color).toSet(), hasLength(3));
    await tester.ensureVisible(find.text('1... e5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1... e5'));
    await tester.pumpAndSettle();
    expect(c.read(gameSessionProvider).lastMove!.uci, 'e7e5');
    expect(
      tester.widget<Chessboard>(find.byType(Chessboard)).controller.game.fen,
      c.read(gameSessionProvider).fen,
    );
    await tester.tap(find.byTooltip('Analysis actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go to start'));
    await tester.pumpAndSettle();
    expect(c.read(gameSessionProvider).fen, Chess.initial.fen);
  });

  test('diagram PGN preserves nested branches, promotion and move numbers', () {
    final analysis = c.read(readingAnalysisProvider.notifier);
    final session = c.read(gameSessionProvider.notifier);
    final fen = line(['e4']).single.positionAfter.fen
        .replaceFirst(' 0 1', ' 0 12');
    analysis.loadStartingPosition(fen, diagramKey: '12:0');
    session.playMove(Move.parse('e7e5')!);
    analysis.goToStart();
    session.playMove(Move.parse('c7c5')!);
    final fork = c.read(readingAnalysisProvider).cursor!;
    session.playMove(Move.parse('g1f3')!);
    analysis.select(fork);
    session.playMove(Move.parse('d2d4')!);
    final selectedFen = c.read(gameSessionProvider).fen;
    analysis.promoteToMain(c.read(readingAnalysisProvider).cursor!);
    expect(c.read(gameSessionProvider).fen, selectedFen);
    final pgn = analysis.exportPgn();
    expect(pgn, contains('[FEN "$fen"]'));
    expect(pgn, contains('12... c5 (12... e5) 13. d4 (13. Nf3)'));
    final parsed = PgnGame.parsePgn(pgn);
    expect(parsed.moves.children.length, 2);
    expect(parsed.moves.children.first.children.length, 2);
    analysis.open('book.pdf');
    expect(analysis.exportPgn(), pgn);
    expect(c.read(gameSessionProvider).fen, selectedFen);
  });

  test('undo removes entered moves and clear affects only the active root', () {
    final analysis = c.read(readingAnalysisProvider.notifier);
    final session = c.read(gameSessionProvider.notifier);
    analysis.newGame(1);
    session.playMove(Move.parse('e2e4')!);
    session.playMove(Move.parse('e7e5')!);
    analysis.undoEntry();
    analysis.undoEntry();
    expect(c.read(gameSessionProvider).fen, Chess.initial.fen);
    expect(c.read(readingAnalysisProvider).nodes, hasLength(1));
    session.playMove(Move.parse('d2d4')!);
    analysis.newGame(2);
    session.playMove(Move.parse('g1f3')!);
    analysis.clearAnalysis();
    final state = c.read(readingAnalysisProvider);
    expect(state.children(state.root), isEmpty);
    expect(state.children(0), hasLength(1));
    expect(c.read(gameSessionProvider).fen, Chess.initial.fen);
  });

  test('a copied diagram starts its own tree even on the printed line', () {
    final moves = line(['e4', 'e5']);
    c.read(activeLineProvider.notifier).select(moves, 0, 1);
    final analysis = c.read(readingAnalysisProvider.notifier);
    final rootFen = moves.first.positionAfter.fen;
    analysis.loadStartingPosition(rootFen, diagramKey: '1:0');
    final state = c.read(readingAnalysisProvider);
    expect(state.nodes[state.root].fen, rootFen);
    expect(state.children(state.root), isEmpty);
    c.read(gameSessionProvider.notifier).playMove(Move.parse('c7c5')!);
    expect(analysis.exportPgn(), contains('1... c5'));
    analysis.loadStartingPosition(rootFen, diagramKey: '1:1');
    expect(
      c
          .read(readingAnalysisProvider)
          .children(c.read(readingAnalysisProvider).root),
      isEmpty,
    );
    analysis.loadStartingPosition(rootFen, diagramKey: '1:0');
    expect(analysis.exportPgn(), contains('1... c5'));
    analysis.clearAnalysis();
    c.read(activeLineProvider.notifier).select(moves, 0, 1);
    expect(analysis.exportPgn(), contains('1. e4 e5'));
  });

  testWidgets('play inside Moves and choose Black from a copied diagram', (
    tester,
  ) async {
    final analysis = c.read(readingAnalysisProvider.notifier);
    analysis.loadStartingPosition(Chess.initial.fen, diagramKey: '1:0');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: BoardPanel())),
      ),
    );
    final board = find.byType(Chessboard);
    final controller = tester.widget<Chessboard>(board).controller;
    await tester.tap(find.text('Moves'));
    await tester.pumpAndSettle();
    expect(board, findsOneWidget);
    expect(tester.widget<Chessboard>(board).controller, same(controller));
    final rect = tester.getRect(board);
    final square = rect.width / 8;
    Future<void> play(int file, int fromRank, int toRank) async {
      await tester.tapAt(
        rect.topLeft + Offset(square * (file + 0.5), square * (7.5 - fromRank)),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(
        rect.topLeft + Offset(square * (file + 0.5), square * (7.5 - toRank)),
      );
      await tester.pumpAndSettle();
    }

    await play(4, 1, 3);
    expect(analysis.exportPgn(), contains('1. e4'));
    await tester.tap(find.text('White'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Black').last);
    await tester.pumpAndSettle();
    expect(c.read(gameSessionProvider).position.turn, Side.black);
    await play(2, 6, 4);
    expect(analysis.exportPgn(), contains('1... c5'));
    expect(analysis.setStartingSide(Side.white), isTrue);
    expect(analysis.exportPgn(), contains('1. e4'));
  });

  test('manual new-game main line survives exploring an alternative', () {
    final analysis = c.read(readingAnalysisProvider.notifier);
    final session = c.read(gameSessionProvider.notifier);
    analysis.newGame(1);
    session.playMove(Move.parse('e2e4')!);
    final e4 = c.read(readingAnalysisProvider).cursor!;
    session.playMove(Move.parse('e7e5')!);
    final mainFen = c.read(gameSessionProvider).fen;
    analysis.select(e4);
    session.playMove(Move.parse('c7c5')!);
    analysis.backToMain();
    expect(c.read(gameSessionProvider).fen, mainFen);
  });

  test('Back to book keeps saved navigation synchronized', () {
    c.read(activeLineProvider.notifier).select(line(['e4', 'e5']), 0, 1);
    final main = c.read(readingAnalysisProvider).cursor;
    final session = c.read(gameSessionProvider.notifier);
    session.playMove(Move.parse('c7c5')!);
    final variation = c.read(readingAnalysisProvider).cursor!;
    session.backToBook();
    expect(c.read(readingAnalysisProvider).cursor, main);
    c.read(readingAnalysisProvider.notifier).select(variation);
    expect(c.read(gameSessionProvider).lastMove!.uci, 'c7c5');
  });

  test('printed variation does not replace main-line return point', () {
    final moves = line(['e4', 'e5', 'Nf3']);
    final variation = line(['c5', 'Nf3'], start: moves.first.positionAfter);
    final all = [...moves, ...variation];
    c.read(activeLineProvider.notifier).select(all, 2, 1);
    final main = c.read(readingAnalysisProvider).main;
    c.read(activeLineProvider.notifier).select(all, 4, 1);
    expect(c.read(readingAnalysisProvider).main, main);
    c.read(readingAnalysisProvider.notifier).backToMain();
    expect(c.read(gameSessionProvider).fen, moves.last.positionAfter.fen);
  });

  test(
    'book and page analysis are isolated and repeated moves deduplicate',
    () {
      final moves = line(['d4', 'd5']);
      final active = c.read(activeLineProvider.notifier);
      active.select(moves, 0, 1);
      final count = c.read(readingAnalysisProvider).nodes.length;
      active.select(moves, 1, 1);
      expect(c.read(readingAnalysisProvider).nodes.length, count);
      active.select(moves, 0, 2);
      expect(c.read(readingAnalysisProvider).nodes.length, count * 2);
      c.read(readingAnalysisProvider.notifier).open('other.pdf');
      expect(c.read(readingAnalysisProvider).nodes, isEmpty);
      c.read(readingAnalysisProvider.notifier).open('book.pdf');
      expect(c.read(readingAnalysisProvider).nodes.length, count * 2);
    },
  );

  test(
    'computer moves and corrupt saved analysis do not become reader moves',
    () async {
      c.read(activeLineProvider.notifier).select(line(['e4', 'e5']), 0, 1);
      final before = c.read(readingAnalysisProvider);
      c
          .read(gameSessionProvider.notifier)
          .playMove(Move.parse('c7c5')!, origin: PositionOrigin.computer);
      expect(c.read(readingAnalysisProvider), same(before));
      await prefs.setString('reading.analysis.v1.broken.pdf', '{bad json');
      c.read(readingAnalysisProvider.notifier).open('broken.pdf');
      expect(c.read(readingAnalysisProvider).nodes, isEmpty);
    },
  );

  test('newGame when no book is open resets board without saving nodes', () {
    final analysis = c.read(readingAnalysisProvider.notifier);
    final session = c.read(gameSessionProvider.notifier);
    analysis.open(null);
    session.playMove(Move.parse('e2e4')!);
    expect(c.read(gameSessionProvider).fen, isNot(Chess.initial.fen));
    analysis.newGame(1);
    expect(c.read(gameSessionProvider).fen, Chess.initial.fen);
    expect(c.read(readingAnalysisProvider).nodes, isEmpty);
    expect(c.read(readingAnalysisProvider).cursor, isNull);
  });

  test('moves played before selecting a book move form one connected line', () {
    final session = c.read(gameSessionProvider.notifier);
    session.playMove(Move.parse('e2e4')!);
    session.playMove(Move.parse('e7e5')!);
    final tree = c.read(readingAnalysisProvider);
    expect(tree.nodes.map((n) => n.label), [
      'Start position',
      '1.e4',
      '1...e5',
    ]);
    expect(tree.nodes.map((n) => n.parent), [null, 0, 1]);
    expect(tree.nodes.first.fen, Chess.initial.fen);
    expect(tree.main, tree.cursor);
    session.undo();
    expect(c.read(readingAnalysisProvider).cursor, 1);
  });

  test('undo and Back to book stay on the current page line', () {
    final moves = line(['e4', 'e5']);
    final active = c.read(activeLineProvider.notifier);
    final session = c.read(gameSessionProvider.notifier);
    active.select(moves, 0, 1);
    active.select(moves, 0, 2);
    final onPageTwo = c.read(readingAnalysisProvider).cursor!;
    session.playMove(Move.parse('c7c5')!);
    session.undo();
    expect(c.read(readingAnalysisProvider).cursor, onPageTwo);
    session.playMove(Move.parse('c7c5')!);
    session.backToBook();
    expect(c.read(readingAnalysisProvider).cursor, onPageTwo);
  });

  test('selecting another game moves the main-line return point with it', () {
    final analysis = c.read(readingAnalysisProvider.notifier);
    final session = c.read(gameSessionProvider.notifier);
    analysis.newGame(1);
    session.playMove(Move.parse('e2e4')!);
    final firstGame = c.read(readingAnalysisProvider).cursor!;
    final firstGameFen = c.read(gameSessionProvider).fen;
    session.playMove(Move.parse('e7e5')!);
    analysis.newGame(1);
    session.playMove(Move.parse('d2d4')!);
    analysis.select(firstGame);
    expect(c.read(readingAnalysisProvider).main, firstGame);
    session.playMove(Move.parse('c7c5')!);
    analysis.backToMain();
    expect(c.read(gameSessionProvider).fen, firstGameFen);
  });

  test('a diagram with an impossible check survives reopening the book', () {
    const fen = '4k3/8/8/8/r3K2r/8/8/4r3 w - - 0 1';
    final session = c.read(gameSessionProvider.notifier);
    expect(session.loadFen(fen), isTrue);
    expect(c.read(gameSessionProvider).legal, isTrue);
    session.playMove(Move.parse('e4d5')!);
    final count = c.read(readingAnalysisProvider).nodes.length;
    expect(count, 2);
    final analysis = c.read(readingAnalysisProvider.notifier);
    analysis.open('book.pdf');
    expect(c.read(readingAnalysisProvider).nodes.length, count);
    analysis.select(0);
    expect(c.read(gameSessionProvider).fen, fen);
  });

  test('a printed line stays connected when it transposes into another', () {
    final analysis = c.read(readingAnalysisProvider.notifier);
    final session = c.read(gameSessionProvider.notifier);
    analysis.newGame(1);
    final root = c.read(readingAnalysisProvider).cursor!;
    // The earlier nodes reach the printed position by another move order.
    for (final uci in ['g1f3', 'b8c6', 'b1c3']) {
      session.playMove(Move.parse(uci)!);
    }
    final transposedFen = c.read(gameSessionProvider).fen;
    analysis.select(root);
    for (final uci in ['b1c3', 'b8c6', 'g1f3']) {
      session.playMove(Move.parse(uci)!);
    }
    expect(c.read(gameSessionProvider).fen, transposedFen);
    c
        .read(activeLineProvider.notifier)
        .select(line(['Nc3', 'Nc6', 'Nf3', 'e5']), 3, 1);
    final tree = c.read(readingAnalysisProvider);
    final labels = <String>[];
    for (int? id = tree.cursor; id != null; id = tree.nodes[id].parent) {
      labels.insert(0, tree.nodes[id].label);
    }
    expect(labels, ['New game 1', '1.Nc3', '1...Nc6', '2.Nf3', '2...e5']);
  });

  testWidgets('saved-line controls leave the phone board usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final moves = line(['e4', 'e5']);
    c
        .read(activeLineProvider.notifier)
        .select(
          [
            ...moves,
            ...line(['c5'], start: moves.first.positionAfter),
          ],
          0,
          1,
        );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: BoardPanel())),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(Chessboard)).width, greaterThan(120));
    await tester.tap(find.text('Moves'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Chessboard), findsOneWidget);
    expect(tester.getSize(find.byType(Chessboard)).width, greaterThan(120));
    await tester.pumpWidget(const SizedBox());
  });
}
