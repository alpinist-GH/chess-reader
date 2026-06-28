import 'package:chessground/chessground.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the side board sits relative to the book pane. [auto] keeps the
/// responsive default (side-by-side on wide screens, a collapsible bottom panel
/// on phones); the rest force that arrangement on any screen size.
enum BoardPlacement { auto, left, right, top, bottom }

/// User preferences, persisted via SharedPreferences.
class AppSettings {
  const AppSettings({
    this.pieceSet = PieceSet.merida,
    this.boardThemeName = 'brown',
    this.engineThreads = 4,
    this.engineDepth = 30,
    this.textScale = 1.0,
    this.boardFraction = 0.4,
    this.themeMode = ThemeMode.system,
    this.boardPlacement = BoardPlacement.auto,
  });

  final PieceSet pieceSet;
  final String boardThemeName;
  final int engineThreads;

  /// Search depth for `go depth N`.
  final int engineDepth;

  /// Multiplier applied to EPUB body text.
  final double textScale;

  /// Fraction of the reader width given to the side board (wide layout).
  final double boardFraction;

  /// Light / dark / follow-system app theme.
  final ThemeMode themeMode;

  /// How the board pane is arranged relative to the book pane.
  final BoardPlacement boardPlacement;

  ChessboardColorScheme get boardColors =>
      boardThemes[boardThemeName] ?? ChessboardColorScheme.brown;

  AppSettings copyWith({
    PieceSet? pieceSet,
    String? boardThemeName,
    int? engineThreads,
    int? engineDepth,
    double? textScale,
    double? boardFraction,
    ThemeMode? themeMode,
    BoardPlacement? boardPlacement,
  }) {
    return AppSettings(
      pieceSet: pieceSet ?? this.pieceSet,
      boardThemeName: boardThemeName ?? this.boardThemeName,
      engineThreads: engineThreads ?? this.engineThreads,
      engineDepth: engineDepth ?? this.engineDepth,
      textScale: textScale ?? this.textScale,
      boardFraction: boardFraction ?? this.boardFraction,
      themeMode: themeMode ?? this.themeMode,
      boardPlacement: boardPlacement ?? this.boardPlacement,
    );
  }
}

/// Named board color schemes offered in settings.
const Map<String, ChessboardColorScheme> boardThemes = {
  'brown': ChessboardColorScheme.brown,
  'blue': ChessboardColorScheme.blue,
  'green': ChessboardColorScheme.green,
  'grey': ChessboardColorScheme.grey,
  'newspaper': ChessboardColorScheme.newspaper,
  'marble': ChessboardColorScheme.marble,
  'maple': ChessboardColorScheme.maple,
};

/// SharedPreferences instance. Overridden in main() after async init.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPrefsProvider not initialized'),
);

class SettingsNotifier extends Notifier<AppSettings> {
  static const _kPieceSet = 'pieceSet';
  static const _kBoardTheme = 'boardTheme';
  static const _kThreads = 'engineThreads';
  static const _kDepth = 'engineDepth';
  static const _kTextScale = 'textScale';
  static const _kBoardFraction = 'boardFraction';
  static const _kThemeMode = 'themeMode';
  static const _kBoardPlacement = 'boardPlacement';

  SharedPreferences get _prefs => ref.read(sharedPrefsProvider);

  @override
  AppSettings build() {
    final p = _prefs;
    return AppSettings(
      pieceSet: PieceSet.values.firstWhere(
        (s) => s.name == p.getString(_kPieceSet),
        orElse: () => PieceSet.merida,
      ),
      boardThemeName: p.getString(_kBoardTheme) ?? 'brown',
      engineThreads: p.getInt(_kThreads) ?? 4,
      engineDepth: p.getInt(_kDepth) ?? 30,
      textScale: p.getDouble(_kTextScale) ?? 1.0,
      boardFraction: p.getDouble(_kBoardFraction) ?? 0.4,
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == p.getString(_kThemeMode),
        orElse: () => ThemeMode.system,
      ),
      boardPlacement: BoardPlacement.values.firstWhere(
        (b) => b.name == p.getString(_kBoardPlacement),
        orElse: () => BoardPlacement.auto,
      ),
    );
  }

  void setPieceSet(PieceSet set) {
    _prefs.setString(_kPieceSet, set.name);
    state = state.copyWith(pieceSet: set);
  }

  void setBoardTheme(String name) {
    _prefs.setString(_kBoardTheme, name);
    state = state.copyWith(boardThemeName: name);
  }

  void setEngineThreads(int threads) {
    _prefs.setInt(_kThreads, threads);
    state = state.copyWith(engineThreads: threads);
  }

  void setEngineDepth(int depth) {
    _prefs.setInt(_kDepth, depth);
    state = state.copyWith(engineDepth: depth);
  }

  void setTextScale(double scale) {
    _prefs.setDouble(_kTextScale, scale);
    state = state.copyWith(textScale: scale);
  }

  void setBoardFraction(double fraction) {
    final clamped = fraction.clamp(0.25, 0.6);
    _prefs.setDouble(_kBoardFraction, clamped);
    state = state.copyWith(boardFraction: clamped);
  }

  void setThemeMode(ThemeMode mode) {
    _prefs.setString(_kThemeMode, mode.name);
    state = state.copyWith(themeMode: mode);
  }

  void setBoardPlacement(BoardPlacement placement) {
    _prefs.setString(_kBoardPlacement, placement.name);
    state = state.copyWith(boardPlacement: placement);
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
