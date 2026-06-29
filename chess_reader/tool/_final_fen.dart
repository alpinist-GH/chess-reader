// Prints, per board, the FINAL position the app would render: the shipped
// post-processing (isPlausibleDiagram gate -> repairToLegal -> assembleFen) on
// real CNN readings produced by tool/vision_train/_infer2.py. Use to see exactly
// what each real_cells board resolves to in-app.
//
// Usage: dart run tool/_final_fen.dart <readings.json>
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chess_reader/features/vision/domain/board_repair.dart';
import 'package:chess_reader/features/vision/domain/board_validator.dart';
import 'package:chess_reader/features/vision/domain/fen_assembler.dart';

void main(List<String> args) {
  final boards = (jsonDecode(File(args[0]).readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  for (final b in boards) {
    final labels = (b['labels'] as List).cast<String>();
    final probs = [
      for (final row in (b['probs'] as List))
        Float32List.fromList(
            [for (final v in (row as List)) (v as num).toDouble()])
    ];
    final confidences =
        [for (final row in probs) row.reduce((a, c) => a > c ? a : c)];
    final plausible = isPlausibleDiagram(labels, confidences: confidences);
    final repaired = assembleFen(repairToLegal(labels, probs));
    final raw = assembleFen(labels);
    final changed = raw != repaired ? '  (repaired from $raw)' : '';
    print('${b['id']}: ${plausible ? '' : '[SKIPPED non-board] '}$repaired$changed');
  }
}
