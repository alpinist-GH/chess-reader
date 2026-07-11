import 'dart:io' show Platform;

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// Session options that request a hardware-accelerated ONNX execution
/// provider where the platform (and flutter_onnxruntime) supports one.
///
/// - Apple platforms (macOS, iOS): CoreML (Neural Engine / GPU).
/// - Windows / Linux / Android: `null` (default CPU). Windows DirectML is not
///   wired into the plugin's native code yet; Android's heavy OCR uses the
///   device's native recognizer rather than this ONNX path.
///
/// IMPORTANT: despite listing [OrtProvider.CPU] after [OrtProvider.CORE_ML],
/// this does NOT make CPU a real fallback by itself. flutter_onnxruntime's
/// native macOS/iOS `createSession` aborts the whole session with an error the
/// moment `appendCoreMLExecutionProvider()` throws — it never falls through to
/// a CPU-only session. A caller that wants inference to keep working when
/// CoreML can't compile a model on a given build must retry session creation
/// with `options: null` itself; see `OnnxSquareClassifier._createSession`.
OrtSessionOptions? acceleratedSessionOptions() {
  if (Platform.isMacOS || Platform.isIOS) {
    return OrtSessionOptions(providers: [OrtProvider.CORE_ML, OrtProvider.CPU]);
  }
  return null;
}
