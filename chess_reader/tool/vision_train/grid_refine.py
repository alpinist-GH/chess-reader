"""Checkerboard-lattice refinement of the inside-frame board crop.

`crop_inside_frame` only peels edge rows/cols that are >80% dark, so a frame
drawn as thick outer line + white gap + thin inner line leaves the grid offset
by a fraction of a cell. The true board is a sub-rectangle of the peeled crop;
we pick the one whose 8x8 cell means best fit an alternating light/dark
checkerboard (hatched or filled dark squares are always darker than light ones,
pieces only perturb a few cells). Mirrors `refineGrid` in board_slicer.dart.
"""
import numpy as np

MAX_TRIM = 0.6  # of one cell, per side
STEP = 2


def _integral(g):
    return np.pad(g.astype(np.float64).cumsum(0).cumsum(1), ((1, 0), (1, 0)))


def refine_rect(gray):
    """gray HxW uint8 (already frame-peeled) -> (x0, y0, x1, y1) exclusive ends."""
    h, w = gray.shape
    ii = _integral(gray)
    cx, cy = w / 8.0, h / 8.0
    mx, my = int(cx * MAX_TRIM), int(cy * MAX_TRIM)
    par = np.fromfunction(lambda r, f: (-1.0) ** (r + f), (8, 8))
    best, rect = -1e18, (0, 0, w, h)
    for x0 in range(0, mx + 1, STEP):
        for x1 in range(w - mx, w + 1, STEP):
            xs = np.round(x0 + (x1 - x0) * np.arange(9) / 8).astype(int)
            for y0 in range(0, my + 1, STEP):
                for y1 in range(h - my, h + 1, STEP):
                    ys = np.round(y0 + (y1 - y0) * np.arange(9) / 8).astype(int)
                    s = (ii[np.ix_(ys[1:], xs[1:])] - ii[np.ix_(ys[:-1], xs[1:])]
                         - ii[np.ix_(ys[1:], xs[:-1])] + ii[np.ix_(ys[:-1], xs[:-1])])
                    area = np.outer(np.diff(ys), np.diff(xs))
                    m = s / area
                    sc = abs((m * par).sum())
                    if sc > best:
                        best, rect = sc, (x0, y0, x1, y1)
    return rect


SEARCH_SIDE = 352  # search on a copy no larger than this (cell ~44px)


def refine_rect_scaled(gray):
    """refine_rect for any size: search on a block-mean downscale, map back."""
    h, w = gray.shape
    k = max(1, round(min(h, w) / SEARCH_SIDE))
    if k == 1:
        return refine_rect(gray)
    hh, ww = h // k, w // k
    small = gray[:hh * k, :ww * k].reshape(hh, k, ww, k).mean((1, 3)).astype(np.uint8)
    x0, y0, x1, y1 = refine_rect(small)
    return (x0 * k, y0 * k, min(w, x1 * k), min(h, y1 * k))


def refine(gray):
    x0, y0, x1, y1 = refine_rect_scaled(gray)
    return gray[y0:y1, x0:x1]
