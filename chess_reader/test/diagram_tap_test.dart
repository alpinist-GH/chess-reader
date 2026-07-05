import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_reader/core/models/move_token.dart';
import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/reader/data/epub_book.dart';
import 'package:chess_reader/features/reader/domain/move_resolver.dart';
import 'package:chess_reader/features/reader/presentation/book_html_view.dart';

/// Regression: tapping a detected diagram in the HTML reading view must load
/// its FEN onto the side board — it worked in PDF (original-pages) mode but the
/// reading view's tap didn't reach the handler. Renders the production
/// HtmlChapterList (ScrollablePositionedList) so the real scroll/hit-test
/// context is exercised.
void main() {
  testWidgets('tapping a diagram in the reading view loads its FEN',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    const fen = '4k3/8/8/3PP3/3PP3/8/8/4K3 w - - 0 1';
    const placement = '4k3/8/8/3PP3/3PP3/8/8/4K3';
    final chapter = EpubChapter(
      title: 'p1',
      html: '<div><p>before</p>'
          '<chessdiagram fen="$fen">board</chessdiagram>'
          '<p>after</p></div>',
      moves: const [],
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        home: Scaffold(
          body: HtmlChapterList(
            path: '/tmp/book.pdf',
            chapters: [chapter],
            sourceKeyPrefix: 'pg',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final boardFinder = find.byType(StaticChessboard);
    expect(boardFinder, findsOneWidget, reason: 'diagram board should render');

    final container = ProviderScope.containerOf(
        tester.element(boardFinder),
        listen: false);
    expect(container.read(gameSessionProvider).fen.startsWith(placement),
        isFalse);

    await tester.tapAt(tester.getCenter(boardFinder));
    await tester.pumpAndSettle();

    expect(
      container.read(gameSessionProvider).fen.startsWith(placement),
      isTrue,
      reason: 'tapping the diagram should load its position onto the board',
    );
  });

  testWidgets('the diagram Load button loads its FEN onto the board',
      (tester) async {
    // The button is the reliable affordance: a bare board tap can lose the
    // gesture arena to the surrounding scroll on a real device, but a button
    // press always reaches its handler.
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    const fen = '4k3/8/8/3PP3/3PP3/8/8/4K3 w - - 0 1';
    const placement = '4k3/8/8/3PP3/3PP3/8/8/4K3';
    final chapter = EpubChapter(
      title: 'p1',
      html: '<div><p>before</p>'
          '<chessdiagram fen="$fen">board</chessdiagram>'
          '<p>after</p></div>',
      moves: const [],
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        home: Scaffold(
          body: HtmlChapterList(
            path: '/tmp/book.pdf',
            chapters: [chapter],
            sourceKeyPrefix: 'pg',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final loadButton = find.widgetWithText(FilledButton, 'Load');
    expect(loadButton, findsOneWidget, reason: 'a Load button should render');

    final container = ProviderScope.containerOf(
        tester.element(loadButton),
        listen: false);
    expect(container.read(gameSessionProvider).fen.startsWith(placement),
        isFalse);

    await tester.tap(loadButton);
    await tester.pumpAndSettle();

    expect(
      container.read(gameSessionProvider).fen.startsWith(placement),
      isTrue,
      reason: 'pressing Load should put the position on the board',
    );
  });

  testWidgets('training annotations render as arrow shapes and ✕ marks',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    const fen = '4k3/8/8/3PP3/3PP3/8/8/4K3 w - - 0 1';
    final chapter = EpubChapter(
      title: 'p1',
      html: '<div>'
          '<chessdiagram fen="$fen" ann="Ae1e4;Xd5;Xe5">board</chessdiagram>'
          '</div>',
      moves: const [],
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        home: Scaffold(
          body: HtmlChapterList(
            path: '/tmp/book.pdf',
            chapters: [chapter],
            sourceKeyPrefix: 'pg',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final board =
        tester.widget<StaticChessboard>(find.byType(StaticChessboard));
    expect(
      board.shapes,
      {Arrow(color: const Color(0xB315781B), orig: Square.e1, dest: Square.e4)},
      reason: 'the ann arrow should reach the board as a chessground shape',
    );
    // The two X marks paint through a dedicated layer over the board.
    expect(
      find.byWidgetPredicate((w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_XMarkPainter'),
      findsOneWidget,
      reason: 'marked squares should get the ✕ paint layer',
    );
  });

  testWidgets('an unreconstructable diagram (empty fen) shows the print crop',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    // A 1×1 transparent PNG as the stand-in crop.
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
    final chapter = EpubChapter(
      title: 'p1',
      html: '<div><chessdiagram fen="">'
          '<img src="data:image/png;base64,$png"></chessdiagram></div>',
      moves: const [],
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        home: Scaffold(
          body: HtmlChapterList(
            path: '/tmp/book.pdf',
            chapters: [chapter],
            sourceKeyPrefix: 'pg',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(StaticChessboard), findsNothing,
        reason: 'no board can be rebuilt from an empty FEN');
    expect(find.text('Diagram (as printed)'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Load'), findsNothing,
        reason: 'the as-printed tile has no position to load');
  });

  testWidgets('tapping a move in the reading view updates the board',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    // One resolved move: 1.e4 from the initial position.
    final before = Chess.initial;
    final move = NormalMove.fromUci('e2e4');
    final after = before.play(move);
    const expectedFen =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
    final resolved = ResolvedMove(
      token: const MoveToken(san: 'e4', start: 0, end: 2),
      move: move,
      positionBefore: before,
      positionAfter: after,
    );
    final chapter = EpubChapter(
      title: 'p1',
      html: '<div><p>1.<chessmove idx="0">e4</chessmove> and so on.</p></div>',
      moves: [resolved],
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        home: Scaffold(
          body: HtmlChapterList(
            path: '/tmp/book.pdf',
            chapters: [chapter],
            sourceKeyPrefix: 'pg',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The move is an inline TextSpan (with a TapGestureRecognizer), not a
    // standalone Text widget, so it lives inside the paragraph's RichText.
    final paragraphFinder = find.textContaining('e4');
    expect(paragraphFinder, findsOneWidget, reason: 'move should render');

    final container = ProviderScope.containerOf(
        tester.element(paragraphFinder),
        listen: false);
    expect(container.read(gameSessionProvider).fen, isNot(expectedFen));

    await tester.tapOnText(find.textRange.ofSubstring('e4'));
    await tester.pumpAndSettle();

    expect(
      container.read(gameSessionProvider).fen,
      expectedFen,
      reason: 'tapping a move should play it onto the board',
    );
  });
}
