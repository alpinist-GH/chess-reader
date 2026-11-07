import 'package:chess_reader/core/models/move_token.dart';
import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/reader/domain/move_resolver.dart';
import 'package:chess_reader/features/reader/state/book_providers.dart';
import 'package:chess_reader/features/reader/state/reading_analysis.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:chess_reader/features/board/reading_analysis_bar.dart';
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
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
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
        child: const MaterialApp(home: Scaffold(body: ReadingAnalysisBar())),
      ),
    );
    await tester.tap(find.text('Return to main line'));
    await tester.pump();
    expect(c.read(gameSessionProvider).fen, moves.first.positionAfter.fen);
    await tester.tap(find.text('Saved lines'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1...c5'));
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

  testWidgets(
    'branches are visible and selectable without opening saved lines',
    (tester) async {
      final moves = line(['e4', 'e5']);
      c.read(activeLineProvider.notifier).select(moves, 0, 1);
      c.read(gameSessionProvider.notifier).playMove(Move.parse('c7c5')!);
      c.read(readingAnalysisProvider.notifier).backToMain();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: Scaffold(body: ReadingAnalysisBar())),
        ),
      );
      expect(find.text('Branches:'), findsOneWidget);
      expect(find.text('1...e5 · Main'), findsOneWidget);
      await tester.tap(find.text('1...c5 · Variation'));
      await tester.pump();
      expect(c.read(gameSessionProvider).lastMove!.uci, 'c7c5');
      expect(find.text('Alternatives:'), findsOneWidget);
      await tester.tap(find.text('1...e5 · Main'));
      await tester.pump();
      expect(c.read(gameSessionProvider).lastMove!.uci, 'e7e5');
      await tester.pumpWidget(const SizedBox());
    },
  );

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
}
