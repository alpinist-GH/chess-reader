import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/app_settings.dart';
import '../../../core/state/game_session.dart';
import '../data/engine_factory.dart';
import '../domain/uci_engine.dart';
import '../domain/uci_parser.dart';

/// What the engine currently thinks about the position on the board.
class AnalysisState {
  const AnalysisState({
    this.enabled = false,
    this.running = false,
    this.error,
    this.eval,
    this.fen,
  });

  final bool enabled;

  /// True once the engine process/library is up.
  final bool running;
  final String? error;

  /// Latest search info for [fen]; null until the first info line arrives.
  final UciInfo? eval;

  /// FEN the eval belongs to (guards against stale lines).
  final String? fen;

  AnalysisState copyWith({
    bool? enabled,
    bool? running,
    String? error,
    UciInfo? eval,
    String? fen,
  }) {
    return AnalysisState(
      enabled: enabled ?? this.enabled,
      running: running ?? this.running,
      error: error,
      eval: eval ?? this.eval,
      fen: fen ?? this.fen,
    );
  }

  /// Eval in pawns from White's perspective, for the eval bar. Null when
  /// only a mate score is known (callers show `#n` instead).
  double? get whitePawns {
    final e = eval;
    final f = fen;
    if (e?.scoreCp == null || f == null) return null;
    final whiteToMove = f.split(' ')[1] == 'w';
    final cp = e!.scoreCp!;
    return (whiteToMove ? cp : -cp) / 100.0;
  }

  /// Display string like `+0.85`, `-1.20` or `#5` (White's perspective).
  String? get scoreLabel {
    final e = eval;
    final f = fen;
    if (e == null || f == null) return null;
    final whiteToMove = f.split(' ')[1] == 'w';
    if (e.scoreMate != null) {
      final mate = whiteToMove ? e.scoreMate! : -e.scoreMate!;
      return mate >= 0 ? '#$mate' : '#$mate';
    }
    if (e.scoreCp != null) {
      final pawns = (whiteToMove ? e.scoreCp! : -e.scoreCp!) / 100.0;
      return '${pawns >= 0 ? '+' : ''}${pawns.toStringAsFixed(2)}';
    }
    return null;
  }
}

/// Drives the engine from the game session: debounces position changes and
/// serializes searches (`stop` → wait for `bestmove` → `position`/`go`),
/// which the UCI protocol requires to avoid interleaved output.
class AnalysisNotifier extends Notifier<AnalysisState> {
  UciEngine? _engine;
  StreamSubscription<String>? _subscription;
  Timer? _debounce;

  /// FEN of the search currently running on the engine, if any.
  String? _searchingFen;

  /// Position to analyze next, set while a previous search is being stopped.
  String? _pendingFen;

  @override
  AnalysisState build() {
    ref.listen(gameSessionProvider, (previous, next) {
      // Display-only boards (unvalidated diagram placements) aren't analyzed.
      if (!next.legal) return;
      if (previous?.fen != next.fen) _onPositionChanged(next.fen);
    });
    ref.onDispose(stopEngine);
    return const AnalysisState();
  }

  /// Stops and disposes the engine, if running. Safe to call when no engine
  /// has been started. Used both on provider disposal and when the app is
  /// quitting, so the native Stockfish process isn't left blocked on a
  /// `read()` that would otherwise hang Dart VM shutdown.
  Future<void> stopEngine() async {
    _debounce?.cancel();
    await _subscription?.cancel();
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
  }

  Future<void> toggle() async {
    if (state.enabled) {
      _debounce?.cancel();
      if (_searchingFen != null) _engine?.send('stop');
      _searchingFen = null;
      _pendingFen = null;
      state = const AnalysisState(enabled: false, running: true);
      return;
    }
    state = state.copyWith(enabled: true);
    try {
      await _ensureStarted();
      _onPositionChanged(ref.read(gameSessionProvider).fen);
    } catch (e) {
      state = AnalysisState(enabled: false, error: 'Engine failed: $e');
    }
  }

  Future<void> _ensureStarted() async {
    if (_engine != null) return;
    final engine = createEngine();
    await engine.start();
    _subscription = engine.lines.listen(_onLine);
    final threads = ref.read(settingsProvider).engineThreads;
    engine.send('setoption name Threads value $threads');
    engine.send('setoption name Hash value 128');
    _engine = engine;
    state = state.copyWith(running: true);
  }

  void _onPositionChanged(String fen) {
    if (!state.enabled || _engine == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _requestSearch(fen);
    });
  }

  void _requestSearch(String fen) {
    final engine = _engine;
    if (engine == null || !state.enabled) return;
    if (_searchingFen == fen) return;
    if (_searchingFen != null) {
      // A search is running: stop it and start the new one on `bestmove`.
      _pendingFen = fen;
      engine.send('stop');
      return;
    }
    _startSearch(fen);
  }

  void _startSearch(String fen) {
    final engine = _engine!;
    _searchingFen = fen;
    state = state.copyWith(eval: null, fen: fen);
    final depth = ref.read(settingsProvider).engineDepth;
    engine.send('position fen $fen');
    engine.send('go depth $depth');
  }

  void _onLine(String line) {
    final fen = _searchingFen;
    if (parseBestmove(line) != null) {
      _searchingFen = null;
      final pending = _pendingFen;
      _pendingFen = null;
      if (pending != null && state.enabled) _startSearch(pending);
      return;
    }
    if (fen == null || !state.enabled) return;
    final info = parseInfoLine(line);
    if (info != null && info.hasScore) {
      state = state.copyWith(eval: info, fen: fen);
    }
  }
}

final analysisProvider =
    NotifierProvider<AnalysisNotifier, AnalysisState>(AnalysisNotifier.new);

/// The engine's principal variation rendered as SAN from the analyzed
/// position, e.g. `["Nf3", "Nc6", "Bb5"]`. Empty when unavailable.
List<String> pvToSan(String fen, List<String> pvUci, {int maxMoves = 8}) {
  Position position;
  try {
    position = Chess.fromSetup(Setup.parseFen(fen));
  } catch (_) {
    return const [];
  }
  final sans = <String>[];
  for (final uci in pvUci.take(maxMoves)) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    final (next, san) = position.makeSan(move);
    sans.add(san);
    position = next;
  }
  return sans;
}
