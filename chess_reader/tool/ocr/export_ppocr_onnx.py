"""Vendor the PP-OCR (mobile) detection + recognition ONNX models and the
recognition dictionary into ``assets/models/`` for the in-app text-page OCR.

These models are *pretrained* and vendored as-is — unlike the chess-diagram
models in ``tool/vision_train`` (which are trained here on synthetic data).

Why RapidOCR: it redistributes PaddleOCR's PP-OCR models already converted to
ONNX, with the matching character dictionary, so no PaddlePaddle / paddle2onnx
toolchain is needed. The Dart pipeline (lib/features/ocr) is written to the
PP-OCR preprocessing conventions these models expect:
  * detection input  : RGB, /255, ImageNet mean/std, NCHW, sides %32
  * recognition input: RGB, (x/255-0.5)/0.5, height 48, NCHW
  * recognition head : CTC over ['<blank>', *dict_lines, ' ']

Detector: PP-OCRv3 mobile (bundled in the rapidocr package).
Recognizer: PP-OCRv4 mobile — a drop-in upgrade over v3 (same size and dict,
fewer errors on degraded scans; see tool/ocr/bench/bench.py). The v4 rec isn't
bundled in rapidocr, so it's fetched from the same RapidOCR model repo on
Hugging Face.

Usage:
    pip install rapidocr-onnxruntime
    python tool/ocr/export_ppocr_onnx.py

Outputs (overwritten):
    assets/models/ocr_det.onnx
    assets/models/ocr_rec.onnx
    assets/models/ocr_keys.txt
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

# assets/models relative to the Flutter project root (two levels up from here).
REPO_ROOT = Path(__file__).resolve().parents[2]
ASSETS = REPO_ROOT / "assets" / "models"

DET_OUT = ASSETS / "ocr_det.onnx"
REC_OUT = ASSETS / "ocr_rec.onnx"
KEYS_OUT = ASSETS / "ocr_keys.txt"


# PP-OCRv4 mobile recognizer in the RapidOCR Hugging Face model repo.
REC_V4_URL = (
    "https://huggingface.co/SWHL/RapidOCR/resolve/main/"
    "PP-OCRv4/ch_PP-OCRv4_rec_infer.onnx"
)


def _locate_det() -> Path:
    """Return the PP-OCRv3 mobile detector bundled with rapidocr-onnxruntime."""
    try:
        import rapidocr_onnxruntime as ro
    except ImportError as exc:  # pragma: no cover - environment guard
        raise SystemExit(
            "rapidocr-onnxruntime is not installed.\n"
            "  pip install rapidocr-onnxruntime\n"
            "then re-run this script."
        ) from exc

    models_dir = Path(ro.__file__).resolve().parent / "models"
    hits = sorted(p for p in models_dir.glob("*det*.onnx"))
    if not hits:
        raise SystemExit(f"No detector model under {models_dir}")
    # Prefer the smallest match — the *mobile* model, not a server one.
    return min(hits, key=lambda p: p.stat().st_size)


def _fetch_rec_v4() -> Path:
    """Download the PP-OCRv4 mobile recognizer to a cache next to this script."""
    import urllib.request

    cache = Path(__file__).resolve().parent / "_cache"
    cache.mkdir(exist_ok=True)
    dest = cache / "ch_PP-OCRv4_rec_infer.onnx"
    if not dest.exists():
        print(f"downloading {REC_V4_URL} ...")
        urllib.request.urlretrieve(REC_V4_URL, dest)
    return dest


def _extract_dict(rec_onnx: Path) -> list[str]:
    """The recognition dictionary is embedded in the rec model's ONNX metadata
    under the `character` key (RapidOCR convention), newline-joined, one char
    per entry. Returns the list of characters (no blank, no trailing space)."""
    import onnx

    model = onnx.load(str(rec_onnx))
    meta = {p.key: p.value for p in model.metadata_props}
    raw = meta.get("character")
    if not raw:
        raise SystemExit(
            f"No 'character' dictionary in {rec_onnx} metadata; this exporter "
            "expects a RapidOCR rec model."
        )
    return [c for c in raw.split("\n") if c != ""]


def main() -> int:
    ASSETS.mkdir(parents=True, exist_ok=True)
    det = _locate_det()
    rec = _fetch_rec_v4()
    chars = _extract_dict(rec)

    shutil.copyfile(det, DET_OUT)
    shutil.copyfile(rec, REC_OUT)
    KEYS_OUT.write_text("\n".join(chars) + "\n", encoding="utf-8")

    print(f"det  : {det.name}\n   -> {DET_OUT} ({DET_OUT.stat().st_size // 1024} KiB)")
    print(f"rec  : {rec.name}\n   -> {REC_OUT} ({REC_OUT.stat().st_size // 1024} KiB)")
    print(f"keys : {len(chars)} chars\n   -> {KEYS_OUT}")
    print("\nDone. The Dart loader prepends '<blank>' and appends ' ' to keys.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
