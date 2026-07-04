# Square classifier training

Trains the per-square CNN that turns a printed chess diagram into a FEN
(Phase 5 vision). The exported model lives at
`chess_reader/assets/models/square_classifier.onnx` and is committed; you
only need to retrain to improve recognition.

## Why a custom model (not tsoj/Chess_diagram_to_FEN)

tsoj is a 5-model pipeline built for photos (perspective warp, rotation,
orientation detection) and is awkward to export. Our diagrams are already
located and axis-aligned by the classical-CV `BoardLocator`, so a single
small per-square CNN is simpler, exports to ONNX trivially, and drops into
the existing `SquareClassifier` interface.

## Approach

- **Synthetic data** (`dataset.py`): composites chessground piece PNGs (21
  book-like sets) onto randomized square backgrounds, then augments to bridge
  the gap to printed book diagrams.
  - Backgrounds include **hatching / cross-hatch / stipple** textures — the
    Gambit test book draws "dark" squares as light paper with diagonal
    hatching, not solid fill. Without this the model reads every empty hatched
    square as a knight.
  - Augmentation: grayscale, mild downscale/blur, contrast/brightness, light
    noise, grid lines. It does NOT alter piece fill colour — white pieces stay
    light/outline, black stay solid, which is the white/black cue.
- **Model** (`model.py`): `SquareCNN`, ~156k params, 32×32 grayscale → 13
  classes (`K Q R B N P k q r b n p` + empty). Class order MUST match Dart
  `squareLabels`.
- **Preprocessing** must match Dart `board_slicer.dart`:
  `(gray/255 - 0.5) / 0.5`.

## Run

```powershell
# one-time
py -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt

# train + export (assets = chessground piece_sets in the pub cache)
$cg = "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev\chessground-10.0.3\assets\piece_sets"
.venv\Scripts\python train.py --assets $cg --out ..\..\assets\models\square_classifier.onnx
```

## Validate

```powershell
# Synthetic accuracy (clean + degraded):
.venv\Scripts\python eval_onnx.py --assets $cg --model ..\..\assets\models\square_classifier.onnx

# Real book diagrams: first export their cells with the Dart tool, then:
#   dart run tool/dump_board_cells.dart <book.pdf> %TEMP%\book_cells 21 22
.venv\Scripts\python eval_cells.py --model ..\..\assets\models\square_classifier.onnx --cells $env:TEMP\book_cells
```

## Old-print EPUB finetune (Chess Strategy / Chess Fundamentals scans)

The two EPUB scans in the repo root broke the shipped model (58% occupied-square
accuracy: engraving fonts read pawns as R/B and kings as Q; bleed-through and
mottled hatching add phantoms; very faint white glyphs fell under the old
central-dark-mass emptiness gate, which is now removed from the app).

- `_eval_epub.py <img_dir> <out_dir>` — app-faithful repro over a directory of
  diagram images: locate, peel, segment, classify; writes board crops +
  `results.tsv` (name, FEN). Extract EPUB images with `unzip -j book.epub
  'OEBPS/*.jpg' -d dir` first.
- `cls2_epub.py` — loads labeled boards from `tool/epub_boards/`. Lasker labels
  reuse `lasker_labels.json` (same book as the bundled PDF, diagram numbers map
  1:1); Capablanca labels are hand-read in `fund_labels.json`.
- `cls2_epub_finetune.py --assets $cg --out ..\..\assets\models\square_classifier2.onnx`
  — warm-start finetune on synthetic + previous real sources + EPUB cells, with
  held-out EPUB boards. Result: holdout 83%→98% cell acc, old sources unchanged.
- `cls2_consensus.py --imgs <epub jpg dir>` — corpus-wide pseudo-labels for the
  Chess Strategy book by cross-checking the EPUB scan against the sample-PDF
  rendering (`tool/lasker_diagrams`): agreeing cells become labels, paired
  adjacent disagreements (glyph-straddle shifts) are excluded, and unpaired
  "PDF empty / EPUB piece" cells are labeled empty (reverse-page bleed-through
  phantoms — the dominant user-visible error). Writes `lasker_consensus.json`
  (committed). Pass the same dir to `cls2_epub_finetune.py --consensus-imgs`
  to train with it. Result: corpus structural plausibility (after repair)
  146→156/167 on the Lasker EPUB and 109→132/148 on Chess Fundamentals, with
  hand-labeled holdout up 97.9→98.4% and old sources up slightly.
  Do NOT hand-relabel individual cells from crop images: this book's print
  places some glyphs visibly off their logical square, and the end-to-end
  pipeline is self-consistently right where isolated cells look wrong.
