"""Finetune the 2-channel square classifier to (a) read the engraving white
queen confidently and (b) be ROBUST to the cell downsample method.

Root cause history (see app board_slicer.dart): the ~150k-param CNN was trained
on cells downsampled one specific way (PIL bilinear), but the Flutter app's
`image` package downsamples differently, and the model is brittle enough that
the white queen (a near 50/50 call) flipped to black. Fix = train each cell by
downsampling the NATIVE-resolution cell to 32x32 with a RANDOM resampling method
every draw, so no single downsample is special, and oversample queens so the
white/black queen margin grows.

Warm-starts from square_classifier2.pth, finetunes on the real Lasker crops
(tool/lasker_train/*.png at the app's 200dpi ~1021px, labels.json) + real_cells,
re-exports square_classifier2.onnx. Eval reports per-resample-method board
accuracy so we can confirm the result is resize-invariant.
"""
import json
import math
import os
import random

import numpy as np
import torch
import torch.nn as nn
from PIL import Image, ImageFilter
from torch.utils.data import DataLoader, Dataset

from cls2_model import SquareCNN2
from model import CELL, CLASSES
from seg_test import predict_mask

_HERE = os.path.dirname(__file__)
_EMPTY_STD = 0.08
_EMPTY_CENTRAL_MASS = 0.05
_DARK_NORM = -0.14
_RESAMPLERS = [Image.NEAREST, Image.BILINEAR, Image.BICUBIC, Image.BOX,
               Image.LANCZOS, Image.HAMMING]


def _central_dark_mass(cell):
    lo = (CELL * 22) // 100
    hi = CELL - lo
    return float((cell[lo:hi, lo:hi] <= _DARK_NORM).mean())


def _crop_inside_frame(gray):
    n = gray.shape[0]
    mp = n // 8
    t, b, l, r = 0, n - 1, 0, n - 1
    while t < mp and (gray[t] < 128).mean() > 0.8:
        t += 1
    while b > n - mp and (gray[b] < 128).mean() > 0.8:
        b -= 1
    while l < mp and (gray[:, l] < 128).mean() > 0.8:
        l += 1
    while r > n - mp and (gray[:, r] < 128).mean() > 0.8:
        r -= 1
    return gray[t:b + 1, l:r + 1]


def _fen_to_labels(fen):
    out = []
    for rank in fen.split('/'):
        for ch in rank:
            out.extend([''] * int(ch) if ch.isdigit() else [ch])
    assert len(out) == 64
    return out


def load_boards():
    """[(id, [64 native uint8 cell arrays], mask32[64], labels[64])]."""
    boards = []
    srcs = []
    lt = os.path.join(_HERE, 'lasker_train')
    if os.path.exists(os.path.join(lt, 'labels.json')):
        for n, fen in json.load(open(os.path.join(lt, 'labels.json'))).items():
            srcs.append((f'lt{n}', os.path.join(lt, f'd{n}.png'), fen))
    # real_cells board.png crops, if labeled
    rl = os.path.join(_HERE, 'real_labels.json')
    if os.path.exists(rl):
        for bid, fen in json.load(open(rl)).items():
            if bid.startswith('_'):
                continue
            parts = bid.split('_')
            p = os.path.join(_HERE, '..', 'real_cells', parts[0],
                             '_'.join(parts[1:]), 'board.png')
            if os.path.exists(p):
                srcs.append((bid, p, fen))
    for bid, path, fen in srcs:
        gray = np.asarray(Image.open(path).convert('L'))
        mask = predict_mask(_crop_inside_frame(gray))
        inner = _crop_inside_frame(gray)
        h, w = inner.shape
        cells, mcells = [], np.zeros((64, CELL, CELL), np.float32)
        for r in range(8):
            for f in range(8):
                ys, ye = round(r * h / 8), round((r + 1) * h / 8)
                xs, xe = round(f * w / 8), round((f + 1) * w / 8)
                cells.append(inner[ys:ye, xs:xe].astype(np.uint8))
                mcells[r * 8 + f] = np.asarray(Image.fromarray(
                    (mask[ys:ye, xs:xe] * 255).astype(np.uint8)).resize(
                    (CELL, CELL), Image.BILINEAR), np.float32) / 255.0
        boards.append((bid, cells, mcells, _fen_to_labels(fen)))
    return boards


def _to32(native, resampler):
    return np.asarray(Image.fromarray(native).resize((CELL, CELL), resampler),
                      np.float32)


def _augment(arr, rng, np_rng):
    if rng.random() < 0.35:  # mild extra blur (print/scan)
        arr = np.asarray(Image.fromarray(arr.astype(np.uint8)).filter(
            ImageFilter.GaussianBlur(rng.uniform(0.3, 0.9))), np.float32)
    mean = arr.mean()
    arr = (arr - mean) * rng.uniform(0.8, 1.25) + mean + rng.uniform(-18, 18)
    if rng.random() < 0.35:
        arr = arr + np_rng.normal(0, rng.uniform(2, 6), arr.shape)
    return np.clip(arr, 0, 255)


class ResizeAugDataset(Dataset):
    def __init__(self, boards, length=40000, seed=0):
        self.boards = boards
        self.length = length
        self.seed = seed
        self.pool = []
        counts = {}
        for bi, (_, _, _, labels) in enumerate(boards):
            for ci, lab in enumerate(labels):
                self.pool.append((bi, ci, lab))
                counts[lab] = counts.get(lab, 0) + 1
        # sqrt-inverse frequency, with an extra boost for queens (the weak glyph)
        w = []
        for (_, _, lab) in self.pool:
            base = 1.0 / math.sqrt(counts[lab])
            if lab in ('Q', 'q'):
                base *= 3.0
            w.append(base)
        w = np.array(w, np.float64)
        self.weights = w / w.sum()
        self.idx = np.arange(len(self.pool))

    def __len__(self):
        return self.length

    def __getitem__(self, i):
        rng = random.Random(self.seed * 2_000_003 + i)
        np_rng = np.random.RandomState(rng.randrange(2**31))
        bi, ci, lab = self.pool[np_rng.choice(self.idx, p=self.weights)]
        _, cells, mcells, _ = self.boards[bi]
        arr = _to32(cells[ci], rng.choice(_RESAMPLERS))
        arr = _augment(arr, rng, np_rng)
        gray = (arr / 255.0 - 0.5) / 0.5
        x = np.stack([gray, mcells[ci]]).astype(np.float32)
        return torch.from_numpy(x), CLASSES.index(lab)


@torch.no_grad()
def evaluate(model, boards, device):
    """Per-resampler board accuracy + queen-square correctness."""
    model.eval()
    sq = lambda i: 'abcdefgh'[i % 8] + str(8 - i // 8)
    for resampler, rname in [(Image.BOX, 'area'), (Image.BILINEAR, 'bilinear'),
                             (Image.NEAREST, 'nearest')]:
        tot = cor = qtot = qcor = 0
        for _, cells, mcells, labels in boards:
            x = np.zeros((64, 2, CELL, CELL), np.float32)
            for i in range(64):
                arr = _to32(cells[i], resampler)
                x[i, 0] = (arr / 255.0 - 0.5) / 0.5
                x[i, 1] = mcells[i]
            logits = model(torch.from_numpy(x).to(device)).cpu().numpy()
            for i in range(64):
                empty = x[i, 0].std() < _EMPTY_STD or \
                    _central_dark_mass(x[i, 0]) < _EMPTY_CENTRAL_MASS
                pred = '' if empty else CLASSES[int(logits[i].argmax())]
                tot += 1
                cor += pred == labels[i]
                if labels[i] in ('Q', 'q'):
                    qtot += 1
                    qcor += pred == labels[i]
        print(f"    {rname:9}: cells {cor}/{tot} ({cor/tot:.4f})  "
              f"queens {qcor}/{qtot}")


def main():
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    boards = load_boards()
    print(f"boards: {len(boards)}")
    model = SquareCNN2().to(device)
    init = os.path.join(_HERE, 'square_classifier2.pth')
    model.load_state_dict(torch.load(init, map_location=device))
    print("baseline:")
    evaluate(model, boards, device)

    ds = ResizeAugDataset(boards, length=40000, seed=1)
    dl = DataLoader(ds, batch_size=256, shuffle=True,
                    num_workers=min(6, os.cpu_count() or 1))
    opt = torch.optim.Adam(model.parameters(), lr=2e-4, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, 6)
    loss_fn = nn.CrossEntropyLoss()
    for epoch in range(6):
        model.train()
        run = 0.0
        for x, y in dl:
            x, y = x.to(device), y.to(device)
            opt.zero_grad()
            loss = loss_fn(model(x), y)
            loss.backward()
            opt.step()
            run += loss.item()
        sched.step()
        print(f"epoch {epoch}: loss {run/len(dl):.4f}")
        evaluate(model, boards, device)

    model = model.cpu().eval()
    torch.save(model.state_dict(), os.path.join(_HERE, 'square_classifier2.pth'))
    out = os.path.join(_HERE, '..', '..', 'assets', 'models',
                       'square_classifier2.onnx')
    torch.onnx.export(model, torch.zeros(1, 2, CELL, CELL), out,
                      input_names=['cells'], output_names=['logits'],
                      dynamic_axes={'cells': {0: 'b'}, 'logits': {0: 'b'}},
                      opset_version=17, dynamo=False)
    print(f"exported {out}")


if __name__ == '__main__':
    main()
