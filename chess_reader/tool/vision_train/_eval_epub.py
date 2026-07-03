"""Batch-run the app-faithful repro pipeline over EPUB diagram images.

Usage (run from tool/vision_train with its venv):
  python eval_epub.py <img_dir> <out_dir>

For each image: grayscale -> locate boards -> crop inside frame -> arrow
segmenter mask -> 2-channel classifier with the app's empty gates.
Writes <out_dir>/<name>_b<idx>.png (board crop) and results.tsv (name, fen).
"""
import glob
import os
import sys

import numpy as np
from PIL import Image

from _repro_helpers import locate, crop_inside_frame, to_fen
from model import CELL, CLASSES
from seg_test import predict_mask
import onnxruntime as ort

_CLS2 = ort.InferenceSession('../../assets/models/square_classifier2.onnx')


def _cdm(c):
    lo = (CELL * 22) // 100
    hi = CELL - lo
    return float((c[lo:hi, lo:hi] <= -0.14).mean())


def classify_with_mask(inner, mask):
    h, w = inner.shape
    x = np.zeros((64, 2, CELL, CELL), np.float32)
    for r in range(8):
        for f in range(8):
            ys, ye = round(r * h / 8), round((r + 1) * h / 8)
            xs, xe = round(f * w / 8), round((f + 1) * w / 8)
            g = np.asarray(Image.fromarray(inner[ys:ye, xs:xe].astype(np.uint8))
                           .resize((CELL, CELL), Image.BILINEAR), np.float32)
            m = np.asarray(Image.fromarray((mask[ys:ye, xs:xe] * 255).astype(np.uint8))
                           .resize((CELL, CELL), Image.BILINEAR), np.float32) / 255.0
            x[r * 8 + f, 0] = (g / 255.0 - 0.5) / 0.5
            x[r * 8 + f, 1] = m
    logits = _CLS2.run(None, {'cells': x})[0]
    out, conf = [], []
    for i in range(64):
        empty = x[i, 0].std() < 0.08
        p = np.exp(logits[i] - logits[i].max())
        p /= p.sum()
        out.append('' if empty else CLASSES[int(logits[i].argmax())])
        conf.append(0.0 if empty else float(p.max()))
    return out, conf


def main():
    img_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    rows = []
    paths = sorted(glob.glob(os.path.join(img_dir, '*.jpg')))
    for p in paths:
        name = os.path.splitext(os.path.basename(p))[0]
        gray = np.asarray(Image.open(p).convert('L'))
        cands = locate(gray)
        if not cands:
            rows.append((name, 'NO_BOARD', ''))
            continue
        l, t, size = cands[0]
        inner = crop_inside_frame(gray, l, t, size)
        # segmenter works on the raw board crop, then peel the same frame
        board = gray[t:t + size, l:l + size]
        mask_full = predict_mask(board)
        # align mask to inner crop: recompute peel offsets
        dh = board.shape[0] - inner.shape[0]
        dw = board.shape[1] - inner.shape[1]
        # peel offsets aren't returned; approximate by centering (frame peel is
        # symmetric to within a pixel or two, and mask is near-zero anyway
        # when no arrows are drawn)
        oy, ox = dh // 2, dw // 2
        mask = mask_full[oy:oy + inner.shape[0], ox:ox + inner.shape[1]]
        labels, conf = classify_with_mask(inner, mask)
        fen = to_fen(labels)
        nonempty = [c for c in conf if c > 0]
        minc = min(nonempty) if nonempty else 1.0
        Image.fromarray(inner.astype(np.uint8)).save(
            os.path.join(out_dir, f'{name}.png'))
        rows.append((name, fen, f'{minc:.2f}'))
        print(name, fen, f'minconf={minc:.2f}', flush=True)
    with open(os.path.join(out_dir, 'results.tsv'), 'w') as f:
        for r in rows:
            f.write('\t'.join(r) + '\n')
    found = sum(1 for r in rows if r[1] != 'NO_BOARD')
    print(f'\n{found}/{len(rows)} images had a located board')


if __name__ == '__main__':
    main()
