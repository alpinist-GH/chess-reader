"""Training data from the two old-print EPUB scans in the repo root:
'Chess Strategy' (Lasker) and 'Chess Fundamentals' (Capablanca).

Both books use engraving fonts on heavily hatched squares; the Lasker scan adds
reverse-page bleed-through, the Capablanca scan mottled hatching and very faint
white glyphs. The shipped model reads pawns as R/B and kings as Q on them
(58% occupied-square accuracy, ~90% of boards structurally impossible).

Board crops live in tool/epub_boards/{lasker,fund}/*.png — they are the
frame-peeled inner boards produced by the app-faithful repro pipeline
(tool/vision_train/_eval_epub.py), so slicing matches inference. Labels:
- lasker: the EPUB is the same book as the bundled PDF; diagram numbers map
  1:1 onto lasker_labels.json (verified: every noisy prediction best-matches
  its own label). Diagram 2 (arrow move-illustration) is skipped there.
- fund: hand-labeled FENs in fund_labels.json.
"""
import json
import os

import numpy as np
from PIL import Image

from cls2_lasker import _fen_to_labels, load_labels as load_lasker_fens
from model import CELL
from seg_test import predict_mask

_HERE = os.path.dirname(__file__)
_BOARDS = os.path.join(_HERE, '..', 'epub_boards')

# Held out of training to measure generalization to unseen boards of the
# same scans (eval only).
HOLDOUT = {'l-diag21', 'l-diag22', 'l-diag23', 'l-diag24',
           'f-Fig10', 'f-Fig33', 'f-Fig81', 'f-Fig90'}


def board_cells_no_peel(png):
    """Like cls2_real.board_cells but without the frame peel: these crops are
    already the peeled inner board (and are not exactly square, which the
    square-assuming peel loop would crash on)."""
    g = np.asarray(Image.open(png).convert('L'))
    m = predict_mask(g)
    h, w = g.shape
    gc = np.zeros((64, CELL, CELL), np.float32)
    mc = np.zeros((64, CELL, CELL), np.float32)
    for r in range(8):
        for f in range(8):
            ys, ye = round(r * h / 8), round((r + 1) * h / 8)
            xs, xe = round(f * w / 8), round((f + 1) * w / 8)
            gc[r * 8 + f] = np.asarray(Image.fromarray(g[ys:ye, xs:xe]).resize(
                (CELL, CELL), Image.BILINEAR), np.float32)
            mc[r * 8 + f] = np.asarray(Image.fromarray(
                (m[ys:ye, xs:xe] * 255).astype(np.uint8)).resize(
                (CELL, CELL), Image.BILINEAR), np.float32) / 255.0
    return gc, mc


def _load(subdir, name_fens, prefix):
    out = []
    for name, fen in sorted(name_fens.items()):
        png = os.path.join(_BOARDS, subdir, f'{name}.png')
        gc, mc = board_cells_no_peel(png)
        out.append((f'{prefix}-{name}', gc, mc, _fen_to_labels(fen)))
    return out


def load_epub_boards():
    """[(id, gray[64], mask[64], labels[64])] for every labeled EPUB board."""
    lasker = {f'diag{n:02d}': fen for n, fen in load_lasker_fens().items()}
    fund = {k: v for k, v in json.load(
        open(os.path.join(_HERE, 'fund_labels.json'))).items()
        if not k.startswith('_')}
    return _load('lasker', lasker, 'l') + _load('fund', fund, 'f')


def split_epub_boards():
    """(train_boards, holdout_boards)."""
    boards = load_epub_boards()
    train = [b for b in boards if b[0] not in HOLDOUT]
    hold = [b for b in boards if b[0] in HOLDOUT]
    return train, hold
