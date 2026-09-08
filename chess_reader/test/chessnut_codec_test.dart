import 'dart:typed_data';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/features/chessnut/codec/chessnut_codec.dart';

void main() {
  group('ChessnutCodec square ordering', () {
    test('squareToChessnutIndex maps corners and intermediate squares correctly', () {
      // h8 is index 0
      final h8 = Square.fromName('h8');
      expect(ChessnutCodec.squareToChessnutIndex(h8), 0);
      expect(ChessnutCodec.chessnutIndexToSquare(0), h8);

      // g8 is index 1
      final g8 = Square.fromName('g8');
      expect(ChessnutCodec.squareToChessnutIndex(g8), 1);
      expect(ChessnutCodec.chessnutIndexToSquare(1), g8);

      // a8 is index 7
      final a8 = Square.fromName('a8');
      expect(ChessnutCodec.squareToChessnutIndex(a8), 7);
      expect(ChessnutCodec.chessnutIndexToSquare(7), a8);

      // h7 is index 8
      final h7 = Square.fromName('h7');
      expect(ChessnutCodec.squareToChessnutIndex(h7), 8);
      expect(ChessnutCodec.chessnutIndexToSquare(8), h7);

      // e4: rank 3, file 4 ('e') -> index (7-3)*8 + (7-4) = 35
      final e4 = Square.fromName('e4');
      expect(ChessnutCodec.squareToChessnutIndex(e4), 35);
      expect(ChessnutCodec.chessnutIndexToSquare(35), e4);

      // h1 is index 56
      final h1 = Square.fromName('h1');
      expect(ChessnutCodec.squareToChessnutIndex(h1), 56);
      expect(ChessnutCodec.chessnutIndexToSquare(56), h1);

      // a1 is index 63
      final a1 = Square.fromName('a1');
      expect(ChessnutCodec.squareToChessnutIndex(a1), 63);
      expect(ChessnutCodec.chessnutIndexToSquare(63), a1);
    });
  });

  group('ChessnutCodec placement round-trip', () {
    test('initial chess position encodes and decodes losslessly', () {
      const initialPlacement = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR';
      final bytes = ChessnutCodec.placementToBoardBytes(initialPlacement);
      expect(bytes.length, 32);

      // Check byte 0: h8 (r = 8) and g8 (n = 5).
      // Low nibble = 8, high nibble = 5 -> byte = 0x58
      expect(bytes[0], (5 << 4) | 8);

      // Check byte 3: b8 (n = 5) and a8 (r = 8)
      // square 6 is b8 (low nibble = 5), square 7 is a8 (high nibble = 8) -> 0x85
      expect(bytes[3], (8 << 4) | 5);

      final decoded = ChessnutCodec.boardBytesToPlacement(bytes);
      expect(decoded, initialPlacement);
    });

    test('complex position with promotions and empty squares round-trips losslessly', () {
      const complexPlacement = '8/4P3/8/2k5/8/8/4K2Q/8';
      final bytes = ChessnutCodec.placementToBoardBytes(complexPlacement);
      expect(bytes.length, 32);

      final decoded = ChessnutCodec.boardBytesToPlacement(bytes);
      expect(decoded, complexPlacement);
    });
  });

  group('ChessnutCodec commands', () {
    test('encodeTargetPositionCommand generates 35-byte payload with non-force mode', () {
      const placement = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR';
      final cmd = ChessnutCodec.encodeTargetPositionCommand(placement, force: false);
      expect(cmd.length, 35);
      expect(cmd[0], 0x42);
      expect(cmd[1], 0x21);
      // forceFlag = 1 for non-force
      expect(cmd[34], 1);

      // Verify board bytes embedded
      final boardBytes = ChessnutCodec.placementToBoardBytes(placement);
      expect(cmd.sublist(2, 34), boardBytes);
    });

    test('encodeStopCommand generates 35-byte payload with 33 zero bytes', () {
      final cmd = ChessnutCodec.encodeStopCommand();
      expect(cmd.length, 35);
      expect(cmd[0], 0x42);
      expect(cmd[1], 0x21);
      for (var i = 2; i < 35; i++) {
        expect(cmd[i], 0);
      }
    });

    test('encodeEnableFenReportingCommand generates 3-byte payload [0x21, 0x01, 0x00]', () {
      final cmd = ChessnutCodec.encodeEnableFenReportingCommand();
      expect(cmd, Uint8List.fromList([0x21, 0x01, 0x00]));
    });

    test('encodeSquareLedsCommand encodes red LEDs for specific squares and off for others', () {
      // Light square 0 (h8) and square 1 (g8) in red
      final cmd = ChessnutCodec.encodeMismatchLedsCommand({0, 1});
      expect(cmd.length, 34);
      expect(cmd[0], 0x43);
      expect(cmd[1], 0x20);

      // Byte 2 controls square 0 and 1: low nibble = 1 (red), high nibble = 1 (red) -> 0x11
      expect(cmd[2], 0x11);
      // Other bytes are 0
      for (var i = 3; i < 34; i++) {
        expect(cmd[i], 0);
      }
    });

    test('encodeClearLedsCommand turns off all LEDs', () {
      final cmd = ChessnutCodec.encodeClearLedsCommand();
      expect(cmd.length, 34);
      expect(cmd[0], 0x43);
      expect(cmd[1], 0x20);
      for (var i = 2; i < 34; i++) {
        expect(cmd[i], 0);
      }
    });
  });

  group('ChessnutCodec queries and responses', () {
    test('encodeBatteryQueryCommand is [0x41, 0x01, 0x0C]', () {
      expect(ChessnutCodec.encodeBatteryQueryCommand(), Uint8List.fromList([0x41, 0x01, 0x0C]));
    });

    test('decodeBatteryResponse parses charging and battery percentage', () {
      final response = Uint8List.fromList([0x41, 0x03, 0x0C, 1, 85]);
      final state = ChessnutCodec.decodeBatteryResponse(response);
      expect(state, isNotNull);
      expect(state!.charging, isTrue);
      expect(state.level, 85);
      expect(state.isLow, isFalse);

      final lowResponse = Uint8List.fromList([0x41, 0x03, 0x0C, 0, 12]);
      final lowState = ChessnutCodec.decodeBatteryResponse(lowResponse);
      expect(lowState, isNotNull);
      expect(lowState!.charging, isFalse);
      expect(lowState.level, 12);
      expect(lowState.isLow, isTrue);
    });

    test('decodePieceStatusResponse parses 34 motorized piece statuses', () {
      final packet = Uint8List(139);
      packet[0] = 0x41;
      packet[1] = 0x89;
      packet[2] = 0x0B;

      // Piece 0 (White pawn): x=10, y=20, bat=90
      packet[3] = 1; // piece identity WP
      packet[4] = 10;
      packet[5] = 20;
      packet[6] = 90;

      // Piece 33 (Black king): x=50, y=60, bat=10
      final p33Offset = 3 + 33 * 4;
      packet[p33Offset] = 12; // BK
      packet[p33Offset + 1] = 50;
      packet[p33Offset + 2] = 60;
      packet[p33Offset + 3] = 10;

      final pieces = ChessnutCodec.decodePieceStatusResponse(packet);
      expect(pieces, isNotNull);
      expect(pieces!.length, 34);

      expect(pieces[0].pieceChar, 'P');
      expect(pieces[0].x, 10);
      expect(pieces[0].y, 20);
      expect(pieces[0].battery, 90);
      expect(pieces[0].isLowBattery, isFalse);

      expect(pieces[33].pieceChar, 'k');
      expect(pieces[33].x, 50);
      expect(pieces[33].y, 60);
      expect(pieces[33].battery, 10);
      expect(pieces[33].isLowBattery, isTrue);
    });

    test('decodeFenReport extracts placement FEN from 38-byte notification', () {
      const placement = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR';
      final packet = Uint8List(38);
      packet[0] = 0x21;
      packet[1] = 0x20;
      final boardBytes = ChessnutCodec.placementToBoardBytes(placement);
      packet.setRange(2, 34, boardBytes);

      final decoded = ChessnutCodec.decodeFenReport(packet);
      expect(decoded, placement);
    });
  });

  group('ChessnutCodec inventory validation', () {
    test('valid standard and promotional positions pass inventory check', () {
      expect(
        ChessnutCodec.validateInventory('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR').isValid,
        isTrue,
      );
      // Position with 2 White Queens (nominal max 2) passes
      expect(
        ChessnutCodec.validateInventory('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKB1Q').isValid,
        isTrue,
      );
    });

    test('exceeding queen inventory fails with explicit message', () {
      // 3 White Queens
      final check = ChessnutCodec.validateInventory('8/8/8/8/8/QQQ5/k7/4K3');
      expect(check.isValid, isFalse);
      expect(check.errorMessage, contains('2 White Queens'));
    });

    test('exceeding knight inventory fails with explicit message', () {
      // 3 White Knights
      final check = ChessnutCodec.validateInventory('8/8/8/8/8/NNN5/k7/4K3');
      expect(check.isValid, isFalse);
      expect(check.errorMessage, contains('2 White Knights'));
    });

    test('exceeding king count fails with explicit message', () {
      // 2 White Kings
      final check = ChessnutCodec.validateInventory('8/8/8/8/8/KK6/k7/8');
      expect(check.isValid, isFalse);
      expect(check.errorMessage, contains('1 White King'));
    });

    test('diffPlacements returns indices of changed squares', () {
      const fenA = '8/8/8/8/8/8/4P3/8'; // e2 pawn
      const fenB = '8/8/8/8/4P3/8/8/8'; // e4 pawn
      final diff = ChessnutCodec.diffPlacements(fenA, fenB);

      final e2Idx = ChessnutCodec.squareToChessnutIndex(Square.fromName('e2'));
      final e4Idx = ChessnutCodec.squareToChessnutIndex(Square.fromName('e4'));

      expect(diff, contains(e2Idx));
      expect(diff, contains(e4Idx));
      expect(diff.length, 2);
    });
  });
}
