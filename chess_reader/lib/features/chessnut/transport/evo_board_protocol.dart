import 'dart:typed_data';

import '../codec/chessnut_codec.dart';
import '../model/chessnut_constants.dart';

/// Translates between the Evo's on-device board service and the packets the
/// Chessnut controller already understands, so the controller does not care
/// whether a board is reached over Bluetooth or through the Evo's service.
class EvoBoardProtocol {
  EvoBoardProtocol._();

  /// Colour of a lit square (amber), as red, green, blue.
  static const ledColor = [255, 170, 0];

  /// Wraps the service's FEN into a Bluetooth-style position report
  /// (`01 24`, 32 board bytes, 4 trailing bytes). Null for an unusable FEN.
  static Uint8List? fenToReport(String? fen) {
    if (fen == null || fen.trim().isEmpty) return null;
    try {
      final packet = Uint8List(ChessnutConstants.fenReportLength)
        ..[0] = 0x01
        ..[1] = 0x24;
      packet.setRange(
        2,
        34,
        ChessnutCodec.placementToBoardBytes(
          ChessnutCodec.extractPlacement(fen),
        ),
      );
      return packet;
    } on FormatException {
      return null;
    }
  }

  /// Index of a controller square (rank 8 first, h-file first inside a rank,
  /// as in the position report) in the service's 64-entry LED arrays.
  ///
  /// The service documents only "8 x 8 with index row * 8 + column". Row 0 is
  /// assumed to be rank 8 and column 0 the a-file, like the FEN. Not yet
  /// confirmed on a board.
  static int ledIndex(int square) {
    final row = square ~/ 8;
    final column = 7 - square % 8;
    return row * 8 + column;
  }

  /// The squares lit by a Move/Evo `43 20` LED command.
  static Set<int> litSquares(Uint8List command) {
    final lit = <int>{};
    if (command.length < 34 || command[0] != 0x43 || command[1] != 0x20) {
      return lit;
    }
    for (var square = 0; square < 64; square++) {
      final nibble = (command[2 + square ~/ 2] >> ((square % 2) * 4)) & 0x0f;
      if (nibble != 0) lit.add(square);
    }
    return lit;
  }

  /// Arguments for the service's `setLed` call: one on/off byte per square and
  /// three colour bytes per square, both in service order.
  static ({Uint8List on, Uint8List rgb}) ledArguments(Set<int> squares) {
    final on = Uint8List(64);
    final rgb = Uint8List(192);
    for (final square in squares) {
      if (square < 0 || square >= 64) continue;
      final index = ledIndex(square);
      on[index] = 1;
      rgb[index * 3] = ledColor[0];
      rgb[index * 3 + 1] = ledColor[1];
      rgb[index * 3 + 2] = ledColor[2];
    }
    return (on: on, rgb: rgb);
  }
}
