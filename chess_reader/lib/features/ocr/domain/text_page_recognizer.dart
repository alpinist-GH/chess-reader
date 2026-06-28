import 'dart:typed_data';

/// Reads the body text of a rendered page from its BGRA pixels.
///
/// Two implementations share this contract so the conversion pipeline can pick
/// one at runtime:
///   * `NativeTextRecognizer` — the OS text recognizer (Apple Vision on
///     iOS/macOS, Google ML Kit on Android, Windows.Media.Ocr on Windows); used
///     on every supported platform.
///   * `OcrTextRecognizer` — the bundled on-device ONNX pipeline, kept only as a
///     fallback for platforms without a native recognizer.
abstract class TextPageRecognizer {
  /// Returns the page's body text, or the empty string if nothing is read or
  /// the recognizer is unavailable. [bgra] is row-major BGRA8888.
  Future<String> recognizePage({
    required Uint8List bgra,
    required int width,
    required int height,
  });

  /// Releases any held resources (sessions, channels). Safe to call once.
  Future<void> dispose();
}
