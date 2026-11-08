"""Does lattice refinement help or hurt the already-labeled books?

Evaluates a checkpoint on every hand-labeled ebook/epub board with the crops
exactly as stored (Dart cropInsideFrame output) vs. after `grid_refine.refine`.
"""
import sys
import numpy as np
import torch
from PIL import Image

import cls2_ebook, cls2_epub
from cls2_ebook_finetune import eval_boards
from cls2_model import SquareCNN2
from grid_refine import refine
import seg_test


def patched(orig_mod):
    def f(png):
        g = np.asarray(Image.open(png).convert('L'))
        g = np.ascontiguousarray(refine(g))
        m = seg_test.predict_mask(g)
        from model import CELL
        h, w = g.shape
        gc = np.zeros((64, CELL, CELL), np.float32); mc = np.zeros_like(gc)
        for r in range(8):
            for c in range(8):
                ys, ye = round(r * h / 8), round((r + 1) * h / 8)
                xs, xe = round(c * w / 8), round((c + 1) * w / 8)
                gc[r * 8 + c] = np.asarray(Image.fromarray(g[ys:ye, xs:xe]).resize((CELL, CELL), Image.BILINEAR), np.float32)
                mc[r * 8 + c] = np.asarray(Image.fromarray((m[ys:ye, xs:xe] * 255).astype(np.uint8)).resize((CELL, CELL), Image.BILINEAR), np.float32) / 255.0
        return gc, mc
    return f


ckpt = sys.argv[1]
model = SquareCNN2(); model.load_state_dict(torch.load(ckpt)); model.eval()
orig = (cls2_ebook.board_cells_no_peel, cls2_epub.board_cells_no_peel)
for tag in ('as-stored', 'refined'):
    if tag == 'refined':
        cls2_ebook.board_cells_no_peel = patched(cls2_ebook)
        cls2_epub.board_cells_no_peel = patched(cls2_epub)
    eb = cls2_ebook.load_ebook_boards()
    try:
        ep = cls2_epub.load_epub_boards()
    except Exception as e:
        ep = []
    for name, bs in (('ebook', eb), ('epub', ep)):
        if not bs: continue
        c, t, be = eval_boards(model, bs, 'cpu')
        print(f'{tag:10s} {name}: cell acc {c/t:.4f}  boards with errors {be}/{len(bs)}')
