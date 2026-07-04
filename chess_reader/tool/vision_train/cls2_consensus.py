"""Consensus pseudo-labels for ALL Chess Strategy (Lasker) EPUB diagrams.

The bundled sample PDF and the EPUB in the repo root are the same book in two
independent renderings. Classifying every diagram from both and keeping only
the cells where the two agree gives near-free ground truth for the whole book
(162 boards), instead of the 24 hand-labeled ones:

  * agreeing cells -> pseudo-label (the EPUB read; ~98% of cells agree);
  * paired adjacent disagreements (the same piece placed on neighbouring
    squares by the two sides — glyph-straddle/slicing shifts) -> EXCLUDED,
    they are exactly the cells whose square assignment is ambiguous;
  * unpaired "PDF empty, EPUB piece" -> labeled EMPTY: the clean PDF render
    doesn't lose pieces, so the EPUB piece is reverse-page bleed-through read
    as a phantom — the error class users actually see, and the most valuable
    training cells here;
  * every other disagreement -> excluded.

Board 2 (the radiating-arrow move illustration) is skipped, as are the
diagrams only present in the EPUB (52, 69, 86, 128, 140 — no second opinion).

Build (writes lasker_consensus.json; needs the EPUB images extracted, e.g.
  unzip -j ../../../Chess-Strategy-Lasker.epub 'OEBPS/*.jpg' -d /tmp/lasker_img):
  python cls2_consensus.py --imgs <lasker_img_dir>

Training loads boards via load_consensus_boards(img_dir): cells whose label is
None must be excluded from the loss (RealCellsDataset skips them).
"""
import argparse
import glob
import json
import os
import re

import numpy as np
from PIL import Image

from _repro_helpers import locate, crop_inside_frame
from cls2_lasker import board_cells as pdf_board_cells
from model import CELL, CLASSES
from seg_test import predict_mask

_HERE = os.path.dirname(os.path.abspath(__file__))
_JSON = os.path.join(_HERE, 'lasker_consensus.json')
_PDF_ROOT = os.path.join(_HERE, '..', 'lasker_diagrams')

#: The arrow move-illustration (not a position) and the four finetune holdout
#: boards; training must not see the holdout even as pseudo-labels.
SKIP = {2}
HOLDOUT = {21, 22, 23, 24}
_EMPTY_STD = 0.08


def epub_board_arrays(jpg):
    """(gray64, mask64) sliced app-faithfully from one EPUB diagram image, or
    None when no board is located."""
    gray = np.asarray(Image.open(jpg).convert('L'))
    cands = locate(gray)
    if not cands:
        return None
    l, t, size = cands[0]
    inner = crop_inside_frame(gray, l, t, size)
    board = gray[t:t + size, l:l + size]
    mask_full = predict_mask(board)
    dh = board.shape[0] - inner.shape[0]
    dw = board.shape[1] - inner.shape[1]
    mask = mask_full[dh // 2:dh // 2 + inner.shape[0],
                     dw // 2:dw // 2 + inner.shape[1]]
    h, w = inner.shape
    gc = np.zeros((64, CELL, CELL), np.float32)
    mc = np.zeros((64, CELL, CELL), np.float32)
    for r in range(8):
        for f in range(8):
            ys, ye = round(r * h / 8), round((r + 1) * h / 8)
            xs, xe = round(f * w / 8), round((f + 1) * w / 8)
            gc[r * 8 + f] = np.asarray(
                Image.fromarray(inner[ys:ye, xs:xe].astype(np.uint8)).resize(
                    (CELL, CELL), Image.BILINEAR), np.float32)
            mc[r * 8 + f] = np.asarray(
                Image.fromarray((mask[ys:ye, xs:xe] * 255).astype(np.uint8))
                .resize((CELL, CELL), Image.BILINEAR), np.float32) / 255.0
    return gc, mc


def _classify(session, gc, mc):
    x = np.zeros((64, 2, CELL, CELL), np.float32)
    x[:, 0] = (gc / 255.0 - 0.5) / 0.5
    x[:, 1] = mc
    logits = session.run(None, {'cells': x})[0]
    out = []
    for i in range(64):
        empty = x[i, 0].std() < _EMPTY_STD
        out.append('' if empty else CLASSES[int(logits[i].argmax())])
    return out


def _adjacent(a, b):
    return abs(a // 8 - b // 8) <= 1 and abs(a % 8 - b % 8) <= 1


def build(img_dir, model_path):
    import onnxruntime as ort
    session = ort.InferenceSession(model_path)

    epub = {}
    for p in sorted(glob.glob(os.path.join(img_dir, '*.jpg'))):
        m = re.search(r'diag(\d+)', os.path.basename(p))
        if not m:
            continue
        arrays = epub_board_arrays(p)
        if arrays is not None:
            epub[int(m.group(1))] = _classify(session, *arrays)

    out = {}
    stats = {'agree': 0, 'excluded': 0, 'ghost_empty': 0}
    for p in sorted(glob.glob(os.path.join(_PDF_ROOT, 'diagram_*.png'))):
        n = int(re.search(r'diagram_(\d+)', p).group(1))
        if n in SKIP or n not in epub:
            continue
        pdf = _classify(session, *pdf_board_cells(p))
        e = epub[n]
        disputed = [i for i in range(64) if e[i] != pdf[i]]
        labels = [e[i] if i not in disputed else None for i in range(64)]
        for i in disputed:
            # A neighbouring dispute holding the same piece on the other side:
            # a straddle/shift pair, square assignment ambiguous.
            paired = any(_adjacent(i, j) and j != i and pdf[j] == e[i]
                         for j in disputed)
            if not paired and pdf[i] == '' and e[i] != '':
                labels[i] = ''  # bleed-through phantom: teach ghost -> empty
                stats['ghost_empty'] += 1
            elif labels[i] is None:
                stats['excluded'] += 1
        stats['agree'] += 64 - len(disputed)
        out[str(n)] = labels
    json.dump(out, open(_JSON, 'w'))
    print(f'{len(out)} boards -> {_JSON}; {stats}')


def load_consensus_boards(img_dir, exclude=frozenset(SKIP | HOLDOUT)):
    """[(id, gray64, mask64, labels64-with-None)] for training. Cells labeled
    None are ambiguous or unverified and must not contribute to the loss."""
    labels_map = json.load(open(_JSON))
    by_num = {}
    for p in sorted(glob.glob(os.path.join(img_dir, '*.jpg'))):
        m = re.search(r'diag(\d+)', os.path.basename(p))
        if m:
            by_num[int(m.group(1))] = p
    out = []
    for key, labels in sorted(labels_map.items(), key=lambda kv: int(kv[0])):
        n = int(key)
        if n in exclude or n not in by_num:
            continue
        arrays = epub_board_arrays(by_num[n])
        if arrays is None:
            continue
        gc, mc = arrays
        out.append((f'c{n}', gc, mc, labels))
    return out


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--imgs', required=True,
                    help='dir of EPUB diagram jpgs (diagNN.jpg names)')
    ap.add_argument('--model',
                    default='../../assets/models/square_classifier2.onnx')
    args = ap.parse_args()
    build(args.imgs, args.model)
