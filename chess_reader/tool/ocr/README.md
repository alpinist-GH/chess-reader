# Text-page OCR models

In-app OCR gives scanned / image-only PDFs a text layer so the **reflowed
reading view** (and search / move resolution) work. It runs entirely on-device
through the same `flutter_onnxruntime` runtime the diagram pipeline uses, so it
behaves identically on Windows, macOS, iOS and Android.

Unlike the chess-diagram models in `tool/vision_train` (trained here on
synthetic data), the OCR models are **pretrained PP-OCR (mobile)** models,
vendored as-is.

## Generating the assets (one-time)

```sh
pip install rapidocr-onnxruntime
python tool/ocr/export_ppocr_onnx.py
```

This writes three files consumed by `lib/features/ocr`:

| Asset                         | Role                                            |
| ----------------------------- | ----------------------------------------------- |
| `assets/models/ocr_det.onnx`  | DBNet text-line detector (whole page → prob map) |
| `assets/models/ocr_rec.onnx`  | CRNN/SVTR recognizer (line strip → CTC logits)   |
| `assets/models/ocr_keys.txt`  | Recognition dictionary, one char per line        |

The Dart loader (`onnx_text_recognizer.dart`) builds the CTC class list as
`['<blank>', ...keys, ' ']`, matching PaddleOCR's decoding convention.

## Preprocessing contract (must stay in sync)

`lib/features/ocr/data/ocr_isolate.dart` reproduces the PP-OCR preprocessing the
models were trained with. If you swap models, re-check:

* **Detection** — RGB, `/255`, ImageNet mean `[0.485,0.456,0.406]` / std
  `[0.229,0.224,0.225]`, NCHW, both sides rounded to a multiple of 32.
* **Recognition** — RGB, `(x/255 - 0.5)/0.5`, fixed height `kRecHeight = 48`,
  NCHW, width kept by aspect ratio and capped at `kRecMaxWidth = 320`.

## Other languages

`export_ppocr_onnx.py` defaults to the English/Latin dictionary. For a different
script, point `REC_OUT` and `KEYS_OUT` at the matching PP-OCR rec model +
dictionary; no Dart change is needed as long as the preprocessing above holds.
