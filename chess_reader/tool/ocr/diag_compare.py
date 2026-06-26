"""Diagnose the in-app OCR: run OUR vendored models with OUR exact Dart
preprocessing/post-processing, vs RapidOCR's proper PP-OCR pipeline (same
models), on the same rendered page of a scanned PDF.

This tells us whether bad results come from our hand-rolled detector
post-processing (RapidOCR good, ours bad) or from the model/language (both bad).

    tool/vision_train/.venv/Scripts/python.exe tool/ocr/diag_compare.py --page 4
"""

from __future__ import annotations

import argparse
from pathlib import Path

import cv2
import fitz
import numpy as np
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[2]
PDF = ROOT / "assets" / "sample" / "My System.pdf"
DET = ROOT / "assets" / "models" / "ocr_det.onnx"
REC = ROOT / "assets" / "models" / "ocr_rec.onnx"
KEYS = ROOT / "assets" / "models" / "ocr_keys.txt"
OUT = ROOT / "dist" / "ocr_diag"

DET_MEAN = np.array([0.485, 0.456, 0.406], np.float32)
DET_STD = np.array([0.229, 0.224, 0.225], np.float32)
REC_H = 48
REC_MAXW = 320


def render_page(page_idx: int, dpi: int) -> np.ndarray:
    """Render to an RGB uint8 array, matching the app's pdfrx raster."""
    d = fitz.open(str(PDF))
    pix = d[page_idx].get_pixmap(dpi=dpi)
    img = np.frombuffer(pix.samples, np.uint8).reshape(pix.h, pix.w, pix.n)
    return img[:, :, :3].copy()  # drop alpha if present


def round32(v: int) -> int:
    r = round(v / 32) * 32
    return max(32, r)


def run_det(sess: ort.InferenceSession, rgb: np.ndarray, max_side: int):
    """Replicates ocr_isolate._buildDetInput + onnx_text_recognizer.runDet."""
    h, w = rgb.shape[:2]
    longest = max(w, h)
    ratio = max_side / longest if longest > max_side else 1.0
    inW, inH = round32(round(w * ratio)), round32(round(h * ratio))
    resized = cv2.resize(rgb, (inW, inH))
    x = resized.astype(np.float32) / 255.0
    x = (x - DET_MEAN) / DET_STD
    x = x.transpose(2, 0, 1)[None]  # NCHW
    name = sess.get_inputs()[0].name
    prob = sess.run(None, {name: x})[0]  # [1,1,H,W]
    return prob[0, 0], inW, inH, w / inW, h / inH


def our_boxes(prob: np.ndarray, bin_thr=0.3, min_area=16, min_h=4):
    """Replicates TextDetector.detect: threshold + connected components + 30% pad."""
    binary = (prob >= bin_thr).astype(np.uint8)
    n, _, stats, _ = cv2.connectedComponentsWithStats(binary, connectivity=8)
    boxes = []
    for i in range(1, n):
        x, y, bw, bh, area = stats[i]
        if area < min_area or bh < min_h:
            continue
        pad = int(np.clip(round(bh * 0.3), 1, bh))
        pady = int(np.clip(round(pad / 2), 1, bh))
        boxes.append((max(0, x - pad), max(0, y - pady), bw + 2 * pad, bh + 2 * pady))
    return boxes, binary


def load_keys():
    keys = [l for l in KEYS.read_text(encoding="utf-8").split("\n") if l]
    return ["<blank>", *keys, " "]


def run_rec(sess: ort.InferenceSession, rgb: np.ndarray, box, vocab):
    """Replicates ocr_isolate._buildRecInputs + runRec + CTC greedy decode."""
    x, y, bw, bh = box
    crop = rgb[y:y + bh, x:x + bw]
    if crop.size == 0:
        return ""
    w = int(round(REC_H * bw / bh))
    w = max(1, min(REC_MAXW, w))
    strip = cv2.resize(crop, (w, REC_H))
    canvas = np.zeros((REC_H, REC_MAXW, 3), np.float32)
    canvas[:, :w] = (strip.astype(np.float32) / 255.0 - 0.5) / 0.5
    inp = canvas.transpose(2, 0, 1)[None]
    name = sess.get_inputs()[0].name
    out = sess.run(None, {name: inp})[0][0]  # [steps, classes]
    ids = out.argmax(1)
    res, prev = [], 0
    for k in ids:
        if k != 0 and k != prev:
            res.append(vocab[k] if k < len(vocab) else "")
        prev = k
    return "".join(res)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--page", type=int, default=4)
    ap.add_argument("--dpi", type=int, default=200)
    ap.add_argument("--max-side", type=int, default=960)
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)

    rgb = render_page(args.page, args.dpi)
    print(f"page {args.page} rendered @ {args.dpi}dpi -> {rgb.shape[1]}x{rgb.shape[0]}")

    # ---- OUR pipeline ----
    det = ort.InferenceSession(str(DET))
    rec = ort.InferenceSession(str(REC))
    vocab = load_keys()
    prob, inW, inH, sx, sy = run_det(det, rgb, args.max_side)
    print(f"\n[OURS] det input {inW}x{inH}  prob: max={prob.max():.2f} "
          f"mean={prob.mean():.3f}  frac>0.3={(prob >= 0.3).mean():.3f}")
    boxes, binary = our_boxes(prob)
    hs = sorted(b[3] for b in boxes)
    print(f"[OURS] {len(boxes)} boxes; height px min/med/max="
          f"{hs[0] if hs else 0}/{hs[len(hs)//2] if hs else 0}/{hs[-1] if hs else 0}")
    # Scale boxes back to source and recognize.
    src_boxes = [(int(x * sx), int(y * sy), int(w * sx), int(h * sy))
                 for (x, y, w, h) in boxes]
    src_boxes.sort(key=lambda b: (b[1], b[0]))
    ours_lines = [run_rec(rec, rgb, b, vocab) for b in src_boxes]
    ours_text = "\n".join(t for t in ours_lines if t.strip())
    print(f"[OURS] recognized {sum(1 for t in ours_lines if t.strip())} non-empty lines")

    # overlay
    vis = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR).copy()
    for (x, y, w, h) in src_boxes:
        cv2.rectangle(vis, (x, y), (x + w, y + h), (0, 0, 255), 2)
    cv2.imwrite(str(OUT / f"ours_p{args.page}.png"), vis)
    cv2.imwrite(str(OUT / f"ours_probmap_p{args.page}.png"), (prob * 255).astype(np.uint8))

    # ---- RapidOCR (proper PP-OCR post-processing, same models) ----
    from rapidocr_onnxruntime import RapidOCR
    engine = RapidOCR(det_model_path=str(DET), rec_model_path=str(REC))
    result, _ = engine(cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))
    rapid_lines = [r[1] for r in result] if result else []
    rapid_text = "\n".join(rapid_lines)
    print(f"\n[RAPID] {len(rapid_lines)} lines")

    (OUT / f"ours_p{args.page}.txt").write_text(ours_text, encoding="utf-8")
    (OUT / f"rapid_p{args.page}.txt").write_text(rapid_text, encoding="utf-8")

    def preview(label, text):
        print(f"\n===== {label} (first 600 chars) =====")
        print(text[:600] if text.strip() else "(empty)")

    preview("OURS", ours_text)
    preview("RAPIDOCR", rapid_text)
    print(f"\nartifacts in {OUT}")


if __name__ == "__main__":
    main()
