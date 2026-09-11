"""Finetune the 2-channel square classifier on the PDF/epub ebooks, warm-starting
from the shipped model while preserving accuracy on synthetic and prior real sources.

Trains to a large epoch ceiling with plateau-based early stopping: every
--eval-every epochs it scores the model against the full unlabeled ebook_boards
corpus (structural-legality-after-repair, ~1800 boards -- much less noisy than
the small hand-labeled holdout) and keeps the best checkpoint seen. Training
stops once --patience consecutive checks fail to improve that score by
--min-delta, or --max-epochs is reached.

Usage:
  python cls2_ebook_finetune.py \
      --assets ~/.pub-cache/hosted/pub.dev/chessground-10.0.3/assets/piece_sets \
      --out ../../assets/models/square_classifier2.onnx
"""
import argparse
import copy
import json
import os

import numpy as np
import onnxruntime as ort
import torch
import torch.nn as nn
from PIL import Image
from torch.utils.data import DataLoader, Dataset

from board_repair import repair_to_legal
from cls2_dataset import Square2Dataset
from cls2_ebook import split_ebook_boards
from cls2_epub import split_epub_boards
from cls2_lasker import load_lasker_boards
from cls2_model import SquareCNN2
from cls2_real import RealCellsDataset, load_real_boards
from model import CELL, CLASSES

_EMPTY_STD = 0.08
_HERE = os.path.dirname(os.path.abspath(__file__))
_CR_ROOT = os.path.abspath(os.path.join(_HERE, '..', '..'))
_SEG_MODEL = os.path.join(_CR_ROOT, 'assets/models/arrow_seg.onnx')
_MANIFEST = os.path.join(_CR_ROOT, 'tool/ebook_boards/manifest.json')
_SEG_SIZE = 192


def _predict_mask(seg, gray):
    h, w = gray.shape
    inp = np.asarray(Image.fromarray(gray).resize((_SEG_SIZE, _SEG_SIZE), Image.BILINEAR), np.float32)
    x = ((inp / 255.0 - 0.5) / 0.5)[None, None]
    logit = seg.run(None, {'board': x})[0][0, 0]
    prob = 1 / (1 + np.exp(-logit))
    return np.asarray(Image.fromarray((prob * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR), np.float32) / 255.0


def _check_chess_validity(labels):
    wk = labels.count('K')
    bk = labels.count('k')
    if wk != 1 or bk != 1:
        return False
    for i in range(8):
        if labels[i] in ('P', 'p') or labels[56 + i] in ('P', 'p'):
            return False
    if labels.count('P') > 8 or labels.count('p') > 8:
        return False
    if sum(1 for x in labels if x.isupper()) > 16 or sum(1 for x in labels if x.islower()) > 16:
        return False
    return True


def load_corpus_cache():
    """Precompute (gray, mask) cells for every board in the unlabeled ebook_boards
    manifest, once, so each plateau check only re-runs the (fast, changing)
    classifier rather than the (slow, fixed) segmentation model."""
    with open(_MANIFEST) as f:
        manifest = json.load(f)
    seg = ort.InferenceSession(_SEG_MODEL)

    cache = []
    for item in manifest:
        b_dir = os.path.join(_CR_ROOT, item['dir'])
        inner_path = os.path.join(b_dir, 'inner.png')
        board_path = os.path.join(b_dir, 'board.png')
        if not os.path.exists(inner_path):
            continue
        inner_gray = np.asarray(Image.open(inner_path).convert('L'))
        board_gray = np.asarray(Image.open(board_path).convert('L'))
        mask = _predict_mask(seg, board_gray)
        h, w = inner_gray.shape
        mask_inner = np.asarray(Image.fromarray((mask * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR), np.float32) / 255.0

        gc = np.zeros((64, CELL, CELL), np.float32)
        mc = np.zeros((64, CELL, CELL), np.float32)
        for r in range(8):
            for c in range(8):
                ys, ye = round(r * h / 8), round((r + 1) * h / 8)
                xs, xe = round(c * w / 8), round((c + 1) * w / 8)
                gc[r * 8 + c] = np.asarray(Image.fromarray(inner_gray[ys:ye, xs:xe]).resize(
                    (CELL, CELL), Image.BILINEAR), np.float32)
                mc[r * 8 + c] = np.asarray(Image.fromarray(
                    (mask_inner[ys:ye, xs:xe] * 255).astype(np.uint8)).resize(
                    (CELL, CELL), Image.BILINEAR), np.float32) / 255.0
        cache.append((item['id'], gc, mc))
    return cache


@torch.no_grad()
def corpus_legality(model, device, cache):
    """Fraction of the full unlabeled corpus that is structurally legal after
    board_repair, using the live in-memory model (no ONNX export needed)."""
    model.eval()
    legal_raw = legal_rep = 0
    for _bid, gc, mc in cache:
        x = np.zeros((64, 2, CELL, CELL), np.float32)
        x[:, 0] = (gc / 255.0 - 0.5) / 0.5
        x[:, 1] = mc
        logits = model(torch.from_numpy(x).to(device)).cpu().numpy().astype(np.float64)
        labels, probs = [], []
        for i in range(64):
            row = logits[i]
            soft = np.exp(row - row.max())
            soft /= soft.sum()
            probs.append(soft)
            empty = x[i, 0].std() < _EMPTY_STD
            labels.append('' if empty else CLASSES[int(row.argmax())])
        if _check_chess_validity(labels):
            legal_raw += 1
        if _check_chess_validity(repair_to_legal(labels, probs)):
            legal_rep += 1
    n = len(cache)
    return legal_raw / n, legal_rep / n


class MixedDataset(Dataset):
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
                errs = ', '.join(f'{sq(i)} {t or "."}->{p or "."}' for i, t, p in wrong)
                print(f'    {bid}: {errs}')
    return tot_c, tot, board_errs


def report(model, device, sets, verbose=False):
    for name, boards in sets:
        c, t, be = eval_boards(model, boards, device, verbose=verbose)
        print(f'  {name}: cell acc {c/t:.4f} ({c}/{t}), boards w/ errors {be}/{len(boards)}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--assets", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--init", default="square_classifier2.pth")
    ap.add_argument("--max-epochs", type=int, default=40)
    ap.add_argument("--eval-every", type=int, default=4)
    ap.add_argument("--patience", type=int, default=3,
                     help="stop after this many eval-every-epoch checks with no improvement")
    ap.add_argument("--min-delta", type=float, default=0.001,
                     help="minimum corpus-legality improvement to reset patience")
    ap.add_argument("--batch", type=int, default=256)
    ap.add_argument("--train-size", type=int, default=40000)
    ap.add_argument("--lr", type=float, default=2e-4)
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"device: {device}")

    ebook_train, ebook_hold = split_ebook_boards()
    epub_train, epub_hold = split_epub_boards()
    old_real = load_real_boards()
    try:
        old_real += load_lasker_boards()
    except Exception:
        pass
    print(f"ebook train: {len(ebook_train)}, holdout: {len(ebook_hold)}")
    print(f"epub train: {len(epub_train)}, holdout: {len(epub_hold)}")
    print(f"old real: {len(old_real)}")

    synth = Square2Dataset(args.assets, length=200000, seed=1)
    old_ds = RealCellsDataset(length=200000, seed=2, boards=old_real)
    epub_ds = RealCellsDataset(length=200000, seed=3, boards=epub_train)
    ebook_ds = RealCellsDataset(length=200000, seed=4, boards=ebook_train)

    sources = [synth, old_ds, epub_ds, ebook_ds]
    weights = [0.40, 0.10, 0.20, 0.30]

    train = MixedDataset(sources, weights, args.train_size, seed=5)
    workers = min(8, os.cpu_count() or 1)
    trdl = DataLoader(train, batch_size=args.batch, shuffle=True,
                      num_workers=workers, persistent_workers=workers > 0)

    model = SquareCNN2().to(device)
    init = os.path.join(os.path.dirname(__file__), args.init)
    model.load_state_dict(torch.load(init, map_location=device))
    print(f"warm-started from {init}")

    sets = [
        ("ebook-train", ebook_train),
        ("ebook-HOLDOUT", ebook_hold),
        ("epub-HOLDOUT", epub_hold),
        ("old-real", old_real),
    ]
    print("\nLoading full-corpus cache for plateau checks (one-time seg pass)...")
    corpus_cache = load_corpus_cache()
    print(f"corpus cache: {len(corpus_cache)} boards")

    print("\n--- Baseline Before Retraining ---")
    report(model, device, sets)
    base_raw, base_rep = corpus_legality(model, device, corpus_cache)
    print(f"  corpus legality: raw {base_raw:.4f}, repaired {base_rep:.4f}")

    opt = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, args.max_epochs)
    loss_fn = nn.CrossEntropyLoss()

    best_score = base_rep
    best_state = copy.deepcopy(model.state_dict())
    best_epoch = 0
    checks_without_improvement = 0

    for epoch in range(args.max_epochs):
        model.train()
        for x, y in trdl:
            x, y = x.to(device), y.to(device)
            opt.zero_grad()
            loss = loss_fn(model(x), y)
            loss.backward()
            opt.step()
        sched.step()
        print(f"\n--- Epoch {epoch + 1}/{args.max_epochs} ---")

        if (epoch + 1) % args.eval_every != 0 and epoch + 1 != args.max_epochs:
            continue

        report(model, device, sets)
        raw, rep = corpus_legality(model, device, corpus_cache)
        print(f"  corpus legality: raw {raw:.4f}, repaired {rep:.4f}")

        if rep > best_score + args.min_delta:
            best_score = rep
            best_state = copy.deepcopy(model.state_dict())
            best_epoch = epoch + 1
            checks_without_improvement = 0
            print(f"  -> new best (repaired legality {best_score:.4f})")
        else:
            checks_without_improvement += 1
            print(f"  -> no improvement ({checks_without_improvement}/{args.patience} checks, "
                  f"best {best_score:.4f} @ epoch {best_epoch})")
            if checks_without_improvement >= args.patience:
                print(f"\nPlateaued: stopping at epoch {epoch + 1}, "
                      f"restoring best checkpoint from epoch {best_epoch}.")
                break

    model.load_state_dict(best_state)
    print(f"\nUsing best checkpoint from epoch {best_epoch} (corpus repaired legality {best_score:.4f})")

    print("\n--- Final Holdout Detail ---")
    report(model, device, [("ebook-HOLDOUT", ebook_hold)], verbose=True)

    model = model.cpu().eval()
    ckpt = os.path.join(os.path.dirname(__file__), "square_classifier2.pth")
    torch.save(model.state_dict(), ckpt)
    print(f"saved checkpoint {ckpt}")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    dummy = torch.zeros(1, 2, CELL, CELL)
    torch.onnx.export(
        model, dummy, args.out,
        input_names=["cells"], output_names=["logits"],
        dynamic_axes={"cells": {0: "b"}, "logits": {0: "b"}},
        opset_version=17, dynamo=False
    )
    print(f"Successfully exported new ONNX model -> {args.out}")


if __name__ == "__main__":
    main()
