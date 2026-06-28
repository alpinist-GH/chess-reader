package com.alpinist.chessbook_reader

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Bridges the `chess_reader/native_ocr` method channel to Google ML Kit's
/// on-device text recognizer. Receives a page raster as raw BGRA bytes and
/// returns recognized lines as `[{text, l, t, w, h}]` in source-pixel
/// coordinates, which the Dart side reassembles into page text.
class MainActivity : FlutterActivity() {
    private val channelName = "chess_reader/native_ocr"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "recognize") {
                    val bytes = call.argument<ByteArray>("bytes")
                    val width = call.argument<Int>("width")
                    val height = call.argument<Int>("height")
                    if (bytes == null || width == null || height == null ||
                        width <= 0 || height <= 0
                    ) {
                        result.error("bad_args", "missing/invalid arguments", null)
                    } else {
                        recognize(bytes, width, height, result)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun recognize(
        bgra: ByteArray,
        width: Int,
        height: Int,
        result: MethodChannel.Result,
    ) {
        // BGRA bytes -> ARGB int pixels (Bitmap.createBitmap takes ARGB ints,
        // sidestepping any in-memory byte-order ambiguity).
        val pixels = IntArray(width * height)
        var i = 0
        for (p in pixels.indices) {
            val b = bgra[i].toInt() and 0xFF
            val g = bgra[i + 1].toInt() and 0xFF
            val r = bgra[i + 2].toInt() and 0xFF
            val a = bgra[i + 3].toInt() and 0xFF
            pixels[p] = (a shl 24) or (r shl 16) or (g shl 8) or b
            i += 4
        }
        val bitmap = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
        val image = InputImage.fromBitmap(bitmap, 0)
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

        recognizer.process(image)
            .addOnSuccessListener { visionText ->
                val out = ArrayList<HashMap<String, Any>>()
                for (block in visionText.textBlocks) {
                    for (line in block.lines) {
                        val box = line.boundingBox ?: continue
                        out.add(
                            hashMapOf(
                                "text" to line.text,
                                "l" to box.left,
                                "t" to box.top,
                                "w" to box.width(),
                                "h" to box.height(),
                            )
                        )
                    }
                }
                result.success(out)
            }
            .addOnFailureListener { e -> result.error("mlkit", e.message, null) }
            .addOnCompleteListener { recognizer.close() }
    }
}
