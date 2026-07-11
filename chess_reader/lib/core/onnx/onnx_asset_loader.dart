import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/fnv_hash.dart';

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
  final tag = fnv1aHex(bytes);
  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, '$base.$tag.onnx'));
  // Rewrite if missing or a previous partial write left a wrong-sized file.
  if (!await file.exists() || await file.length() != bytes.length) {
    // On macOS/iOS, getTemporaryDirectory() maps to NSCachesDirectory, which
    // path_provider_foundation's getTemporaryPath() returns WITHOUT creating
    // (unlike its getApplicationCachePath() sibling, which does). On a fresh
    // sandboxed container that directory doesn't exist yet, so the write
    // below fails outright — silently dropping every diagram in the book,
    // since the caller treats "can't load the model" as "no accelerator".
    await dir.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }
  return rt.createSession(file.path, options: options);
}
