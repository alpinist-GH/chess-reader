import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_reader/features/ocr/domain/ctc_decoder.dart';

/// Builds a `[steps, classes]` logit tensor that puts all the mass on
/// [argmaxPerStep] at each step (one-hot), so greedy decoding is deterministic.
Float32List _oneHot(List<int> argmaxPerStep, int classes) {
  final t = Float32List(argmaxPerStep.length * classes);
  for (var s = 0; s < argmaxPerStep.length; s++) {
    t[s * classes + argmaxPerStep[s]] = 1.0;
  }
  return t;
}

void main() {
  // vocab: index 0 = blank, then 'a','b','c', then space.
  const decoder = CtcDecoder(['<blank>', 'a', 'b', 'c', ' ']);
  const classes = 5;

  test('collapses repeats and drops blanks', () {
    // a a <blank> a b -> "aab"
    final t = _oneHot([1, 1, 0, 1, 2], classes);
    expect(decoder.decode(t, 5, classes), 'aab');
  });

  test('a blank between identical classes keeps both', () {
    // a <blank> a -> "aa"
    final t = _oneHot([1, 0, 1], classes);
    expect(decoder.decode(t, 3, classes), 'aa');
  });

  test('no blank between identical classes collapses to one', () {
    // a a a -> "a"
    final t = _oneHot([1, 1, 1], classes);
    expect(decoder.decode(t, 3, classes), 'a');
  });

  test('all blank decodes to empty string', () {
    final t = _oneHot([0, 0, 0], classes);
    expect(decoder.decode(t, 3, classes), '');
  });

  test('spells a word with the space class', () {
    // c a b <space> c -> "cab c"
    final t = _oneHot([3, 1, 2, 4, 3], classes);
    expect(decoder.decode(t, 5, classes), 'cab c');
  });

  test('argmax is taken over the full distribution, not just one-hot', () {
    // Step favoring class 2 ('b') by a small margin.
    final t = Float32List.fromList([0.1, 0.2, 0.9, 0.0, 0.0]);
    expect(decoder.decode(t, 1, classes), 'b');
  });
}
