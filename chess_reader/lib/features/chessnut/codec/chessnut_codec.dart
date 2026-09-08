import 'dart:typed_data';
import 'package:dartchess/dartchess.dart';

import '../model/chessnut_constants.dart';
import '../model/chessnut_state.dart';

/// Pure codec for Chessnut Move BLE protocol packets, square indexing,
/// piece nibble encoding, commands, queries, responses, and inventory validation.
class ChessnutCodec {
  ChessnutCodec._();

  static const List<String> _pieceByNibble = [
    '', // 0: Empty
    'q', // 1: Black Queen
    'k', // 2: Black King
    'b', // 3: Black Bishop
    'p', // 4: Black Pawn
    'n', // 5: Black Knight
    'R', // 6: White Rook
    'P', // 7: White Pawn
    'r', // 8: Black Rook
    'B', // 9: White Bishop
    'N', // 10: White Knight
    'Q', // 11: White Queen
    'K', // 12: White King
  ];

  static final Map<String, int> _nibbleByPiece = {
    'q': 1,
    'k': 2,
    'b': 3,
    'p': 4,
    'n': 5,
    'R': 6,
    'P': 7,
    'r': 8,
    'B': 9,
    'N': 10,
    'Q': 11,
    'K': 12,
  };

  /// Nominal piece order for the 34 motorized pieces.
  static const List<String> nominalPieceOrder = [
    // White: 8 Pawns, 2 Rooks, 2 Knights, 2 Bishops, 2 Queens, 1 King
    'P', 'P', 'P', 'P', 'P', 'P', 'P', 'P',
    'R', 'R', 'N', 'N', 'B', 'B', 'Q', 'Q', 'K',
    // Black: 8 Pawns, 2 Rooks, 2 Knights, 2 Bishops, 2 Queens, 1 King
    'p', 'p', 'p', 'p', 'p', 'p', 'p', 'p',
    'r', 'r', 'n', 'n', 'b', 'b', 'q', 'q', 'k',
  ];

  /// Extracts the placement part (field 1) of a FEN string.
  static String extractPlacement(String fen) {
    final trimmed = fen.trim();
    final space = trimmed.indexOf(' ');
    return space == -1 ? trimmed : trimmed.substring(0, space);
  }

  /// Converts a standard dartchess [Square] into Chessnut board square index (0..63).
  ///
  /// Chessnut ordering:
  /// Index 0: h8, Index 1: g8, ..., Index 7: a8,
  /// Index 8: h7, ..., Index 63: a1.
  static int squareToChessnutIndex(Square square) {
    return (7 - square.rank) * 8 + (7 - square.file);
  }

  /// Converts a Chessnut board square index (0..63) into a standard dartchess [Square].
  static Square chessnutIndexToSquare(int index) {
    final rank = 7 - (index ~/ 8);
    final file = 7 - (index % 8);
    return Square(rank * 8 + file);
  }

  /// Converts a 64-square FEN placement string into 32 bytes of board data.
  static Uint8List placementToBoardBytes(String placement) {
    final cleanPlacement = extractPlacement(placement);
    final boardData = Uint8List(32);
    final rows = cleanPlacement.split('/');
    if (rows.length != 8) {
      throw FormatException('Invalid FEN placement rows: ${rows.length}');
    }

    final squareNibbles = Uint8List(64);

    for (var rankIndex = 0; rankIndex < 8; rankIndex++) {
      final row = rows[rankIndex];
      var fileIndex = 0;
      for (var charIndex = 0; charIndex < row.length; charIndex++) {
        final char = row[charIndex];
        final emptyCount = int.tryParse(char);
        if (emptyCount != null) {
          if (emptyCount < 1 || emptyCount > 8 || fileIndex + emptyCount > 8) {
            throw FormatException('Invalid empty-square count in row: $row');
          }
          for (var i = 0; i < emptyCount; i++) {
            final chessnutIdx = rankIndex * 8 + (7 - fileIndex);
            squareNibbles[chessnutIdx] = 0;
            fileIndex++;
          }
        } else {
          final nibble = _nibbleByPiece[char];
          if (nibble == null) {
            throw FormatException(
              'Invalid piece character in placement: $char',
            );
          }
          if (fileIndex >= 8) {
            throw FormatException('Too many files in row: $row');
          }
          final chessnutIdx = rankIndex * 8 + (7 - fileIndex);
          squareNibbles[chessnutIdx] = nibble;
          fileIndex++;
        }
      }
      if (fileIndex != 8) {
        throw FormatException('Row $rankIndex does not contain 8 files: $row');
      }
    }

    for (var p = 0; p < 32; p++) {
      final low = squareNibbles[2 * p] & 0x0F;
      final high = squareNibbles[2 * p + 1] & 0x0F;
      boardData[p] = low | (high << 4);
    }

    return boardData;
  }

  /// Converts 32 bytes of Chessnut board data starting at [offset] into a FEN placement string.
  static String boardBytesToPlacement(Uint8List bytes, [int offset = 0]) {
    if (offset < 0 || bytes.length < offset + 32) {
      throw FormatException(
        'Packet too short for board data: ${bytes.length} < ${offset + 32}',
      );
    }

    final squareNibbles = Uint8List(64);
    for (var p = 0; p < 32; p++) {
      final b = bytes[offset + p];
      squareNibbles[2 * p] = b & 0x0F;
      squareNibbles[2 * p + 1] = (b >> 4) & 0x0F;
    }

    final buffer = StringBuffer();
    for (var rankIndex = 0; rankIndex < 8; rankIndex++) {
      var emptyCount = 0;
      for (var fileIndex = 0; fileIndex < 8; fileIndex++) {
        final chessnutIdx = rankIndex * 8 + (7 - fileIndex);
        final nibble = squareNibbles[chessnutIdx];
        if (nibble >= _pieceByNibble.length) {
          throw FormatException('Invalid piece nibble: $nibble');
        }
        final piece = _pieceByNibble[nibble];
        if (piece.isEmpty) {
          emptyCount++;
        } else {
          if (emptyCount > 0) {
            buffer.write(emptyCount);
            emptyCount = 0;
          }
          buffer.write(piece);
        }
      }
      if (emptyCount > 0) {
        buffer.write(emptyCount);
      }
      if (rankIndex < 7) {
        buffer.write('/');
      }
    }

    return buffer.toString();
  }

  /// Decodes a 38-byte FEN report packet from the board.
  static String? decodeFenReport(Uint8List packet) {
    if (packet.length < ChessnutConstants.fenReportLength) return null;
    try {
      return boardBytesToPlacement(packet, 2);
    } catch (_) {
      return null;
    }
  }

  /// Encodes command to set target position for auto-moves (35 bytes).
  ///
  /// [force] = false sets forceFlag to 1 (non-force mode so manual touch halts auto-move).
  static Uint8List encodeTargetPositionCommand(
    String placement, {
    bool force = false,
  }) {
    final boardData = placementToBoardBytes(placement);
    final command = Uint8List(ChessnutConstants.setTargetCommandLength);
    command[0] = 0x42;
    command[1] = 0x21;
    command.setRange(2, 34, boardData);
    command[34] = force ? 0x00 : 0x01;
    return command;
  }

  /// Encodes command to stop auto-moves mid-motion (35 bytes).
  static Uint8List encodeStopCommand() {
    final command = Uint8List(ChessnutConstants.stopCommandLength);
    command[0] = 0x42;
    command[1] = 0x21;
    // Remaining 33 bytes are zeros
    return command;
  }

  /// Encodes command to enable real-time FEN reporting (3 bytes).
  static Uint8List encodeEnableFenReportingCommand() {
    return Uint8List.fromList([0x21, 0x01, 0x00]);
  }

  /// Encodes command to set square LEDs (34 bytes).
  ///
  /// [squareLeds]: map of Chessnut square index (0..63) to LED color
  /// (0=off, 1=red, 2=green, 3=blue).
  static Uint8List encodeSquareLedsCommand(Map<int, int> squareLeds) {
    final command = Uint8List(ChessnutConstants.setLedsCommandLength);
    command[0] = 0x43;
    command[1] = 0x20;

    for (var p = 0; p < 32; p++) {
      final low = (squareLeds[2 * p] ?? ChessnutConstants.ledOff) & 0x0F;
      final high = (squareLeds[2 * p + 1] ?? ChessnutConstants.ledOff) & 0x0F;
      command[2 + p] = low | (high << 4);
    }

    return command;
  }

  /// Encodes command to highlight specific Chessnut square indices in red (e.g. for mismatch).
  static Uint8List encodeMismatchLedsCommand(Set<int> redSquareIndices) {
    final leds = <int, int>{};
    for (final sq in redSquareIndices) {
      leds[sq] = ChessnutConstants.ledRed;
    }
    return encodeSquareLedsCommand(leds);
  }

  /// Encodes command to turn off all square LEDs (34 bytes).
  static Uint8List encodeClearLedsCommand() {
    final command = Uint8List(ChessnutConstants.setLedsCommandLength);
    command[0] = 0x43;
    command[1] = 0x20;
    return command;
  }

  /// Encodes query for board battery level and charging status (3 bytes).
  static Uint8List encodeBatteryQueryCommand() {
    return Uint8List.fromList([0x41, 0x01, 0x0C]);
  }

  /// Decodes battery status response packet (5 bytes).
  static ChessnutBatteryState? decodeBatteryResponse(Uint8List packet) {
    if (packet.length < ChessnutConstants.batteryResponseLength) return null;
    if (packet[0] != 0x41 || packet[1] != 0x03 || packet[2] != 0x0C) {
      return null;
    }

    final charging = packet[3] == 1;
    final level = packet[4].clamp(0, 100);
    return ChessnutBatteryState(level: level, charging: charging);
  }

  /// Encodes query for 34 motorized piece coordinates and battery levels (3 bytes).
  static Uint8List encodePieceStatusQueryCommand() {
    return Uint8List.fromList([0x41, 0x01, 0x0B]);
  }

  /// Decodes piece status response packet (139 bytes).
  static List<ChessnutPieceStatus>? decodePieceStatusResponse(
    Uint8List packet,
  ) {
    if (packet.length < ChessnutConstants.pieceStatusResponseLength) {
      return null;
    }
    if (packet[0] != 0x41 || packet[1] != 0x89 || packet[2] != 0x0B) {
      return null;
    }

    final list = <ChessnutPieceStatus>[];
    for (var i = 0; i < ChessnutConstants.totalNominalPieces; i++) {
      final offset = 3 + i * 4;
      final pieceChar = i < nominalPieceOrder.length
          ? nominalPieceOrder[i]
          : '?';
      final x = packet[offset + 1];
      final y = packet[offset + 2];
      final bat = packet[offset + 3].clamp(0, 100);

      list.add(
        ChessnutPieceStatus(
          pieceIndex: i,
          pieceChar: pieceChar,
          x: x,
          y: y,
          battery: bat,
        ),
      );
    }
    return list;
  }

  /// Validates that a target placement does not exceed physical piece inventory limits.
  ///
  /// Hardware limits per color:
  /// Pawns: max 8, Rooks: max 2, Knights: max 2, Bishops: max 2, Queens: max 2, King: max 1.
  /// Max total pieces per color on board: 16.
  static ChessnutInventoryCheck validateInventory(String placement) {
    final cleanPlacement = extractPlacement(placement);
    try {
      placementToBoardBytes(cleanPlacement);
    } on FormatException catch (e) {
      return ChessnutInventoryCheck.invalid(e.message);
    }
    final counts = <String, int>{};

    for (var i = 0; i < cleanPlacement.length; i++) {
      final char = cleanPlacement[i];
      if (char == '/' ||
          (char.codeUnitAt(0) >= 48 && char.codeUnitAt(0) <= 57)) {
        continue;
      }
      counts[char] = (counts[char] ?? 0) + 1;
    }

    final whitePawns = counts['P'] ?? 0;
    final whiteRooks = counts['R'] ?? 0;
    final whiteKnights = counts['N'] ?? 0;
    final whiteBishops = counts['B'] ?? 0;
    final whiteQueens = counts['Q'] ?? 0;
    final whiteKings = counts['K'] ?? 0;
    final totalWhite =
        whitePawns +
        whiteRooks +
        whiteKnights +
        whiteBishops +
        whiteQueens +
        whiteKings;

    final blackPawns = counts['p'] ?? 0;
    final blackRooks = counts['r'] ?? 0;
    final blackKnights = counts['n'] ?? 0;
    final blackBishops = counts['b'] ?? 0;
    final blackQueens = counts['q'] ?? 0;
    final blackKings = counts['k'] ?? 0;
    final totalBlack =
        blackPawns +
        blackRooks +
        blackKnights +
        blackBishops +
        blackQueens +
        blackKings;

    if (whiteKings > ChessnutConstants.maxKingsPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 1 White King (found $whiteKings).',
      );
    }
    if (blackKings > ChessnutConstants.maxKingsPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 1 Black King (found $blackKings).',
      );
    }
    if (whiteQueens > ChessnutConstants.maxQueensPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 2 White Queens (found $whiteQueens).',
      );
    }
    if (blackQueens > ChessnutConstants.maxQueensPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 2 Black Queens (found $blackQueens).',
      );
    }
    if (whiteRooks > ChessnutConstants.maxRooksPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 2 White Rooks (found $whiteRooks).',
      );
    }
    if (blackRooks > ChessnutConstants.maxRooksPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 2 Black Rooks (found $blackRooks).',
      );
    }
    if (whiteBishops > ChessnutConstants.maxBishopsPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 2 White Bishops (found $whiteBishops).',
      );
    }
    if (blackBishops > ChessnutConstants.maxBishopsPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 2 Black Bishops (found $blackBishops).',
      );
    }
    if (whiteKnights > ChessnutConstants.maxKnightsPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 2 White Knights (found $whiteKnights).',
      );
    }
    if (blackKnights > ChessnutConstants.maxKnightsPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 2 Black Knights (found $blackKnights).',
      );
    }
    if (whitePawns > ChessnutConstants.maxPawnsPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 8 White Pawns (found $whitePawns).',
      );
    }
    if (blackPawns > ChessnutConstants.maxPawnsPerColor) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 8 Black Pawns (found $blackPawns).',
      );
    }
    if (totalWhite > ChessnutConstants.maxPiecesPerColorOnBoard) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 16 White pieces on the board (found $totalWhite).',
      );
    }
    if (totalBlack > ChessnutConstants.maxPiecesPerColorOnBoard) {
      return ChessnutInventoryCheck.invalid(
        'Board supports at most 16 Black pieces on the board (found $totalBlack).',
      );
    }

    return const ChessnutInventoryCheck.valid();
  }

  /// Identifies squares where two FEN placements differ. Returns set of Chessnut square indices.
  static Set<int> diffPlacements(String placementA, String placementB) {
    final bytesA = placementToBoardBytes(placementA);
    final bytesB = placementToBoardBytes(placementB);
    final diffSquares = <int>{};

    for (var p = 0; p < 32; p++) {
      final a = bytesA[p];
      final b = bytesB[p];
      if (a != b) {
        final lowA = a & 0x0F;
        final lowB = b & 0x0F;
        if (lowA != lowB) diffSquares.add(2 * p);

        final highA = (a >> 4) & 0x0F;
        final highB = (b >> 4) & 0x0F;
        if (highA != highB) diffSquares.add(2 * p + 1);
      }
    }

    return diffSquares;
  }
}
