"""Finetune the 2-channel square classifier on the real Lasker diagrams.

Warm-starts from the shipped square_classifier2.pth and continues training on a
mix of synthetic (Square2Dataset) and augmented real cells (RealCellsDataset) at
a low LR, so the model learns this engraving font without forgetting the broad
synthetic distribution. Evaluates per real board against ground truth (applying
the app's emptiness gates) and re-exports ONNX.

Usage:
  python cls2_finetune.py --assets <piece_sets dir> \
      --out ../../assets/models/square_classifier2.onnx
"""
import argparse
import os

import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, Dataset

from cls2_dataset import Square2Dataset
from cls2_model import SquareCNN2
from cls2_real import RealCellsDataset, load_real_boards
from model import CELL, CLASSES, NUM_CLASSES

_EMPTY_STD = 0.08
_EMPTY_CENTRAL_MASS = 0.05
_DARK_NORM = -0.14


def _central_dark_mass(cell):
    lo = (CELL * 22) // 100
    hi = CELL - lo
    return float((cell[lo:hi, lo:hi] <= _DARK_NORM).mean())


class MixedDataset(Dataset):
    """Each draw is a real sample with prob `real_frac`, else synthetic."""

    def __init__(self, synth, real, length, real_frac, seed=0):
        self.synth, self.real = synth, real
        self.length, self.real_frac = length, real_frac
        self.seed = seed

    def __len__(self):
        return self.length

    def __getitem__(self, idx):
        rng = np.random.RandomState(self.seed * 7919 + idx)
        if rng.random() < self.real_frac:
            return self.real[rng.randint(len(self.real))]
        return self.synth[rng.randint(len(self.synth))]


@torch.no_grad()
def eval_real(model, boards, device):
    """Per-board accuracy on clean real cells, applying the app emptiness gates.
    Returns (total_correct, total_cells, n_board_errors) and prints mismatches."""
    model.eval()
    tot_c = tot = board_errs = 0
    for bid, gray, mask, labels in boards:
        x = np.zeros((64, 2, CELL, CELL), np.float32)
        x[:, 0] = (gray / 255.0 - 0.5) / 0.5
        x[:, 1] = mask
        logits = model(torch.from_numpy(x).to(device)).cpu().numpy()
        pred = []
        for i in range(64):
            empty = x[i, 0].std() < _EMPTY_STD or \
                _central_dark_mass(x[i, 0]) < _EMPTY_CENTRAL_MASS
            pred.append('' if empty else CLASSES[int(logits[i].argmax())])
        wrong = [(i, labels[i], pred[i]) for i in range(64) if labels[i] != pred[i]]
        tot_c += 64 - len(wrong)
        tot += 64
        if wrong:
            board_errs += 1
            sq = lambda i: 'abcdefgh'[i % 8] + str(8 - i // 8)
            errs = ', '.join(f'{sq(i)} {t or "."}->{p or "."}' for i, t, p in wrong)
            print(f'    {bid}: {errs}')
    return tot_c, tot, board_errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--assets", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--init", default="square_classifier2.pth")
    ap.add_argument("--epochs", type=int, default=8)
    ap.add_argument("--batch", type=int, default=256)
    ap.add_argument("--train-size", type=int, default=40000)
    ap.add_argument("--real-frac", type=float, default=0.5)
    ap.add_argument("--lr", type=float, default=3e-4)
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"device: {device}")

    real_boards = load_real_boards()
    print(f"real boards: {len(real_boards)}")
    synth = Square2Dataset(args.assets, length=200000, seed=1)
    real = RealCellsDataset(length=200000, seed=2, boards=real_boards)
    train = MixedDataset(synth, real, args.train_size, args.real_frac, seed=5)
    workers = min(8, os.cpu_count() or 1)
    trdl = DataLoader(train, batch_size=args.batch, shuffle=True,
                      num_workers=workers, persistent_workers=workers > 0)

    model = SquareCNN2().to(device)
    init = os.path.join(os.path.dirname(__file__), args.init)
    model.load_state_dict(torch.load(init, map_location=device))
    print(f"warm-started from {init}")
    print("baseline on real boards:")
    c, t, be = eval_real(model, real_boards, device)
    print(f"  real cell acc {c/t:.4f} ({c}/{t}); boards with errors: {be}")

    opt = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, args.epochs)
    loss_fn = nn.CrossEntropyLoss()

    for epoch in range(args.epochs):
        model.train()
        run = 0.0
        for i, (x, y) in enumerate(trdl):
            x, y = x.to(device), y.to(device)
            opt.zero_grad()
            loss = loss_fn(model(x), y)
            loss.backward()
            opt.step()
            run += loss.item()
        sched.step()
        c, t, be = eval_real(model, real_boards, device)
        print(f"epoch {epoch}: train_loss {run/len(trdl):.4f}  "
              f"real_acc {c/t:.4f} ({c}/{t}); boards w/ errors: {be}")

    model = model.cpu().eval()
    ckpt = os.path.join(os.path.dirname(__file__), "square_classifier2.pth")
    torch.save(model.state_dict(), ckpt)
    print(f"saved {ckpt}")
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    dummy = torch.zeros(1, 2, CELL, CELL)
    torch.onnx.export(model, dummy, args.out,
                      input_names=["cells"], output_names=["logits"],
                      dynamic_axes={"cells": {0: "b"}, "logits": {0: "b"}},
                      opset_version=17, dynamo=False)
    print(f"exported ONNX -> {args.out}")


if __name__ == "__main__":
    main()
