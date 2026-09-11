"""Python port of lib/features/vision/domain/board_repair.dart.

Keep this in sync with the Dart original — it exists so the corpus-wide
legality eval (infer_ebook_boards.py) measures what the shipped app actually
produces (after repair), not the raw per-cell argmax the app never shows.
"""
from model import CLASSES

_LABEL_INDEX = {c: i for i, c in enumerate(CLASSES)}
_EMPTY = _LABEL_INDEX['']
_WHITE_KING = _LABEL_INDEX['K']
_BLACK_KING = _LABEL_INDEX['k']
_WHITE_PAWN = _LABEL_INDEX['P']
_BLACK_PAWN = _LABEL_INDEX['p']

_WHITE_OFFICERS = ['Q', 'R', 'B', 'N']
_BLACK_OFFICERS = ['q', 'r', 'b', 'n']
_OFFICER_STD_MAX = {'Q': 1, 'R': 2, 'B': 2, 'N': 2, 'q': 1, 'r': 2, 'b': 2, 'n': 2}


def _demotable(c):
    return c not in (_WHITE_KING, _BLACK_KING, _WHITE_PAWN, _BLACK_PAWN)


def _cells_labelled(out, label):
    return [i for i in range(64) if out[i] == label]


def _adjacent(a, b):
    return abs(a // 8 - b // 8) <= 1 and abs(a % 8 - b % 8) <= 1


def _next_best(p, allowed):
    best_idx, best_val = _EMPTY, -1.0
    for c in range(len(p)):
        if c == _EMPTY or not allowed(c):
            continue
        if p[c] > best_val:
            best_val, best_idx = p[c], c
    if allowed(_EMPTY) and p[_EMPTY] > best_val:
        return _EMPTY
    return best_idx


def _demote(out, probs, cell, allowed):
    out[cell] = CLASSES[_next_best(probs[cell], allowed)]


def _cap_kings(out, probs, king):
    king_idx = _LABEL_INDEX[king]
    other = 'k' if king == 'K' else 'K'
    other_idx = _LABEL_INDEX[other]
    cells = _cells_labelled(out, king)
    if len(cells) <= 1:
        return False
    cells.sort(key=lambda c: (probs[c][king_idx], c))
    keep = cells.pop()  # most-confident king stays

    if not _cells_labelled(out, other):
        flip = max(cells, key=lambda c: probs[c][other_idx])
        out[flip] = other
        cells.remove(flip)

    for cell in cells:
        if _adjacent(cell, keep):
            out[cell] = ''
        else:
            _demote(out, probs, cell, _demotable)
    return True


def _clear_back_rank_pawns(out, probs):
    changed = False
    for i in range(64):
        on_back = i < 8 or i >= 56
        if not on_back:
            continue
        if out[i] in ('P', 'p'):
            _demote(out, probs, i, _demotable)
            changed = True
    return changed


def _cap_pawns(out, probs, pawn):
    pawn_idx = _LABEL_INDEX[pawn]
    cells = _cells_labelled(out, pawn)
    if len(cells) <= 8:
        return False
    cells.sort(key=lambda c: (probs[c][pawn_idx], c))
    for c in cells[:len(cells) - 8]:
        _demote(out, probs, c, _demotable)
    return True


def _roomy(out, c):
    label = CLASSES[c]
    std = _OFFICER_STD_MAX.get(label)
    if std is None:
        return True
    return len(_cells_labelled(out, label)) < std


def _cap_promoted_material(out, probs, own_officers, pawn):
    budget = max(0, 8 - len(_cells_labelled(out, pawn)))

    surplus = []
    for officer in own_officers:
        cells = _cells_labelled(out, officer)
        std = _OFFICER_STD_MAX[officer]
        if len(cells) <= std:
            continue
        idx = _LABEL_INDEX[officer]
        cells.sort(key=lambda c: (probs[c][idx], c))
        surplus.extend(cells[:len(cells) - std])

    if len(surplus) <= budget:
        return False

    surplus.sort(key=lambda c: (probs[c][_LABEL_INDEX[out[c]]], c))
    for cell in surplus[:len(surplus) - budget]:
        type_idx = _LABEL_INDEX[out[cell]]
        _demote(out, probs, cell,
                lambda c, ti=type_idx: _demotable(c) and c != ti and _roomy(out, c))
    return True


def repair_to_legal(labels, probs):
    """[labels] (64, rank8->rank1, a->h) + [probs] (64x13 softmax rows) -> new labels list."""
    out = list(labels)
    iterations = 0
    changed = True
    while changed and iterations < 6:
        changed = False
        changed |= _cap_kings(out, probs, 'K')
        changed |= _cap_kings(out, probs, 'k')
        changed |= _clear_back_rank_pawns(out, probs)
        changed |= _cap_pawns(out, probs, 'P')
        changed |= _cap_pawns(out, probs, 'p')
        changed |= _cap_promoted_material(out, probs, _WHITE_OFFICERS, 'P')
        changed |= _cap_promoted_material(out, probs, _BLACK_OFFICERS, 'p')
        iterations += 1
    return out
