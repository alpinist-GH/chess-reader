// Runs the annotation extractor over raw seg masks dumped from real book
// pages (192*192 float32 little-endian files, e.g. produced with numpy's
// `mask.tofile(...)` in tool/vision_train), printing the arrows and per-cell
// ink coverage it recovers. Used to eyeball-check arrow endpoints against the
// printed page:
//
//   dart run tool/check_fischer_annotations.dart mask_p40_b3.f32 ...
import 'dart:io';

import 'package:chess_reader/features/vision/domain/annotation_extractor.dart';
import 'package:chess_reader/features/vision/domain/board_annotations.dart';

void main(List<String> args) {
  for (final path in args) {
    final bytes = File(path).readAsBytesSync();
    final mask = bytes.buffer.asFloat32List(0, bytes.length ~/ 4);
    final ex = extractAnnotations(mask);
    final inked = [
      for (var i = 0; i < 64; i++)
        if (ex.cellCoverage[i] >= kAnnotationInkCoverage) i
    ];
    stdout.writeln('$path: arrows=${encodeAnnotations(ex.arrows)} '
        'inkedCells=${inked.length}');
  }
}
