import CoreGraphics
import FlutterMacOS
import Foundation
import Vision

/// Bridges the `chess_reader/native_ocr` method channel to Apple Vision's
/// on-device text recognizer on macOS (the same `VNRecognizeTextRequest` API
/// the iOS plugin uses). Receives a page raster as raw BGRA bytes and returns
/// recognized lines as `[{text, l, t, w, h}]` in source-pixel coordinates
/// (top-left origin), which the Dart side reassembles into page text. Runs off
/// the platform thread; replies on the main thread.
public class NativeOcrPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "chess_reader/native_ocr",
      binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(NativeOcrPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "recognize",
          let args = call.arguments as? [String: Any],
          let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data,
          let width = args["width"] as? Int,
          let height = args["height"] as? Int,
          width > 0, height > 0
    else {
      result(FlutterMethodNotImplemented)
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      let lines = NativeOcrPlugin.recognize(bgra: bytes, width: width, height: height)
      DispatchQueue.main.async { result(lines) }
    }
  }

  /// Runs Vision text recognition over the BGRA raster. Returns [] on any
  /// failure so the Dart side falls back gracefully.
  private static func recognize(bgra: Data, width: Int, height: Int) -> [[String: Any]] {
    guard bgra.count >= width * height * 4 else { return [] }

    // BGRA8888 little-endian == premultipliedFirst + byteOrder32Little.
    let bitmapInfo = CGBitmapInfo(
      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = CGDataProvider(data: bgra as CFData),
          let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    else { return [] }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return []
    }

    let w = CGFloat(width)
    let h = CGFloat(height)
    var out: [[String: Any]] = []
    for obs in (request.results ?? []) {
      guard let top = obs.topCandidates(1).first else { continue }
      // Vision boxes are normalized with a bottom-left origin; convert to
      // top-left pixel coordinates to match the ONNX pipeline's TextBox.
      let bb = obs.boundingBox
      out.append([
        "text": top.string,
        "l": Int((bb.minX * w).rounded()),
        "t": Int(((1 - bb.maxY) * h).rounded()),
        "w": Int((bb.width * w).rounded()),
        "h": Int((bb.height * h).rounded()),
      ])
    }
    return out
  }
}
