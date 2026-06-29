"""Run the shipped ONNX square classifier over dumped board cells.

Reads <root>/p<page>_b<idx>/cell_<rr><ff>.png (the EXACT cells the Dart
sliceBoardCells produced), replicates the Dart preprocessing and emptiness gate,
runs onnxruntime, and writes JSON: a list of {id, labels[64], probs[64][13]}.

This is the real CNN the app uses, so feeding the output into the Dart
repairToLegal tests the shipped pipeline end to end (minus the GUI).

Usage:
  python infer_cells.py <cellsRoot> <model.onnx> <out.json>
"""
import json
import math
import os
import sys

import numpy as np
import onnxruntime as ort
from PIL import Image

from model import CELL, CLASSES

# Mirror onnx_square_classifier.dart: a cell is forced to empty regardless of
# the CNN if its normalized-pixel std-dev is below _EMPTY_STD, OR its central
# region has almost no dark ink (_EMPTY_CENTRAL_MASS) — the latter catches
# hatched "dark" squares that pass the std gate but hold no piece.
_EMPTY_STD = 0.08
_EMPTY_CENTRAL_MASS = 0.05
_DARK_NORM = -0.14  # normalized pixel <= this counts as dark ink (~gray 110)


def _central_dark_mass(cell):
    """Fraction of dark ink in the inner ~56% of a normalized [32,32] cell."""
    lo = (CELL * 22) // 100
    hi = CELL - lo
    cen = cell[lo:hi, lo:hi]
    return float((cen <= _DARK_NORM).mean())


def _preprocess(path):
    """Grayscale -> 32x32 -> (x/255-0.5)/0.5, matching preprocessCell."""
    gray = Image.open(path).convert("L").resize((CELL, CELL), Image.BILINEAR)
    arr = np.asarray(gray, np.float32)
    return (arr / 255.0 - 0.5) / 0.5


def _board_cells(board_dir):
    cells = np.zeros((64, 1, CELL, CELL), np.float32)
    for r in range(8):
        for f in range(8):
            cells[r * 8 + f, 0] = _preprocess(
                os.path.join(board_dir, f"cell_{r}{f}.png"))
    return cells


def main():
    root, model_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    sess = ort.InferenceSession(model_path)
    in_name = sess.get_inputs()[0].name

    boards = []
    for name in sorted(os.listdir(root)):
        bdir = os.path.join(root, name)
        if not os.path.isdir(bdir):
            continue
        cells = _board_cells(bdir)
        logits = sess.run(None, {in_name: cells})[0]  # [64, 13]

        labels, probs = [], []
        for i in range(64):
            row = logits[i].astype(np.float64)
            m = row.max()
            exp = np.exp(row - m)
            soft = exp / exp.sum()
            probs.append([float(x) for x in soft])
            std = float(cells[i, 0].std())
            empty = std < _EMPTY_STD or \
                _central_dark_mass(cells[i, 0]) < _EMPTY_CENTRAL_MASS
            labels.append("" if empty else CLASSES[int(row.argmax())])
        boards.append({"id": name, "labels": labels, "probs": probs})

    with open(out_path, "w") as fh:
        json.dump(boards, fh)
    print(f"{len(boards)} boards -> {out_path}")


if __name__ == "__main__":
    main()
