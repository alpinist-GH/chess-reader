import 'dart:typed_data';

/// Greedy CTC decoder for the PP-OCR recognition head.
///
/// The recognizer outputs, per timestep, a distribution over the character
/// alphabet. [vocab] index 0 is the CTC *blank*; indices 1..N-1 map to the
/// dictionary characters (PP-OCR convention: `['blank', ...keys, ' ']`).
///
/// Greedy decoding takes the argmax class at each timestep, then collapses runs
/// of the same class and drops blanks — the standard best-path approximation.
/// It is deterministic and adequate for body-text recognition (the reflowed
/// reading view tolerates the occasional error).
class CtcDecoder {
  const CtcDecoder(this.vocab);

  /// Full class list including the blank at index 0.
  final List<String> vocab;

  /// Decodes a flat `[steps, classes]` row-major logit/probability tensor.
  /// Whether the values are logits or softmax probabilities is irrelevant to
  /// the argmax, so no normalization is needed.
  String decode(Float32List flat, int steps, int classes) {
    assert(flat.length == steps * classes);
    assert(classes == vocab.length,
        'tensor classes ($classes) != vocab size (${vocab.length})');
    final buf = StringBuffer();
    var prev = -1; // previous argmax class (for run collapsing)
    for (var t = 0; t < steps; t++) {
      final base = t * classes;
      var best = 0;
      var bestVal = flat[base];
      for (var c = 1; c < classes; c++) {
        final v = flat[base + c];
        if (v > bestVal) {
          bestVal = v;
          best = c;
        }
      }
      // Emit only on a transition to a non-blank class.
      if (best != prev && best != 0) {
        buf.write(vocab[best]);
      }
      prev = best;
    }
    return buf.toString();
  }
}
