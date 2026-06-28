import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Native on-device OCR (Apple Vision) — see NativeOcrPlugin / the Dart
    // NativeTextRecognizer. Registered manually since it isn't a pub plugin.
    if let registrar = flutterViewController.registrar(forPlugin: "NativeOcrPlugin") {
      NativeOcrPlugin.register(with: registrar)
    }

    super.awakeFromNib()
  }
}
