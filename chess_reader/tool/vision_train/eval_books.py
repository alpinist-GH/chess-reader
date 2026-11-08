"""Label-free comparison of checkpoints on app-extracted board crops.

Metric: fraction of boards whose RAW prediction (no repair) is structurally
legal (exactly one K and one k, no pawns on ranks 1/8, <=8 pawns/side, <=16
pieces/side), plus the share with all-confident cells. Runs each checkpoint with
and without lattice refinement.

  python eval_books.py <crops_dir> <slug_prefix_filter|-> ckpt[:norefine] ...
"""
import collections, glob, os, sys
import numpy as np, torch
from multiprocessing import Pool
from PIL import Image
from cls2_model import SquareCNN2
from grid_refine import refine
from model import CELL, CLASSES
import seg_test


def cells(gray):
    m = seg_test.predict_mask(gray)
    h, w = gray.shape
    x = np.zeros((64, 2, CELL, CELL), np.float32)
    for r in range(8):
        for f in range(8):
            ys, ye, xs, xe = round(r*h/8), round((r+1)*h/8), round(f*w/8), round((f+1)*w/8)
            g = np.asarray(Image.fromarray(gray[ys:ye, xs:xe]).resize((CELL, CELL), Image.BILINEAR), np.float32)
            mm = np.asarray(Image.fromarray((m[ys:ye, xs:xe]*255).astype(np.uint8)).resize((CELL, CELL), Image.BILINEAR), np.float32)/255
            x[r*8+f, 0] = (g/255-.5)/.5; x[r*8+f, 1] = mm
    return x


def prep(p):
    g = np.asarray(Image.open(p).convert('L'))
    rp = os.path.join(os.path.dirname(p), 'refined', os.path.basename(p))
    r = np.asarray(Image.open(rp).convert('L'))
    return os.path.basename(p), cells(g), cells(r)


def legal(l):
    k, K = l.count('k'), l.count('K')
    if k != 1 or K != 1: return False
    if any(l[i] in ('P', 'p') or l[56+i] in ('P', 'p') for i in range(8)): return False
    if l.count('P') > 8 or l.count('p') > 8: return False
    return sum(c.isupper() for c in l) <= 16 and sum(c.islower() for c in l) <= 16


if __name__ == '__main__':
    d, flt = sys.argv[1], sys.argv[2]
    paths = sorted(glob.glob(d + '/*.png'))
    if flt != '-': paths = [p for p in paths if os.path.basename(p).startswith(flt)]
    data = [prep(p) for p in paths]
    bybook = collections.defaultdict(list)
    for name, a, b in data: bybook[name.split('_p')[0]].append((a, b))
    for spec in sys.argv[3:]:
        ck, _, mode = spec.partition(':')
        m = SquareCNN2(); m.load_state_dict(torch.load(ck)); m.eval()
        print(f'== {spec} ==')
        tot = collections.Counter()
        for book, items in sorted(bybook.items()):
            ok = 0
            for a, b in items:
                x = a if mode == 'norefine' else b
                with torch.no_grad(): lg = m(torch.from_numpy(x)).numpy()
                lab = ['' if x[i, 0].std() < 0.08 else CLASSES[int(lg[i].argmax())] for i in range(64)]
                ok += legal(lab)
            tot['ok'] += ok; tot['n'] += len(items)
            print(f'  {book:10s} legal {ok}/{len(items)} = {ok/len(items):.2f}')
        print(f'  ALL        legal {tot["ok"]}/{tot["n"]} = {tot["ok"]/tot["n"]:.3f}')
