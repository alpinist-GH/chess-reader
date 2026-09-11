import json
import os
import sys
import numpy as np
import onnxruntime as ort
from PIL import Image

_HERE = os.path.dirname(os.path.abspath(__file__))
_CR_ROOT = os.path.abspath(os.path.join(_HERE, '..', '..'))
_MODEL_PATH = os.path.join(_CR_ROOT, 'assets/models/square_classifier2.onnx')
_SEG_MODEL = os.path.join(_CR_ROOT, 'assets/models/arrow_seg.onnx')
_MANIFEST = os.path.join(_CR_ROOT, 'tool/ebook_boards/manifest.json')
_OUT_PATH = os.path.join(_CR_ROOT, 'tool/ebook_boards/candidates.json')

_CLS2 = ort.InferenceSession(_MODEL_PATH)
_SEG = ort.InferenceSession(_SEG_MODEL)

CELL = 32
SEG_SIZE = 192
sys.path.insert(0, _HERE)
from model import CLASSES
_EMPTY_STD = 0.08
_EMPTY_CENTRAL_MASS = 0.05
_DARK_NORM = -0.14

def predict_mask(gray):
    h, w = gray.shape
    inp = np.asarray(Image.fromarray(gray).resize((SEG_SIZE, SEG_SIZE), Image.BILINEAR), np.float32)
    x = ((inp / 255.0 - 0.5) / 0.5)[None, None]
    logit = _SEG.run(None, {'board': x})[0][0, 0]
    prob = 1 / (1 + np.exp(-logit))
    return np.asarray(Image.fromarray((prob * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR), np.float32) / 255.0

def central_dark_mass(cell):
    lo = (CELL * 22) // 100
    hi = CELL - lo
    cen = cell[lo:hi, lo:hi]
    return float((cen <= _DARK_NORM).mean())

def to_fen(labels):
    rows = []
    for r in range(8):
        s = ''
        e = 0
        for f in range(8):
            c = labels[r * 8 + f]
            if c == '':
                e += 1
            else:
                if e:
                    s += str(e)
                    e = 0
                s += c
        if e:
            s += str(e)
        rows.append(s)
    return '/'.join(rows)

def check_chess_validity(labels):
    wk = labels.count('K')
    bk = labels.count('k')
    if wk != 1 or bk != 1:
        return False, f"kings: W={wk}, B={bk}"
    for i in range(8):
        if labels[i] in ('P', 'p'):
            return False, f"pawn on rank 8 (sq {i})"
        if labels[56 + i] in ('P', 'p'):
            return False, f"pawn on rank 1 (sq {56 + i})"
    wpawns = labels.count('P')
    bpawns = labels.count('p')
    if wpawns > 8 or bpawns > 8:
        return False, f"pawns count: W={wpawns}, B={bpawns}"
    wtotal = sum(1 for x in labels if x.isupper())
    btotal = sum(1 for x in labels if x.islower())
    if wtotal > 16 or btotal > 16:
        return False, f"total pieces: W={wtotal}, B={btotal}"
    return True, "legal_structure"

def main():
    if not os.path.exists(_MANIFEST):
        print(f"Manifest not found: {_MANIFEST}")
        return

    with open(_MANIFEST) as f:
        manifest = json.load(f)

    results = []
    num_plausible = 0
    per_book_counts = {}

    for item in manifest:
        bid = item['id']
        book = item['book']
        per_book_counts.setdefault(book, {'total': 0, 'legal': 0})
        per_book_counts[book]['total'] += 1

        b_dir = os.path.join(_CR_ROOT, item['dir'])
        inner_path = os.path.join(b_dir, 'inner.png')
        board_path = os.path.join(b_dir, 'board.png')

        if not os.path.exists(inner_path):
            continue

        inner_gray = np.asarray(Image.open(inner_path).convert('L'))
        board_gray = np.asarray(Image.open(board_path).convert('L'))
        
        mask = predict_mask(board_gray)
        h, w = inner_gray.shape
        mask_inner = np.asarray(Image.fromarray((mask * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR), np.float32) / 255.0

        cells = np.zeros((64, 2, CELL, CELL), np.float32)
        for r_ in range(8):
            for f in range(8):
                ys, ye = round(r_ * h / 8), round((r_ + 1) * h / 8)
                xs, xe = round(f * w / 8), round((f + 1) * w / 8)
                gc = np.asarray(Image.fromarray(inner_gray[ys:ye, xs:xe]).resize((CELL, CELL), Image.BILINEAR), np.float32)
                mc = mask_inner[ys:ye, xs:xe]
                mc_resized = np.asarray(Image.fromarray((mc * 255).astype(np.uint8)).resize((CELL, CELL), Image.BILINEAR), np.float32) / 255.0
                cells[r_ * 8 + f, 0] = (gc / 255.0 - 0.5) / 0.5
                cells[r_ * 8 + f, 1] = mc_resized

        logits = _CLS2.run(None, {'cells': cells})[0]
        labels = []
        confs = []
        for i in range(64):
            row = logits[i].astype(np.float64)
            soft = np.exp(row - row.max())
            soft /= soft.sum()
            std = float(cells[i, 0].std())
            empty = std < _EMPTY_STD
            c = '' if empty else CLASSES[int(row.argmax())]
            labels.append(c)
            confs.append(float(soft[0]) if empty else float(soft.max()))

        fen = to_fen(labels)
        is_legal, reason = check_chess_validity(labels)
        if is_legal:
            num_plausible += 1
            per_book_counts[book]['legal'] += 1

        results.append({
            'id': bid,
            'book': book,
            'page': item['page'],
            'boardIndex': item['boardIndex'],
            'predicted_fen': fen,
            'mean_conf': float(np.mean(confs)),
            'min_conf': float(np.min(confs)),
            'is_structurally_legal': is_legal,
            'validity_reason': reason,
            'board_png': board_path,
            'inner_png': inner_path
        })

    with open(_OUT_PATH, 'w') as f:
        json.dump(results, f, indent=2)

    print(f"Total processed: {len(results)}")
    print(f"Structurally legal without repair: {num_plausible}/{len(results)} ({num_plausible/len(results)*100:.1f}%)")
    for book, stat in per_book_counts.items():
        tot = stat['total']
        leg = stat['legal']
        print(f"  {book}: {leg}/{tot} ({leg/tot*100:.1f}%) cleanly legal positions on model")

if __name__ == '__main__':
    main()
