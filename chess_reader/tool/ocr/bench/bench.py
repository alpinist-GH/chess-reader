"""Benchmark OCR recognizer models against the one the app currently ships.

Holds the detector fixed and swaps only the recognizer, so the numbers isolate
the recognizer's cost/quality:

  * SPEED (rec-only) - time each recognizer over a fixed set of real text-line
        crops taken from the bundled scanned book `assets/sample/My System.pdf`.
        This is the variable that changes between models (detection is shared).
  * ACCURACY (CER)   - per-line synthetic crops with known ground truth, clean
        and scan-degraded (blur + noise + JPEG + down/up-scale), small font.

Run:
    tool/vision_train/.venv/Scripts/python.exe tool/ocr/bench/bench.py

Relative timings hold across CPUs (server is ~Nx slower than mobile regardless
of device); only the absolute ms differ from a phone.
"""

from __future__ import annotations

import io
import re
import time
from pathlib import Path

import cv2
import fitz  # PyMuPDF
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from rapidocr_onnxruntime import RapidOCR

REPO = Path(__file__).resolve().parents[3]
PDF = REPO / "assets" / "sample" / "My System.pdf"
MODELS = Path(__file__).resolve().parent / "models"
FONT = r"C:\Windows\Fonts\times.ttf"
DPI = 200

CANDIDATES = [
    ("v3 mobile (CURRENT)", None),
    ("v4 mobile",           MODELS / "ch_PP-OCRv4_rec_infer.onnx"),
    ("v4 SERVER",           MODELS / "ch_PP-OCRv4_rec_server_infer.onnx"),
]

GT_LINES = [
    "The knight on f3 defends the pawn and eyes the e5 square.",
    "After 1.e4 e5 2.Nf3 Nc6 3.Bb5 White pins the knight to the king.",
    "Black should not hurry; a premature advance weakens the queenside.",
    "Nimzowitsch called this the principle of overprotection.",
    "Control of the open file is worth more than a doubled pawn.",
    "The bishop pair grants a lasting advantage in the endgame.",
]


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()


def cer(ref: str, hyp: str) -> float:
    ref, hyp = norm(ref), norm(hyp)
    if not ref:
        return 0.0
    prev = np.arange(len(hyp) + 1)
    for i, rc in enumerate(ref, 1):
        cur = np.empty(len(hyp) + 1, dtype=int)
        cur[0] = i
        for j, hc in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rc != hc))
        prev = cur
    return prev[-1] / len(ref)


def real_line_crops(engine: RapidOCR, n_pages: int) -> list[np.ndarray]:
    """Detect text lines on real scanned pages and return the line-image crops."""
    doc = fitz.open(PDF)
    crops: list[np.ndarray] = []
    for page in list(doc)[:n_pages]:
        pix = page.get_pixmap(dpi=DPI)
        img = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.h, pix.w, pix.n)
        img = img[:, :, :3].copy()
        boxes, _ = engine.text_detector(img)
        if boxes is None:
            continue
        crops.extend(engine.get_crop_img_list(img, engine.sorted_boxes(boxes)))
    doc.close()
    return crops


def synth_line_crops(degrade: bool) -> list[tuple[np.ndarray, str]]:
    """One small-font image per known line; optionally simulate a scan."""
    font = ImageFont.truetype(FONT, 22)
    out = []
    for ln in GT_LINES:
        w = int(font.getlength(ln)) + 24
        im = Image.new("RGB", (w, 40), "white")
        ImageDraw.Draw(im).text((12, 8), ln, fill="black", font=font)
        a = np.array(im)
        if degrade:
            a = cv2.GaussianBlur(a, (3, 3), 0.8)
            a = np.clip(a.astype(np.int16) + np.random.normal(0, 14, a.shape), 0, 255).astype(np.uint8)
            s = cv2.resize(a, None, fx=0.6, fy=0.6, interpolation=cv2.INTER_AREA)
            a = cv2.resize(s, (a.shape[1], a.shape[0]), interpolation=cv2.INTER_LINEAR)
            ok, buf = cv2.imencode(".jpg", a, [cv2.IMWRITE_JPEG_QUALITY, 45])
            a = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        out.append((a, ln))
    return out


def rec_texts(engine: RapidOCR, crops: list[np.ndarray]) -> list[str]:
    res = engine.text_recognizer(crops)
    rec = res[0] if isinstance(res, tuple) else res
    return [r[0] for r in rec]


def main() -> int:
    base = RapidOCR(**{"use_angle_cls": False})
    crops = real_line_crops(base, n_pages=4)
    syn_clean = synth_line_crops(False)
    syn_scan = synth_line_crops(True)
    print(f"rec-speed over {len(crops)} real line-crops; CER over "
          f"{len(GT_LINES)} synthetic lines\n")

    import rapidocr_onnxruntime as ro
    cur_rec = Path(ro.__file__).parent / "models" / "ch_PP-OCRv3_rec_infer.onnx"

    rows = []
    for label, rec_path in CANDIDATES:
        kw = {"use_angle_cls": False}
        if rec_path is not None:
            if not rec_path.exists():
                print(f"-- {label}: missing {rec_path.name}, skipping")
                continue
            kw["rec_model_path"] = str(rec_path)
        mb = (rec_path or cur_rec).stat().st_size / 1e6
        eng = RapidOCR(**kw)

        rec_texts(eng, crops[:8])  # warmup
        t0 = time.perf_counter()
        rec_texts(eng, crops)
        ms_line = (time.perf_counter() - t0) / len(crops) * 1000

        def cer_of(samples):
            imgs = [s[0] for s in samples]
            hyps = rec_texts(eng, imgs)
            return float(np.mean([cer(gt, h) for (_, gt), h in zip(samples, hyps)]))

        rows.append((label, mb, ms_line, cer_of(syn_clean), cer_of(syn_scan)))

    print(f"{'model':22}{'MB':>7}{'ms/line':>9}{'CER clean':>11}{'CER scan':>10}")
    print("-" * 59)
    for label, mb, ms, cc, cs in rows:
        print(f"{label:22}{mb:7.1f}{ms:9.1f}{cc:11.1%}{cs:10.1%}")
    if rows:
        b = rows[0]
        print("\nvs current:")
        for label, mb, ms, cc, cs in rows[1:]:
            print(f"  {label:18} size x{mb/b[1]:.1f}  rec-speed x{ms/b[2]:.1f} slower"
                  f"  scan-CER {b[4]:.1%} -> {cs:.1%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
