"""Final finetune: synthetic + all previously labeled books + "Blunders and
Brilliancies", with lattice refinement applied to EVERY source's crops so that
training geometry matches the app (cropInsideFrame -> refineGrid).

  python cls2_final.py --assets <piece_sets> --blunders-boards <refined dir> \
      --blunders-labels labels.txt --out ../../assets/models/square_classifier2.onnx
"""
import argparse, os
import numpy as np, torch, torch.nn as nn
from PIL import Image
from torch.utils.data import DataLoader

import cls2_ebook, cls2_epub, cls2_real, cls2_lasker
from cls2_blunders import ARCHS, cells_from_png, load_boards
from cls2_dataset import Square2Dataset
from cls2_ebook_finetune import MixedDataset, eval_boards
from cls2_real import RealCellsDataset
from grid_refine import refine
from model import CELL
import seg_test


def slice_refined(gray):
    gray = np.ascontiguousarray(refine(gray))
    m = seg_test.predict_mask(gray)
    h, w = gray.shape
    gc = np.zeros((64, CELL, CELL), np.float32); mc = np.zeros_like(gc)
    for r in range(8):
        for f in range(8):
            ys, ye, xs, xe = round(r*h/8), round((r+1)*h/8), round(f*w/8), round((f+1)*w/8)
            gc[r*8+f] = np.asarray(Image.fromarray(gray[ys:ye, xs:xe]).resize((CELL, CELL), Image.BILINEAR), np.float32)
            mc[r*8+f] = np.asarray(Image.fromarray((m[ys:ye, xs:xe]*255).astype(np.uint8)).resize((CELL, CELL), Image.BILINEAR), np.float32)/255
    return slice_out(gc, mc)


def slice_out(gc, mc):
    return gc, mc


def patch_loaders():
    gray_of = lambda p: np.asarray(Image.open(p).convert('L'))
    nopeel = lambda png: slice_refined(gray_of(png))
    cls2_ebook.board_cells_no_peel = nopeel
    cls2_epub.board_cells_no_peel = nopeel

    def real_cells(png):
        g = gray_of(png)
        t, b, l, r = cls2_real._crop_inside_frame(g)
        return slice_refined(g[t:b+1, l:r+1])
    cls2_real.board_cells = real_cells

    def lasker_cells(png):
        g = gray_of(png)
        t, b, l, r = cls2_lasker.board_box(g)
        return slice_refined(g[t:b, l:r])
    cls2_lasker.board_cells = lasker_cells


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--assets', required=True)
    ap.add_argument('--blunders-boards', required=True)
    ap.add_argument('--blunders-labels', required=True)
    ap.add_argument('--init', default='square_classifier2.pth')
    ap.add_argument('--arch', default='base')
    ap.add_argument('--epochs', type=int, default=16)
    ap.add_argument('--train-size', type=int, default=40000)
    ap.add_argument('--lr', type=float, default=4e-4)
    ap.add_argument('--out', default=None)
    ap.add_argument('--ckpt', default=None)
    a = ap.parse_args()
    patch_loaders()
    device = 'mps' if torch.backends.mps.is_available() else 'cpu'

    eb_tr, eb_ho = cls2_ebook.split_ebook_boards()
    ep_tr, ep_ho = cls2_epub.split_epub_boards()
    old = cls2_real.load_real_boards()
    try: old += cls2_lasker.load_lasker_boards()
    except Exception as e: print('lasker skipped', e)
    bl = load_boards(a.blunders_boards, a.blunders_labels, do_refine=False)
    bl_ho = [b for i, b in enumerate(bl) if i % 20 == 19]; bl_tr = [b for i, b in enumerate(bl) if i % 20 != 19]
    print(f'ebook {len(eb_tr)}/{len(eb_ho)}  epub {len(ep_tr)}/{len(ep_ho)}  old {len(old)}  blunders {len(bl_tr)}/{len(bl_ho)}')

    srcs = [Square2Dataset(a.assets, length=200000, seed=1),
            RealCellsDataset(length=200000, seed=2, boards=old),
            RealCellsDataset(length=200000, seed=3, boards=ep_tr),
            RealCellsDataset(length=200000, seed=4, boards=eb_tr),
            RealCellsDataset(length=200000, seed=6, boards=bl_tr)]
    w = [0.25, 0.10, 0.15, 0.20, 0.30]
    dl = DataLoader(MixedDataset(srcs, w, a.train_size, seed=5), batch_size=256, shuffle=True,
                    num_workers=8, persistent_workers=True)
    model = ARCHS[a.arch]().to(device)
    if a.init: model.load_state_dict(torch.load(a.init, map_location=device))
    opt = torch.optim.Adam(model.parameters(), lr=a.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, a.epochs)
    sets = [('ebook-train', eb_tr), ('ebook-HOLD', eb_ho), ('epub-train', ep_tr), ('epub-HOLD', ep_ho),
            ('old-real', old), ('blunders-train', bl_tr), ('blunders-HOLD', bl_ho)]

    def rep(tag):
        print(tag, flush=True)
        for n, bs in sets:
            c, t, be = eval_boards(model, bs, device)
            print(f'   {n:15s} cell {c/t:.4f}  boards-wrong {be}/{len(bs)}', flush=True)
    rep('--- before ---')
    lf = nn.CrossEntropyLoss()
    for ep in range(a.epochs):
        model.train()
        for x, y in dl:
            x, y = x.to(device), y.to(device)
            opt.zero_grad(); lf(model(x), y).backward(); opt.step()
        sched.step()
        if (ep + 1) % 4 == 0: rep(f'--- epoch {ep+1} ---')
    model = model.cpu().eval()
    if a.ckpt: torch.save(model.state_dict(), a.ckpt)
    if a.out:
        torch.onnx.export(model, torch.zeros(1, 2, CELL, CELL), a.out, input_names=['cells'],
                          output_names=['logits'], dynamic_axes={'cells': {0: 'b'}, 'logits': {0: 'b'}},
                          opset_version=17, dynamo=False)
        print('exported', a.out)


if __name__ == '__main__':
    main()
