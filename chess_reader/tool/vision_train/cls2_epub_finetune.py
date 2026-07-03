"""Finetune the 2-channel square classifier on the two old-print EPUB scans
(Chess Strategy / Chess Fundamentals), warm-starting from the shipped model.

Mixes synthetic cells, the previous real sources (real_cells + lasker PDF
diagrams — so those fonts aren't forgotten), and the new EPUB cells. Evaluates
per-source every epoch; EPUB holdout boards are never trained on.

Eval applies only the std<0.08 clean-empty gate (not the cdm gate): the faint
white glyphs in these scans sit below the cdm threshold, so the plan is to
drop the cdm gate in the app and let the model's empty class decide.

Usage:
  python cls2_epub_finetune.py --assets <piece_sets dir> \
      --out ../../assets/models/square_classifier2.onnx
"""
import argparse
import os

import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, Dataset

from cls2_dataset import Square2Dataset
from cls2_epub import split_epub_boards
from cls2_lasker import load_lasker_boards
from cls2_model import SquareCNN2
from cls2_real import RealCellsDataset, load_real_boards
from model import CELL, CLASSES

_EMPTY_STD = 0.08


class MixedDataset(Dataset):
    """Each draw comes from (synth, old real, epub) with the given weights."""

    def __init__(self, sources, weights, length, seed=0):
        self.sources = sources
        self.weights = np.asarray(weights, np.float64) / sum(weights)
        self.length = length
        self.seed = seed

    def __len__(self):
        return self.length

    def __getitem__(self, idx):
        rng = np.random.RandomState(self.seed * 7919 + idx)
        src = self.sources[rng.choice(len(self.sources), p=self.weights)]
        return src[rng.randint(len(src))]


@torch.no_grad()
def eval_boards(model, boards, device, verbose=False):
    """(correct, total, boards_with_errors) applying only the std gate."""
    model.eval()
    tot_c = tot = board_errs = 0
    for bid, gray, mask, labels in boards:
        x = np.zeros((64, 2, CELL, CELL), np.float32)
        x[:, 0] = (gray / 255.0 - 0.5) / 0.5
        x[:, 1] = mask
        logits = model(torch.from_numpy(x).to(device)).cpu().numpy()
        pred = []
        for i in range(64):
            empty = x[i, 0].std() < _EMPTY_STD
            pred.append('' if empty else CLASSES[int(logits[i].argmax())])
        wrong = [(i, labels[i], pred[i]) for i in range(64) if labels[i] != pred[i]]
        tot_c += 64 - len(wrong)
        tot += 64
        if wrong:
            board_errs += 1
            if verbose:
                sq = lambda i: 'abcdefgh'[i % 8] + str(8 - i // 8)
                errs = ', '.join(f'{sq(i)} {t or "."}->{p or "."}'
                                 for i, t, p in wrong)
                print(f'    {bid}: {errs}')
    return tot_c, tot, board_errs


def report(model, device, sets, verbose=False):
    for name, boards in sets:
        c, t, be = eval_boards(model, boards, device, verbose=verbose)
        print(f'  {name}: cell acc {c/t:.4f} ({c}/{t}), '
              f'boards w/ errors {be}/{len(boards)}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--assets", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--init", default="square_classifier2.pth")
    ap.add_argument("--epochs", type=int, default=8)
    ap.add_argument("--batch", type=int, default=256)
    ap.add_argument("--train-size", type=int, default=40000)
    ap.add_argument("--lr", type=float, default=3e-4)
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"device: {device}")

    epub_train, epub_hold = split_epub_boards()
    old_real = load_real_boards() + load_lasker_boards()
    print(f"epub train boards: {len(epub_train)}, holdout: {len(epub_hold)}, "
          f"old real: {len(old_real)}")

    synth = Square2Dataset(args.assets, length=200000, seed=1)
    old_ds = RealCellsDataset(length=200000, seed=2, boards=old_real)
    epub_ds = RealCellsDataset(length=200000, seed=3, boards=epub_train)
    train = MixedDataset([synth, old_ds, epub_ds], [0.5, 0.15, 0.35],
                         args.train_size, seed=5)
    workers = min(8, os.cpu_count() or 1)
    trdl = DataLoader(train, batch_size=args.batch, shuffle=True,
                      num_workers=workers, persistent_workers=workers > 0)

    model = SquareCNN2().to(device)
    init = os.path.join(os.path.dirname(__file__), args.init)
    model.load_state_dict(torch.load(init, map_location=device))
    print(f"warm-started from {init}")

    sets = [("epub-train", epub_train), ("epub-HOLDOUT", epub_hold),
            ("old-real", old_real)]
    print("baseline:")
    report(model, device, sets)

    opt = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, args.epochs)
    loss_fn = nn.CrossEntropyLoss()

    for epoch in range(args.epochs):
        model.train()
        run = 0.0
        for x, y in trdl:
            x, y = x.to(device), y.to(device)
            opt.zero_grad()
            loss = loss_fn(model(x), y)
            loss.backward()
            opt.step()
        sched.step()
        run = run  # loss trace omitted; accuracy below is the signal
        print(f"epoch {epoch}:")
        report(model, device, sets)

    print("final holdout detail:")
    report(model, device, [("epub-HOLDOUT", epub_hold)], verbose=True)

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
