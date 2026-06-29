"""Faithful 2-channel app inference over the real Lasker board crops.

Replicates onnx_square_classifier.dart exactly: arrow_seg -> mask, frame peel +
8x8 slice (board AND mask), 2-channel classifier, then BOTH emptiness gates
(std-dev < 0.08 OR central dark mass < 0.05). Emits JSON [{id, labels, probs}]
matching infer_cells.py so repair_from_json.dart / _final_fen.dart can run the
shipped Dart post-processing on top.
"""
import glob
import json
import os
import sys

import numpy as np
import onnxruntime as ort
from PIL import Image

from model import CELL, CLASSES
from seg_test import predict_mask

_MODEL = os.environ.get('CLS2_MODEL', '../../assets/models/square_classifier2.onnx')
_CLS2 = ort.InferenceSession(_MODEL)
_EMPTY_STD = 0.08
_EMPTY_CENTRAL_MASS = 0.05
_DARK_NORM = -0.14


def _crop_inside_frame(gray):
    n = gray.shape[0]
    maxpeel = n // 8
    t, b, l, r = 0, n - 1, 0, n - 1
    while t < maxpeel and (gray[t] < 128).mean() > 0.8:
        t += 1
    while b > n - 1 - maxpeel and (gray[b] < 128).mean() > 0.8:
        b -= 1
    while l < maxpeel and (gray[:, l] < 128).mean() > 0.8:
        l += 1
    while r > n - 1 - maxpeel and (gray[:, r] < 128).mean() > 0.8:
        r -= 1
    return t, b, l, r


def _central_dark_mass(cell):
    lo = (CELL * 22) // 100
    hi = CELL - lo
    cen = cell[lo:hi, lo:hi]
    return float((cen <= _DARK_NORM).mean())


def _cells(gray, mask):
    t, b, l, r = _crop_inside_frame(gray)
    g = gray[t:b + 1, l:r + 1]
    m = mask[t:b + 1, l:r + 1]
    h, w = g.shape
    ch2 = np.zeros((64, 2, CELL, CELL), np.float32)
    for r_ in range(8):
        for f in range(8):
            ys, ye = round(r_ * h / 8), round((r_ + 1) * h / 8)
            xs, xe = round(f * w / 8), round((f + 1) * w / 8)
            gc = np.asarray(Image.fromarray(g[ys:ye, xs:xe]).resize(
                (CELL, CELL), Image.BILINEAR), np.float32)
            mc = np.asarray(Image.fromarray(
                (m[ys:ye, xs:xe] * 255).astype(np.uint8)).resize(
                (CELL, CELL), Image.BILINEAR), np.float32) / 255.0
            ch2[r_ * 8 + f, 0] = (gc / 255.0 - 0.5) / 0.5
            ch2[r_ * 8 + f, 1] = mc
    return ch2


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else '_readings2.json'
    paths = sorted(glob.glob('../real_cells/pdf*/p1_b*/board.png'))
    boards = []
    for p in paths:
        gray = np.asarray(Image.open(p).convert('L'))
        mask = predict_mask(gray)
        cells = _cells(gray, mask)
        logits = _CLS2.run(None, {'cells': cells})[0]
        labels, probs = [], []
        for i in range(64):
            row = logits[i].astype(np.float64)
            soft = np.exp(row - row.max())
            soft /= soft.sum()
            probs.append([float(x) for x in soft])
            std = float(cells[i, 0].std())
            empty = std < _EMPTY_STD or \
                _central_dark_mass(cells[i, 0]) < _EMPTY_CENTRAL_MASS
            labels.append('' if empty else CLASSES[int(row.argmax())])
        tag = os.path.basename(os.path.dirname(os.path.dirname(p))) + '_' + \
            os.path.basename(os.path.dirname(p))
        boards.append({'id': tag, 'labels': labels, 'probs': probs})
    with open(out_path, 'w') as fh:
        json.dump(boards, fh)
    print(f'{len(boards)} boards -> {out_path}')


if __name__ == '__main__':
    main()
