import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../domain/ocr_box.dart';
import '../domain/reading_order.dart';
import '../domain/text_page_recognizer.dart';

/// Page-text OCR backed by the operating system's on-device text recognizer:
/// Apple Vision (`VNRecognizeTextRequest`) on iOS and macOS, Google ML Kit Text
/// on Android, and Windows.Media.Ocr on Windows. Reached over a platform
/// channel; the native side receives the raw BGRA raster and returns recognized
/// lines with pixel bounding boxes, which we reassemble into page text with the
/// same reading-order logic the (now unused) ONNX path used.
///
/// Available on every supported platform — see [isSupported]. If the channel
/// errors, [recognizePage] returns the empty string so the caller falls back
/// exactly as if no text were found.
class NativeTextRecognizer implements TextPageRecognizer {
  NativeTextRecognizer();

  static const MethodChannel _channel =
      MethodChannel('chess_reader/native_ocr');

  /// Whether a native recognizer exists on this platform.
  static bool get isSupported =>
      Platform.isIOS ||
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isWindows;

  @override
  Future<String> recognizePage({
    required Uint8List bgra,
    required int width,
    required int height,
  }) async {
    if (!isSupported) return '';
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('recognize', {
        'bytes': bgra,
        'width': width,
        'height': height,
      });
      if (result == null || result.isEmpty) return '';

      final lines = <RecognizedLine>[];
      for (final entry in result) {
        final m = (entry as Map).cast<dynamic, dynamic>();
        final text = (m['text'] as String?)?.trim() ?? '';
        if (text.isEmpty) continue;
        lines.add(RecognizedLine(
          text: text,
          box: TextBox(
            left: (m['l'] as num).round(),
            top: (m['t'] as num).round(),
            width: (m['w'] as num).round(),
            height: (m['h'] as num).round(),
          ),
        ));
      }
      return linesToPageText(lines);
    } on PlatformException {
      return '';
    } on MissingPluginException {
      return '';
    }
  }

  @override
  Future<void> dispose() async {}
}
