import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Creates an [OrtSession] from a bundled ONNX [assetKey], extracting it to a
/// temp file whose name is keyed by a hash of the model BYTES.
///
/// Why not `OnnxRuntime.createSessionFromAsset`: that method extracts to
/// `<temp>/<basename>` and SKIPS the copy if a file with that name already
/// exists. ONNX Runtime needs a file path, so the model must be unpacked — but
/// because the temp name is just the asset's basename, an app update that ships
/// a CHANGED model under the SAME filename keeps loading the PREVIOUS version's
/// leftover temp file. That silently ran the old (pre-finetune) square
/// classifier even though the new model was bundled, so retrained diagrams kept
/// misreading (e.g. a white queen read as black). Keying the temp file by a
/// content hash means a changed model lands at a new path and is re-extracted,
/// while an unchanged model is still reused without rewriting.
Future<OrtSession> createOnnxSessionFromAssetVersioned(
  OnnxRuntime rt,
  String assetKey, {
  OrtSessionOptions? options,
}) async {
  final data = await rootBundle.load(assetKey);
  final bytes = data.buffer.asUint8List();
  final base = assetKey.split('/').last.replaceFirst(RegExp(r'\.onnx$'), '');
  final tag = _contentHash(bytes);
  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, '$base.$tag.onnx'));
  // Rewrite if missing or a previous partial write left a wrong-sized file.
  if (!await file.exists() || await file.length() != bytes.length) {
    await file.writeAsBytes(bytes, flush: true);
  }
  return rt.createSession(file.path, options: options);
}

/// 64-bit FNV-1a over [bytes], masked to 53 bits (an exact int everywhere),
/// as a hex string. Not cryptographic — just a fast, stable key that changes
/// whenever the model bytes change.
String _contentHash(Uint8List bytes) {
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final b in bytes) {
    hash = (hash ^ b) * prime;
  }
  return (hash & 0x1fffffffffffff).toRadixString(16);
}
