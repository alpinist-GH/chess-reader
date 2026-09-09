import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/core/state/game_session.dart';
import 'package:chess_reader/features/board/external_links.dart';
import 'package:chess_reader/features/engine/data/engine_locator.dart';
import 'package:chess_reader/features/engine/data/process_engine.dart';
import 'package:chess_reader/features/engine/domain/uci_parser.dart';
import 'package:chess_reader/features/engine/state/analysis_provider.dart';

void main() {
  group('parseInfoLine', () {
    test('parses depth, cp score and pv', () {
      final info = parseInfoLine(
          'info depth 22 seldepth 30 multipv 1 score cp 35 nodes 2417057 '
          'nps 1234567 hashfull 350 tbhits 0 time 1957 '
          'pv e2e4 e7e5 g1f3 b8c6');
      expect(info, isNotNull);
      expect(info!.depth, 22);
      expect(info.scoreCp, 35);
      expect(info.scoreMate, isNull);
      expect(info.nodes, 2417057);
      expect(info.pvUci, ['e2e4', 'e7e5', 'g1f3', 'b8c6']);
    });

    test('parses mate scores and ignores string lines', () {
      final mate = parseInfoLine('info depth 12 score mate 3 pv h5f7');
      expect(mate!.scoreMate, 3);
      expect(parseInfoLine('info string NNUE evaluation using nn-1.nnue'),
          isNull);
      expect(parseInfoLine('bestmove e2e4'), isNull);
    });
  });

  test('parseBestmove', () {
    expect(parseBestmove('bestmove e2e4 ponder e7e5'), 'e2e4');
    expect(parseBestmove('bestmove e7e8q'), 'e7e8q');
    expect(parseBestmove('bestmove e7e8q ponder e2e4'), 'e7e8q');
    expect(parseBestmove('bestmove (none)'), isNull);
    expect(parseBestmove('bestmove 0000'), isNull);
    expect(parseBestmove('info depth 1'), isNull);
  });

  test('parseEngineCapabilities detects limit strength and Elo range', () {
    final lines = [
      'id name Stockfish 16',
      'option name Threads type spin default 1 min 1 max 1024',
      'option name UCI_LimitStrength type check default false',
      'option name UCI_Elo type spin default 1320 min 1320 max 3190',
      'uciok',
    ];
    final caps = parseEngineCapabilities(lines);
    expect(caps.supportsLimitStrength, isTrue);
    expect(caps.minElo, 1320);
    expect(caps.maxElo, 3190);
  });

  test('pvToSan converts UCI pv from a FEN', () {
    final sans = pvToSan(kInitialFEN, ['e2e4', 'e7e5', 'g1f3']);
    expect(sans, ['e4', 'e5', 'Nf3']);
  });

  group('external links', () {
    const fen = 'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';

    test('lichess uses underscores for spaces', () {
      expect(
        lichessAnalysisUrl(fen),
        'https://lichess.org/analysis/standard/'
        'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R_w_KQkq_-_2_3',
      );
    });

    test('chess.com URL-encodes the FEN', () {
      final url = chessComAnalysisUrl(fen);
      expect(url, startsWith('https://www.chess.com/analysis?fen='));
      expect(Uri.parse(url).queryParameters['fen'], fen);
    });
  });

  group('variation sandbox', () {
    test('board moves after a book position are an excursion; back to book returns',
        () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final session = container.read(gameSessionProvider.notifier);

      // Book sets a position (as if the user clicked a move).
      final bookPos = Chess.initial.play(NormalMove.fromUci('e2e4'));
      session.setPosition(bookPos, lastMove: NormalMove.fromUci('e2e4'));
      expect(container.read(gameSessionProvider).onBookLine, isTrue);

      // User explores on the board.
      session.playMove(NormalMove.fromUci('c7c5'));
      expect(container.read(gameSessionProvider).onBookLine, isFalse);

      session.backToBook();
      final state = container.read(gameSessionProvider);
      expect(state.onBookLine, isTrue);
      expect(state.fen, bookPos.fen);
    });
  });

  group('process engine (requires assets/engines binary)', () {
    test('startpos go depth 10 returns bestmove', () async {
      final path = locateStockfish();
      expect(path, isNotNull,
          reason: 'Stockfish binary missing — run tool/fetch_stockfish.ps1');
      final engine = ProcessEngine(path!);
      addTearDown(engine.dispose);
      await engine.start();

      final bestmove = engine.lines
          .map(parseBestmove)
          .firstWhere((m) => m != null)
          .timeout(const Duration(seconds: 30));
      engine.send('position startpos');
      engine.send('go depth 10');
      final move = await bestmove;
      expect(move, matches(RegExp(r'^[a-h][1-8][a-h][1-8]')));
    });
  });
}
