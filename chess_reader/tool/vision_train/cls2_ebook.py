"""Training data from the 4 PDF ebooks (Fischer, Kotov, Middle Game, March of Chess Ideas).
"""
import json
import os

import numpy as np
from PIL import Image

from cls2_real import _fen_to_labels
from model import CELL
from seg_test import predict_mask

_HERE = os.path.dirname(__file__)
_BOARDS = os.path.join(_HERE, '..', 'ebook_boards')
_LABELS = os.path.join(_HERE, 'ebook_labels.json')

HOLDOUT = {
    'fischer_p20_b0',
    'kotov_p23_b0',
    'middle_game_p28_b0',
    'march_ideas_p43_b0',
    'art_of_attack_p15_b0',
    'reassess_i00550_b0'
}

def _parse_bid(bid):
    for prefix in ['middle_game_', 'march_ideas_', 'art_of_attack_', 'reassess_', 'fischer_', 'kotov_']:
        if bid.startswith(prefix):
            book = prefix[:-1]
            rest = bid[len(prefix):]
            return book, rest
    raise ValueError(f"Unknown board id prefix: {bid}")

def board_cells_no_peel(png):
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

def load_ebook_boards():
    """[(id, gray[64], mask[64], labels[64])] for every labeled ebook board."""
    with open(_LABELS) as f:
        labels_map = {k: v for k, v in json.load(f).items() if not k.startswith('_')}

    out = []
    for bid, fen in sorted(labels_map.items()):
        book, rest = _parse_bid(bid)
        png = os.path.join(_BOARDS, book, rest, 'inner.png')
        if not os.path.exists(png):
            png = os.path.join(_BOARDS, book, rest, 'board.png')
        gc, mc = board_cells_no_peel(png)
        out.append((bid, gc, mc, _fen_to_labels(fen)))
    return out

def split_ebook_boards():
    """(train_boards, holdout_boards)."""
    boards = load_ebook_boards()
    train = [b for b in boards if b[0] not in HOLDOUT]
    hold = [b for b in boards if b[0] in HOLDOUT]
    return train, hold

if __name__ == '__main__':
    train, hold = split_ebook_boards()
    print(f"Loaded ebook boards: {len(train)} train, {len(hold)} holdout")
