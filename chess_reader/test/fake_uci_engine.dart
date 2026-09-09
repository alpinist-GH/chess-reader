import 'dart:async';

import 'package:chess_reader/features/engine/domain/uci_engine.dart';

/// Test double simulating a UCI engine (Stockfish) with programmable replies.
class FakeUciEngine implements UciEngine {
  StreamController<String> _controller = StreamController<String>.broadcast();
  final List<String> sentCommands = [];
  bool started = false;
  bool disposed = false;
  String? nextBestmove = 'e7e5';
  bool autoRespondBestmove = true;

  /// When true, [start] throws, simulating a missing/broken engine binary.
  bool failOnStart = false;

  @override
  Stream<String> get lines {
    if (_controller.isClosed) {
      _controller = StreamController<String>.broadcast();
    }
    return _controller.stream;
  }

  @override
  Future<void> start() async {
    if (failOnStart) throw StateError('engine unavailable');
    disposed = false;
    started = true;
    if (_controller.isClosed) {
      _controller = StreamController<String>.broadcast();
    }
    _controller.add('id name FakeStockfish');
    _controller.add('option name UCI_LimitStrength type check default false');
    _controller.add('option name UCI_Elo type spin default 1320 min 1320 max 3190');
    _controller.add('uciok');
  }

  @override
  void send(String command) {
    sentCommands.add(command);
    if (command.startsWith('go') && autoRespondBestmove && nextBestmove != null) {
      Timer.run(() {
        if (!disposed && !_controller.isClosed) {
          _controller.add('bestmove $nextBestmove');
        }
      });
    }
  }

  void pushLine(String line) {
    if (!disposed && !_controller.isClosed) {
      _controller.add(line);
    }
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _controller.close();
  }
}
