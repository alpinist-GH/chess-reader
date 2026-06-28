import 'dart:io' show Platform;

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// Session options that enable a hardware-accelerated ONNX execution provider
/// where the platform (and flutter_onnxruntime) supports one, always listing
/// CPU as a fallback so inference still runs if the accelerator can't compile a
/// given model/op.
///
/// - Apple platforms (macOS, iOS): CoreML (Neural Engine / GPU) → CPU.
/// - Windows / Linux / Android: `null` (default CPU). Windows DirectML is not
///   wired into the plugin's native code yet; Android's heavy OCR uses the
///   device's native recognizer rather than this ONNX path.
OrtSessionOptions? acceleratedSessionOptions() {
  if (Platform.isMacOS || Platform.isIOS) {
    return OrtSessionOptions(providers: [OrtProvider.CORE_ML, OrtProvider.CPU]);
  }
  return null;
}
