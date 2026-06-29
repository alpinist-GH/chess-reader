"""Real-diagram finetuning data: the hand-labeled Lasker 'Chess Strategy' board
crops in tool/real_cells/, turned into augmented 2-channel (grayscale, mask)
per-square samples.

The synthetic Square2Dataset bridges chessground fonts to print, but the
engraving font in this 1915 book still trips the classifier (bishop->king,
arrow-induced phantom rooks). These are the real cells of that exact font with
correct labels, so finetuning on them (mixed with synthetic to avoid forgetting)
teaches the model the styles synthesis didn't cover.

Cells are built EXACTLY like the app (onnx_square_classifier.dart): segmenter
mask -> frame peel -> 8x8 slice of board AND mask. Each cell is then augmented
(downscale/blur/contrast/noise/grid + mask dropout) so the few real boards
multiply into a robust training signal instead of being memorized verbatim.
"""
import json
import math
import os
import random

import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFilter
from torch.utils.data import Dataset

from cls2_dataset import _augment_mask, _spurious_mask
from model import CELL, CLASSES
from seg_test import predict_mask

_HERE = os.path.dirname(__file__)
_REAL_ROOT = os.path.join(_HERE, '..', 'real_cells')
_LABELS = os.path.join(_HERE, 'real_labels.json')


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
    assert len(labels) == 64
    return labels


def _crop_inside_frame(gray):
    """Mirror board_slicer._cropInsideFrame: peel near-fully-dark edge rows/cols."""
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


def board_cells(board_png):
    """Return (gray[64,CELL,CELL] in 0..255, mask[64,CELL,CELL] in 0..1) for one
    board crop, sliced exactly like the app."""
    gray = np.asarray(Image.open(board_png).convert('L'))
    mask = predict_mask(gray)
    t, b, l, r = _crop_inside_frame(gray)
    g = gray[t:b + 1, l:r + 1]
    m = mask[t:b + 1, l:r + 1]
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


def load_real_boards():
    """[(id, gray[64], mask[64], labels[64])] for every labeled board."""
    labels_map = {k: v for k, v in json.load(open(_LABELS)).items()
                  if not k.startswith('_')}
    out = []
    for bid, fen in labels_map.items():
        # bid like pdf9_p1_b0 -> real_cells/pdf9/p1_b0/board.png
        parts = bid.split('_')
        png = os.path.join(_REAL_ROOT, parts[0], '_'.join(parts[1:]), 'board.png')
        gc, mc = board_cells(png)
        out.append((bid, gc, mc, _fen_to_labels(fen)))
    return out


def _add_grid(arr, rng):
    img = Image.fromarray(arr.astype(np.uint8))
    d = ImageDraw.Draw(img)
    shade = rng.randint(60, 160)
    if rng.random() < 0.5:
        d.line([(0, 0), (CELL - 1, 0)], fill=shade)
    if rng.random() < 0.5:
        d.line([(0, 0), (0, CELL - 1)], fill=shade)
    return np.asarray(img, np.float32)


def _augment_cell(gray255, mask, rng, np_rng):
    """Photometric + mask augmentation on a 32x32 real cell."""
    arr = gray255.copy()
    if rng.random() < 0.5:  # mild downscale/upscale (print blur)
        f = rng.uniform(0.55, 0.95)
        s = max(6, int(CELL * f))
        arr = np.asarray(Image.fromarray(arr.astype(np.uint8)).resize(
            (s, s), Image.BILINEAR).resize((CELL, CELL), Image.BILINEAR), np.float32)
    if rng.random() < 0.4:
        arr = np.asarray(Image.fromarray(arr.astype(np.uint8)).filter(
            ImageFilter.GaussianBlur(rng.uniform(0.3, 1.0))), np.float32)
    if rng.random() < 0.4:
        arr = _add_grid(arr, rng)
    mean = arr.mean()
    arr = (arr - mean) * rng.uniform(0.75, 1.3) + mean + rng.uniform(-22, 22)
    if rng.random() < 0.4:
        arr = arr + np_rng.normal(0, rng.uniform(2, 7), arr.shape)
    arr = np.clip(arr, 0, 255)

    m = mask
    if m.max() > 0:
        m = _augment_mask(m, rng)
    elif rng.random() < 0.1:
        m = _spurious_mask(rng)
    gray = (arr / 255.0 - 0.5) / 0.5
    return np.stack([gray, m]).astype(np.float32)


class RealCellsDataset(Dataset):
    """Augmented per-square samples drawn from the labeled real boards.

    Cells are sampled inversely to class frequency so the rare pieces (kings,
    bishops, queens) — exactly where the engraving font fails — aren't drowned
    out by the ~40 empty/pawn cells per board.
    """

    def __init__(self, length=20000, seed=0, boards=None):
        self.boards = boards if boards is not None else load_real_boards()
        self.length = length
        self.base_seed = seed
        # Flat pool of (board_idx, cell_idx, class_idx) with per-class weights.
        self.pool = []
        counts = [0] * len(CLASSES)
        for bi, (_, _, _, labels) in enumerate(self.boards):
            for ci, lab in enumerate(labels):
                k = CLASSES.index(lab)
                self.pool.append((bi, ci, k))
                counts[k] += 1
        # Sampling weight: blend uniform (so the real empties — including
        # arrow/hatch squares the gates let through — stay well represented and
        # the model keeps calling them empty) with sqrt-inverse frequency (so the
        # rare officers, where the engraving font actually fails, aren't drowned
        # out). Pure inverse frequency over-weights officers and re-introduces
        # phantom-piece false positives on annotated empty squares.
        sqrt_inv = np.array(
            [1.0 / math.sqrt(counts[k]) for (_, _, k) in self.pool], np.float64)
        sqrt_inv /= sqrt_inv.sum()
        uniform = np.full(len(self.pool), 1.0 / len(self.pool))
        self.weights = 0.5 * uniform + 0.5 * sqrt_inv
        self.idx_arr = np.arange(len(self.pool))

    def __len__(self):
        return self.length

    def __getitem__(self, idx):
        rng = random.Random(self.base_seed * 2_000_003 + idx)
        np_rng = np.random.RandomState(rng.randrange(2**31))
        pick = np_rng.choice(self.idx_arr, p=self.weights)
        bi, ci, k = self.pool[pick]
        _, gray, mask, _ = self.boards[bi]
        x = _augment_cell(gray[ci], mask[ci].copy(), rng, np_rng)
        return torch.from_numpy(x), k
