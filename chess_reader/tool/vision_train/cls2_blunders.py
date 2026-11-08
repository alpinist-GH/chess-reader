"""Finetune the 2-channel square classifier on a labeled book (default: "Blunders
and Brilliancies", coarse 1-bit hatched diagrams) and compare architectures.

Boards are the `inner` crops produced by `_eval_epub.py` (one PNG per diagram,
named <id>.png); labels are a text file with lines `<id> <FEN piece field>`.

Usage (from tool/vision_train, with a venv that has torch/onnxruntime):
  python cls2_blunders.py --boards <dir> --labels <labels.txt> \
      --assets ~/.pub-cache/hosted/pub.dev/chessground-10.0.3/assets/piece_sets \
      --arch base|wide --holdout 40 [--init square_classifier2.pth] \
      [--out model.onnx] [--ckpt model.pth]
"""
import argparse
import copy
import os

import numpy as np
import torch
import torch.nn as nn
from PIL import Image
from torch.utils.data import DataLoader

from cls2_dataset import Square2Dataset
from cls2_ebook_finetune import MixedDataset, eval_boards
from cls2_model import SquareCNN2
from cls2_real import RealCellsDataset, _crop_inside_frame, _fen_to_labels
from grid_refine import refine
from model import CELL, NUM_CLASSES
from seg_test import predict_mask


class SquareCNN2Wide(nn.Module):
    """Same I/O contract as SquareCNN2 (2x32x32 -> 13) with ~4x the width and one
    extra conv per stage, to test whether capacity (not data) is the limit."""

    def __init__(self, num_classes: int = NUM_CLASSES):
        super().__init__()

        def block(i, o):
            return [nn.Conv2d(i, o, 3, padding=1), nn.BatchNorm2d(o), nn.ReLU(inplace=True)]

        self.features = nn.Sequential(
            *block(2, 32), *block(32, 32), nn.MaxPool2d(2),
            *block(32, 64), *block(64, 64), nn.MaxPool2d(2),
            *block(64, 128), nn.MaxPool2d(2),
        )
        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Linear(128 * 4 * 4, 256),
            nn.ReLU(inplace=True),
            nn.Dropout(0.3),
            nn.Linear(256, num_classes),
        )

    def forward(self, x):
        return self.classifier(self.features(x))


ARCHS = {'base': SquareCNN2, 'wide': SquareCNN2Wide}


def cells_from_png(path, do_refine=True):
    """(gray[64,CELL,CELL], mask[64,CELL,CELL]) sliced like the app, from an
    already frame-peeled inner crop (then lattice-refined)."""
    gray = np.asarray(Image.open(path).convert('L'))
    if do_refine:
        gray = np.ascontiguousarray(refine(gray))
    mask = predict_mask(gray)
    h, w = gray.shape
    gc = np.zeros((64, CELL, CELL), np.float32)
    mc = np.zeros((64, CELL, CELL), np.float32)
    for r in range(8):
        for f in range(8):
            ys, ye = round(r * h / 8), round((r + 1) * h / 8)
            xs, xe = round(f * w / 8), round((f + 1) * w / 8)
            gc[r * 8 + f] = np.asarray(Image.fromarray(gray[ys:ye, xs:xe]).resize(
                (CELL, CELL), Image.BILINEAR), np.float32)
            mc[r * 8 + f] = np.asarray(Image.fromarray(
                (mask[ys:ye, xs:xe] * 255).astype(np.uint8)).resize(
                (CELL, CELL), Image.BILINEAR), np.float32) / 255.0
    return gc, mc


def load_boards(boards_dir, labels_path, do_refine=True):
    out = []
    for line in open(labels_path):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        bid, fen = line.split()[:2]
        p = os.path.join(boards_dir, bid + '.png')
        gc, mc = cells_from_png(p, do_refine)
        out.append((bid, gc, mc, _fen_to_labels(fen)))
    return out


@torch.no_grad()
def dump_disagreements(model, boards, device, path):
    from model import CLASSES
    model.eval()
    with open(path, 'a') as f:
        for bid, gray, mask, labels in boards:
            x = np.zeros((64, 2, CELL, CELL), np.float32)
            x[:, 0] = (gray / 255.0 - 0.5) / 0.5
            x[:, 1] = mask
            lg = model(torch.from_numpy(x).to(device)).cpu().numpy()
            for i in range(64):
                p = '' if x[i, 0].std() < 0.08 else CLASSES[int(lg[i].argmax())]
                if p != labels[i]:
                    e = np.exp(lg[i] - lg[i].max()); e /= e.sum()
                    sq = 'abcdefgh'[i % 8] + str(8 - i // 8)
                    f.write(f'{bid}\t{sq}\tlabel={labels[i] or "."}\tmodel={p or "."}\tp={e.max():.2f}\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--boards', required=True)
    ap.add_argument('--labels', required=True)
    ap.add_argument('--assets', required=True)
    ap.add_argument('--arch', default='base', choices=ARCHS)
    ap.add_argument('--init', default=None, help='warm-start .pth (must match --arch)')
    ap.add_argument('--holdout', type=int, default=40, help='every Nth board is held out')
    ap.add_argument('--epochs', type=int, default=20)
    ap.add_argument('--train-size', type=int, default=40000)
    ap.add_argument('--lr', type=float, default=1e-3)
    ap.add_argument('--w-synth', type=float, default=0.3)
    ap.add_argument('--prerefined', action='store_true',
                    help='--boards already holds lattice-refined crops (skip refine)')
    ap.add_argument('--fold', type=int, default=None,
                    help='hold out boards with index %% holdout == fold (cross-validation)')
    ap.add_argument('--dump', default=None, help='write held-out cell disagreements here')
    ap.add_argument('--out', default=None)
    ap.add_argument('--ckpt', default=None)
    args = ap.parse_args()

    device = 'mps' if torch.backends.mps.is_available() else 'cpu'
    boards = load_boards(args.boards, args.labels, not args.prerefined)
    k = args.holdout - 1 if args.fold is None else args.fold
    hold = [b for i, b in enumerate(boards) if i % args.holdout == k] \
        if args.holdout < len(boards) else boards[-max(1, len(boards) // 4):]
    hold_ids = {b[0] for b in hold}
    train_b = [b for b in boards if b[0] not in hold_ids]
    print(f'device {device}  arch {args.arch}  train boards {len(train_b)}  holdout {len(hold)}')

    synth = Square2Dataset(args.assets, length=200000, seed=1)
    real = RealCellsDataset(length=200000, seed=4, boards=train_b)
    train = MixedDataset([synth, real], [args.w_synth, 1 - args.w_synth], args.train_size, seed=5)
    dl = DataLoader(train, batch_size=256, shuffle=True, num_workers=8, persistent_workers=True)

    model = ARCHS[args.arch]().to(device)
    print('params', sum(p.numel() for p in model.parameters()))
    if args.init:
        model.load_state_dict(torch.load(args.init, map_location=device))
    opt = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, args.epochs)
    loss_fn = nn.CrossEntropyLoss()

    def rep(tag):
        c, t, be = eval_boards(model, hold, device)
        ct, tt, bt = eval_boards(model, train_b, device)
        print(f'  {tag}: HOLDOUT cell {c/t:.4f} boards-wrong {be}/{len(hold)} | '
              f'train cell {ct/tt:.4f} boards-wrong {bt}/{len(train_b)}', flush=True)
    rep('before')
    for ep in range(args.epochs):
        model.train()
        for x, y in dl:
            x, y = x.to(device), y.to(device)
            opt.zero_grad()
            loss_fn(model(x), y).backward()
            opt.step()
        sched.step()
        if (ep + 1) % 4 == 0 or ep + 1 == args.epochs:
            rep(f'ep{ep + 1}')

    if args.dump:
        dump_disagreements(model, hold, device, args.dump)
    model = model.cpu().eval()
    if args.ckpt:
        torch.save(model.state_dict(), args.ckpt)
    if args.out:
        torch.onnx.export(model, torch.zeros(1, 2, CELL, CELL), args.out,
                          input_names=['cells'], output_names=['logits'],
                          dynamic_axes={'cells': {0: 'b'}, 'logits': {0: 'b'}},
                          opset_version=17, dynamo=False)
        print('exported', args.out)


if __name__ == '__main__':
    main()
