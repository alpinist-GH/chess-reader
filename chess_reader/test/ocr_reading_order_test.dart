import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/features/ocr/domain/ocr_box.dart';
import 'package:chess_reader/features/ocr/domain/reading_order.dart';

RecognizedLine _line(String text, int x, int y, {int w = 40, int h = 10}) =>
    RecognizedLine(
      box: TextBox(left: x, top: y, width: w, height: h),
      text: text,
    );

void main() {
  test('orders rows top-to-bottom and lines within a row left-to-right', () {
    // Deliberately out of order on input.
    final lines = [
      _line('world', 60, 0), // same row as "hello", to its right
      _line('second', 0, 20), // next line down
      _line('hello', 0, 0),
    ];
    expect(linesToPageText(lines), 'hello world\nsecond');
  });

  test('a wide vertical gap becomes a paragraph break', () {
    final lines = [
      _line('para one', 0, 0, h: 10),
      _line('still one', 0, 20, h: 10), // gap 10 < 12 -> same paragraph
      _line('para two', 0, 45, h: 10), // gap 15 > 12 -> new paragraph
    ];
    expect(linesToPageText(lines), 'para one\nstill one\n\npara two');
  });

  test('drops blank lines and trims whitespace', () {
    final lines = [
      _line('  keep  ', 0, 0),
      _line('   ', 0, 20), // whitespace-only -> dropped
    ];
    expect(linesToPageText(lines), 'keep');
  });

  test('empty input yields empty string', () {
    expect(linesToPageText(const []), '');
  });
}
