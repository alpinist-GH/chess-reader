import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/app_settings.dart';
import '../../../core/state/game_session.dart';
import '../../computer_opponent/state/computer_opponent_provider.dart';
import '../../guess_move/domain/guess_move_models.dart';
import '../../guess_move/state/guess_move_provider.dart';
import '../domain/move_resolver.dart';

/// Nodes use parent IDs rather than FEN identity: transpositions in different
/// branches remain separate, and the first child always retains the main line.
class ReadingMove {
  const ReadingMove(this.parent, this.fen, this.label, this.location, this.uci);
  final int? parent;
  final String fen;
  final String label;
  final String location;
  final String? uci;

  Map<String, dynamic> toJson() => {
    'parent': parent,
    'fen': fen,
    'label': label,
    'location': location,
    'uci': uci,
  };
}

class ReadingAnalysisState {
  const ReadingAnalysisState({this.nodes = const [], this.cursor, this.main});
  final List<ReadingMove> nodes;
  final int? cursor;
  final int? main;
  List<int> children(int id) => [
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i].parent == id) i,
  ];
}

class ReadingAnalysis extends Notifier<ReadingAnalysisState> {
  String? _book;
  bool _navigating = false;

  @override
  ReadingAnalysisState build() {
    ref.listen(gameSessionProvider, (previous, next) {
      if (_book == null ||
          _navigating ||
          previous == null ||
          next.origin == PositionOrigin.computer ||
          next.origin == PositionOrigin.bookReset ||
          ref.read(computerOpponentProvider).ownsBoard ||
          ref.read(guessMoveProvider).phase != GuessMovePhase.idle) {
        return;
      }
      final cursor = state.cursor;
      if (!next.legal) return;
      if (next.onBookLine) {
        if (cursor != null && state.nodes[cursor].fen == next.fen) return;
        final existing = state.nodes.indexWhere((n) => n.fen == next.fen);
        if (existing >= 0) {
          _select(existing, apply: false);
        } else {
          final id = state.nodes.length;
          state = ReadingAnalysisState(
            nodes: [
              ...state.nodes,
              ReadingMove(
                null,
                next.fen,
                'Start position',
                'Diagram / position',
                null,
              ),
            ],
            cursor: id,
            main: id,
          );
          _save();
        }
        return;
      }
      if (cursor == null) return;
      final node = state.nodes[cursor];
      if (node.fen != previous.fen) return;
      // A takeback navigates to its parent without deleting the continuation.
      final parent = node.parent;
      if (parent != null && state.nodes[parent].fen == next.fen) {
        _select(parent, apply: false);
        return;
      }
      final move = next.lastMove;
      if (move == null ||
          !previous.position.isLegal(move) ||
          previous.position.playUnchecked(move).fen != next.fen) {
        return;
      }
      final nodes = [...state.nodes];
      final id = _append(
        nodes,
        cursor,
        next.fen,
        _label(previous.position, move),
        node.location,
        move.uci,
      );
      // Extend the main line only along its first-child path; alternatives
      // retain the last main-line position for direct return.
      state = ReadingAnalysisState(
        nodes: nodes,
        cursor: id,
        main: _onMain(nodes, id) ? id : state.main,
      );
      _save();
    });
    return const ReadingAnalysisState();
  }

  String get _key => 'reading.analysis.v1.${Uri.encodeComponent(_book!)}';

  void open(String? book) {
    _book = book;
    state = const ReadingAnalysisState();
    if (book == null) return;
    try {
      final raw = ref.read(sharedPrefsProvider).getString(_key);
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final nodes = <ReadingMove>[];
      for (final item in data['nodes'] as List) {
        final j = item as Map<String, dynamic>;
        final parent = j['parent'] as int?;
        if (parent != null && (parent < 0 || parent >= nodes.length)) {
          throw const FormatException('Invalid analysis parent');
        }
        final fen = j['fen'] as String;
        Chess.fromSetup(Setup.parseFen(fen));
        final uci = j['uci'] as String?;
        if (parent != null) {
          final before = Chess.fromSetup(Setup.parseFen(nodes[parent].fen));
          final move = uci == null ? null : Move.parse(uci);
          if (move == null ||
              !before.isLegal(move) ||
              before.playUnchecked(move).fen != fen) {
            throw const FormatException('Invalid analysis move');
          }
        }
        nodes.add(
          ReadingMove(
            parent,
            fen,
            j['label'] as String,
            j['location'] as String,
            uci,
          ),
        );
      }
      final cursor = data['cursor'] as int?;
      final main = data['main'] as int?;
      if ([
        cursor,
        main,
      ].any((i) => i != null && (i < 0 || i >= nodes.length))) {
        throw const FormatException('Invalid analysis cursor');
      }
      state = ReadingAnalysisState(nodes: nodes, cursor: cursor, main: main);
      if (cursor != null) _apply(cursor);
    } catch (_) {
      // A damaged analysis must not prevent the book from opening.
      state = const ReadingAnalysisState();
    }
  }

  /// Start a separate game without discarding the book or earlier analysis.
  void newGame(Object sourceKey) {
    final id = state.nodes.length;
    final number =
        state.nodes.where((n) => n.label.startsWith('New game ')).length + 1;
    state = ReadingAnalysisState(
      nodes: [
        ...state.nodes,
        ReadingMove(
          null,
          Chess.initial.fen,
          'New game $number',
          '${sourceKey.runtimeType}:$sourceKey',
          null,
        ),
      ],
      cursor: id,
      main: id,
    );
    _apply(id);
    _save();
  }

  /// Seed the resolved page/chapter so alternatives never replace its moves.
  void selectBookMoves(List<ResolvedMove> moves, int index, Object sourceKey) {
    if (_book == null || moves.isEmpty) return;
    final location = '${sourceKey.runtimeType}:$sourceKey';
    final nodes = [...state.nodes];
    int? selected;
    for (var i = 0; i < moves.length; i++) {
      final resolved = moves[i];
      final currentRoot = state.cursor == null
          ? null
          : _root(nodes, state.cursor!);
      var parent = -1;
      // Prefer the explicitly started game when several games share a page.
      if (currentRoot != null && nodes[currentRoot].location == location) {
        for (var candidate = 0; candidate < nodes.length; candidate++) {
          if (nodes[candidate].location == location &&
              nodes[candidate].fen == resolved.positionBefore.fen &&
              _root(nodes, candidate) == currentRoot) {
            parent = candidate;
            break;
          }
        }
      }
      if (parent < 0) {
        parent = nodes.indexWhere(
          (n) => n.location == location && n.fen == resolved.positionBefore.fen,
        );
      }
      if (parent < 0) {
        parent = nodes.length;
        nodes.add(
          ReadingMove(
            null,
            resolved.positionBefore.fen,
            'Start position',
            location,
            null,
          ),
        );
      }
      final id = _append(
        nodes,
        parent,
        resolved.positionAfter.fen,
        _label(resolved.positionBefore, resolved.move),
        location,
        resolved.move.uci,
      );
      if (i == index) selected = id;
    }
    var main = state.main;
    if (selected != null &&
        (_onMain(nodes, selected) ||
            main == null ||
            _root(nodes, main) != _root(nodes, selected))) {
      main = selected;
    }
    state = ReadingAnalysisState(nodes: nodes, cursor: selected, main: main);
    _save();
  }

  String _label(Position before, Move move) =>
      '${before.fullmoves}${before.turn == Side.white ? '.' : '...'}${before.makeSan(move).$2}';

  int _root(List<ReadingMove> nodes, int id) {
    while (nodes[id].parent != null) {
      id = nodes[id].parent!;
    }
    return id;
  }

  bool _onMain(List<ReadingMove> nodes, int id) {
    var current = id;
    while (nodes[current].parent != null) {
      final parent = nodes[current].parent!;
      if (nodes.indexWhere((n) => n.parent == parent) != current) return false;
      current = parent;
    }
    return true;
  }

  int _append(
    List<ReadingMove> nodes,
    int parent,
    String fen,
    String label,
    String location,
    String uci,
  ) {
    final existing = nodes.indexWhere(
      (n) => n.parent == parent && n.uci == uci,
    );
    if (existing >= 0) return existing;
    nodes.add(ReadingMove(parent, fen, label, location, uci));
    return nodes.length - 1;
  }

  void select(int id) => _select(id);
  void backToMain() {
    final main = state.main;
    if (main != null) _select(main);
  }

  void _select(int id, {bool apply = true}) {
    state = ReadingAnalysisState(
      nodes: state.nodes,
      cursor: id,
      main: state.main,
    );
    if (apply) _apply(id);
    _save();
  }

  void _apply(int id) {
    _navigating = true;
    try {
      final node = state.nodes[id];
      final parsed = node.uci == null ? null : Move.parse(node.uci!);
      ref
          .read(gameSessionProvider.notifier)
          .setPosition(
            Chess.fromSetup(Setup.parseFen(node.fen)),
            lastMove: parsed is NormalMove ? parsed : null,
          );
    } finally {
      _navigating = false;
    }
  }

  void _save() {
    if (_book == null) return;
    ref
        .read(sharedPrefsProvider)
        .setString(
          _key,
          jsonEncode({
            'nodes': [for (final node in state.nodes) node.toJson()],
            'cursor': state.cursor,
            'main': state.main,
          }),
        );
  }
}

final readingAnalysisProvider =
    NotifierProvider<ReadingAnalysis, ReadingAnalysisState>(
      ReadingAnalysis.new,
    );
