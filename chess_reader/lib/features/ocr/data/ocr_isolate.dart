import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../domain/ocr_box.dart';

/// Height, in pixels, of the strip fed to the recognizer. MUST match the
/// PP-OCR recognition model's fixed input height (PP-OCRv4/v5 mobile: 48).
const int kRecHeight = 48;

/// Max width of a recognizer input strip; longer lines are squashed to fit.
const int kRecMaxWidth = 320;

/// ImageNet normalization used by the PP-OCR *detection* model (RGB, /255).
const List<double> _detMean = [0.485, 0.456, 0.406];
const List<double> _detStd = [0.229, 0.224, 0.225];

// ---- Detection preprocessing -------------------------------------------

/// Sendable page pixels for the detector (BGRA from pdfrx).
class OcrDetRequest {
  const OcrDetRequest({
    required this.bgra,
    required this.width,
    required this.height,
    this.maxSide = 960,
  });

  final Uint8List bgra;
  final int width;
  final int height;

  /// Longest side of the detector input; the page is downscaled to fit.
  final int maxSide;
}

/// The detector input tensor plus the mapping back to source-image pixels.
class OcrDetInput {
  const OcrDetInput({
    required this.tensor,
    required this.inWidth,
    required this.inHeight,
    required this.scaleX,
    required this.scaleY,
  });

  /// NCHW `[1, 3, inHeight, inWidth]`, normalized.
  final Float32List tensor;
  final int inWidth;
  final int inHeight;

  /// source = input * scale, used to map detector boxes back to the page.
  final double scaleX;
  final double scaleY;
}

OcrDetInput _buildDetInput(OcrDetRequest r) {
  final page = img.Image.fromBytes(
    width: r.width,
    height: r.height,
    bytes: r.bgra.buffer,
    order: img.ChannelOrder.bgra,
  );
  // Scale so the longest side is at most maxSide, then round each side to a
  // multiple of 32 (DBNet requires it). Never upscale.
  final longest = r.width > r.height ? r.width : r.height;
  final ratio = longest > r.maxSide ? r.maxSide / longest : 1.0;
  final inW = _round32((r.width * ratio).round());
  final inH = _round32((r.height * ratio).round());
  final resized = img.copyResize(page, width: inW, height: inH);

  final tensor = Float32List(3 * inH * inW);
  final plane = inH * inW;
  var i = 0;
  for (final p in resized) {
    tensor[i] = (p.r / 255.0 - _detMean[0]) / _detStd[0];
    tensor[plane + i] = (p.g / 255.0 - _detMean[1]) / _detStd[1];
    tensor[2 * plane + i] = (p.b / 255.0 - _detMean[2]) / _detStd[2];
    i++;
  }
  return OcrDetInput(
    tensor: tensor,
    inWidth: inW,
    inHeight: inH,
    scaleX: r.width / inW,
    scaleY: r.height / inH,
  );
}

int _round32(int v) {
  final r = (v / 32).round() * 32;
  return r < 32 ? 32 : r;
}

/// Builds the detector input off the UI thread.
Future<OcrDetInput> buildDetInputInIsolate(OcrDetRequest request) =>
    compute(_buildDetInput, request);

// ---- Recognition preprocessing -----------------------------------------

/// Sendable request to crop and normalize each detected line for the
/// recognizer. [boxes] are in source-image pixel coordinates.
class OcrRecRequest {
  const OcrRecRequest({
    required this.bgra,
    required this.width,
    required this.height,
    required this.boxes,
  });

  final Uint8List bgra;
  final int width;
  final int height;
  final List<TextBox> boxes;
}

/// One recognizer input strip: NCHW `[1, 3, kRecHeight, stripWidth]`.
class OcrRecInput {
  const OcrRecInput({required this.tensor, required this.stripWidth});

  final Float32List tensor;
  final int stripWidth;
}

List<OcrRecInput> _buildRecInputs(OcrRecRequest r) {
  final page = img.Image.fromBytes(
    width: r.width,
    height: r.height,
    bytes: r.bgra.buffer,
    order: img.ChannelOrder.bgra,
  );
  final out = <OcrRecInput>[];
  for (final box in r.boxes) {
    final crop = img.copyCrop(page,
        x: box.left, y: box.top, width: box.width, height: box.height);
    // Keep aspect ratio at the fixed height, capped to kRecMaxWidth.
    var w = (kRecHeight * box.width / box.height).round();
    if (w < 1) w = 1;
    if (w > kRecMaxWidth) w = kRecMaxWidth;
    final strip = img.copyResize(crop, width: w, height: kRecHeight);

    // Right-pad to kRecMaxWidth with zeros (post-normalization), so every
    // strip is the same width and CTC has trailing blanks to absorb.
    const stripW = kRecMaxWidth;
    final tensor = Float32List(3 * kRecHeight * stripW);
    final plane = kRecHeight * stripW;
    for (var y = 0; y < kRecHeight; y++) {
      for (var x = 0; x < w; x++) {
        final p = strip.getPixel(x, y);
        final idx = y * stripW + x;
        tensor[idx] = (p.r / 255.0 - 0.5) / 0.5;
        tensor[plane + idx] = (p.g / 255.0 - 0.5) / 0.5;
        tensor[2 * plane + idx] = (p.b / 255.0 - 0.5) / 0.5;
      }
    }
    out.add(OcrRecInput(tensor: tensor, stripWidth: stripW));
  }
  return out;
}

/// Builds all recognizer input strips off the UI thread. One strip per box, in
/// the same order; callers must pass only positive-size boxes (the detector
/// guarantees this).
Future<List<OcrRecInput>> buildRecInputsInIsolate(OcrRecRequest request) =>
    compute(_buildRecInputs, request);
