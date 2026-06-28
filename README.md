# ChessBook Reader

An **offline, cross‑platform interactive chess book reader** built with Flutter.
Open your own PDF/EPUB chess books, click any move in the text to follow it on a
board, analyse positions with an embedded Stockfish engine, and let a **local
vision model read printed diagrams into positions** — all with no internet
connection or server.

The Flutter app lives in [`chess_reader/`](chess_reader/).

## Download

**Windows:** download the installer from the latest release —
[**chessbook-reader-setup-1.4.1.exe**](https://github.com/alpinist-GH/chess-reader/releases/download/chessbook-v1.4.1/chessbook-reader-setup-1.4.1.exe)
([all releases](https://github.com/alpinist-GH/chess-reader/releases/latest)).

It's a per‑user install (no administrator rights needed). The installer is
unsigned, so Windows SmartScreen may warn — choose **More info → Run anyway**.
The Stockfish engine and the diagram‑recognition model are bundled; everything
runs offline.

**macOS:** build from source on a Mac (Flutter + Xcode) and package a `.dmg`
with the bundled helper script — see [Building](#building). Requires macOS 14+
and a Mac with a Metal‑capable GPU.

Other platforms: build from source (see [Building](#building)).

## Features

- **Clickable moves** — tap a move in the book and the side board jumps to that
  position; step through lines and explore your own variations, then snap back
  to the book.
- **Two reading views for PDF** — the original printed pages, or a reflowed HTML
  reading view (easier on small screens). Choose at open, switch anytime; EPUB
  is always HTML.
- **Scan a paper book** *(mobile)* — photograph the pages of a physical chess
  book with the device's document scanner (auto‑crop and de‑skew); the pages are
  combined into a PDF, text is recovered with on‑device OCR, and diagrams are
  recognised — just like opening a scanned PDF.
- **Automatic diagram recognition** — every printed diagram in the book is
  detected on open, shown with its detected FEN, and **tap to load it onto the
  board**. Results are cached to disk so reopening is instant.
- **Embedded Stockfish** — analyse any position fully offline (bundled engine on
  desktop, FFI on mobile).
- **Cover‑art library** — a home shelf of recent and already‑converted books
  shown as a grid of their real cover pages (extracted from the PDF/EPUB), plus
  export of a converted book to standalone HTML.
- **Open in Lichess / Chess.com** — send the current position to the web for
  further analysis (optional; the app itself stays offline).
- **Comfort** — a light / dark / system theme, resume where you left off,
  bookmarks, full‑text search (figurine‑aware), table of contents, and a
  resizable board you can place left, right, top or bottom of the text (or let
  it adapt) — handy on phones. Configurable piece set / board theme / engine depth.

## How it works

| Concern | Approach |
|---|---|
| Board & chess logic | `chessground` + `dartchess` (lichess) |
| PDF | `pdfrx` (PDFium) — text rects for tap targets, page rasters for vision |
| EPUB | zip + XHTML parsed directly, rendered via `flutter_html` |
| Engine | bundled Stockfish over UCI (desktop) / `multistockfish` FFI (mobile) |
| Vision | classical CV board locator + a small per‑square CNN exported to ONNX, run with `flutter_onnxruntime` |
| State | `flutter_riverpod` |

The vision model is a ~150k‑parameter CNN classifying each of the 64 squares
(13 classes), trained on synthetic book‑style diagrams. See
[`chess_reader/docs/`](chess_reader/docs/) for notes.

## Building

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install).

```bash
cd chess_reader
flutter pub get
flutter test          # 47 tests
flutter run -d windows # or macos / android / ios
```

Stockfish is not committed (it is large and GPL). Fetch it before a desktop
build:

```powershell
pwsh chess_reader/tool/fetch_stockfish.ps1
```

### Windows installer

```powershell
cd chess_reader
flutter build windows --release
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" windows\installer\chess_reader.iss
# → chess_reader/dist/chessbook-reader-setup-<version>.exe (per‑user, no admin needed)
```

### macOS .dmg

Build and package on a Mac (Flutter + Xcode required; cannot be produced on
Windows):

```bash
cd chess_reader
tool/build_macos.sh
# → chess_reader/dist/chessbook-reader-<version>-macos.dmg
```

The `.app`/`.dmg` is unsigned (no paid Apple Developer account needed); on first
launch right‑click the app → **Open** to bypass Gatekeeper.

## License

This program is free software, licensed under the **GNU General Public License
v3.0**. It bundles Stockfish and the lichess `chessground` / `dartchess`
libraries, which are themselves GPL/open source.

## Author

Made by **Vu‑Hung Quan**.
