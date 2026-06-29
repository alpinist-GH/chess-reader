"""Training data from ALL bundled 'Chess Strategy' (Lasker) diagram boards.

The v13 finetune memorized 13 mid-game boards (real_cells/) and did NOT
generalize to this engraving font (start position, full back ranks, every-color
officers all misread). This module loads the diagram boards extracted straight
from the bundled PDF (tool/lasker_diagrams/diagram_NN.png, clean 346x344 raster,
one per page) with hand FEN labels in lasker_labels.json.

Each PDF image is the whole rendered diagram: an 8x8 board plus a thin left strip
of rank digits and a bottom strip of file letters. `board_box` finds the square
board region (the hatched squares keep every board row/col >~20% non-white, while
the sparse coordinate margins stay near-white), then we slice 8x8 board AND arrow
mask exactly like the app (onnx_square_classifier.dart) so cells match inference.
"""
import json
import os

import numpy as np
from PIL import Image

from model import CELL, CLASSES
from seg_test import predict_mask

_HERE = os.path.dirname(__file__)
_DIAG_ROOT = os.path.join(_HERE, '..', 'lasker_diagrams')
_LABELS = os.path.join(_HERE, 'lasker_labels.json')


def _fen_to_labels(fen_field):
    """FEN piece-placement (rank8->rank1) -> 64 labels (row-major, a-file first)."""
    labels = []
    for rank in fen_field.split('/'):
        row = []
        for ch in rank:
            if ch.isdigit():
                row.extend([''] * int(ch))
            else:
                row.append(ch)
        assert len(row) == 8, f'bad rank {rank!r} in {fen_field!r}'
        labels.extend(row)
    assert len(labels) == 64, f'{fen_field!r} -> {len(labels)} squares'
    return labels


def board_box(gray):
    """Square board region inside the diagram image. The board's hatched squares
    keep rows/cols >20% non-white; the rank-digit (left) and file-letter (bottom)
    margins stay near-white. Right/top edges are the board edges; force the box
    square (these renderings are square) to trim the left digit strip."""
    nw = gray < 230
    rows = [i for i, v in enumerate(nw.mean(axis=1)) if v > 0.2]
    cols = [i for i, v in enumerate(nw.mean(axis=0)) if v > 0.2]
    t, b = min(rows), max(rows) + 1
    r = max(cols) + 1
    l = r - (b - t)  # square board; trims the left rank-digit margin
    return t, b, l, r


def board_cells(diagram_png):
    """(gray[64,CELL,CELL] in 0..255, mask[64,CELL,CELL] in 0..1) for one diagram,
    cropped to the board box then sliced 8x8 (board AND arrow mask), as the app."""
    gray_full = np.asarray(Image.open(diagram_png).convert('L'))
    mask_full = predict_mask(gray_full)
    t, b, l, r = board_box(gray_full)
    g = gray_full[t:b, l:r]
    m = mask_full[t:b, l:r]
    h, w = g.shape
    gc = np.zeros((64, CELL, CELL), np.float32)
    mc = np.zeros((64, CELL, CELL), np.float32)
    for r_ in range(8):
        for f in range(8):
            ys, ye = round(r_ * h / 8), round((r_ + 1) * h / 8)
            xs, xe = round(f * w / 8), round((f + 1) * w / 8)
            gc[r_ * 8 + f] = np.asarray(Image.fromarray(g[ys:ye, xs:xe]).resize(
                (CELL, CELL), Image.BILINEAR), np.float32)
            mc[r_ * 8 + f] = np.asarray(Image.fromarray(
                (m[ys:ye, xs:xe] * 255).astype(np.uint8)).resize(
                (CELL, CELL), Image.BILINEAR), np.float32) / 255.0
    return gc, mc


def load_labels():
    """{diagram_number(int): fen} for labeled, non-skipped diagrams."""
    raw = json.load(open(_LABELS))
    skip = set(raw.get('_skip', []))
    return {int(k): v for k, v in raw.items()
            if not k.startswith('_') and int(k) not in skip}


def load_lasker_boards(numbers=None):
    """[(id, gray[64], mask[64], labels[64])] for the given diagram numbers
    (default: all labeled)."""
    labels = load_labels()
    if numbers is not None:
        labels = {n: labels[n] for n in numbers if n in labels}
    out = []
    for n, fen in sorted(labels.items()):
        png = os.path.join(_DIAG_ROOT, f'diagram_{n:02d}.png')
        gc, mc = board_cells(png)
        out.append((f'd{n}', gc, mc, _fen_to_labels(fen)))
    return out
