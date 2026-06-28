import 'dart:io';

import 'package:path/path.dart' as p;

/// Finds a bundled OCR model file on desktop platforms.
///
/// The ONNX OCR pipeline only runs on desktop now — mobile uses the device's
/// native recognizer (Apple Vision / ML Kit), so the ~13 MB OCR models are NOT
/// shipped in the mobile bundle. To keep them out of the IPA/APK they are no
/// longer declared as Flutter assets; instead the desktop builds place them next
/// to the app and this resolves the path at runtime (mirrors `locateStockfish`).
///
/// Search order:
/// 1. next to the app executable (Windows release: `data/models/`, copied by
///    windows/CMakeLists.txt).
/// 2. inside the macOS `.app` bundle (`../Resources/models/`, copied by the
///    Runner "Bundle OCR models" build phase).
/// 3. a bare `models/` next to the executable.
/// 4. the project's `assets/models/` (development runs: `flutter run` / tests
///    execute with cwd = project root, where the files still live in the repo).
///
/// Returns null if the file can't be found (e.g. on mobile, or a model absent),
/// in which case the caller falls back to an empty text layer exactly as if no
/// OCR were available.
String? locateOcrModel(String filename) {
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final candidates = [
    p.join(exeDir, 'data', 'models', filename),
    p.join(exeDir, '..', 'Resources', 'models', filename),
    p.join(exeDir, 'models', filename),
    p.join(Directory.current.path, 'assets', 'models', filename),
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
