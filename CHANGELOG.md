# Changelog

All notable changes to ChessBook Reader are documented here. The project loosely
follows [Keep a Changelog](https://keepachangelog.com/) and
[Semantic Versioning](https://semver.org/).

## [2.1.0] — 2026-09-11

### Changed
- **Diagram recognition model retrained and improved.** The board-square
  classifier used to read printed diagrams was retrained on an expanded,
  hand-verified corpus (7 books, 1,821 board diagrams, including newly added
  *The Art of Attack in Chess*, *How to Reassess Your Chess*, and *The Life
  and Games of Mikhail Tal*), with corrected ground-truth labels and
  consistent extraction resolution across all source books. Training now
  uses plateau-based early stopping validated against the full corpus's
  post-repair legality rate rather than a fixed epoch count. Overall
  repaired-board legality improved from 97.2% to 97.9%, and hand-verified
  cell accuracy from 99.22% to 99.34%, with the largest gains on books that
  previously read worst.

## [2.0.0] — 2026-09-09

### Added
- **Chessnut Move electronic board support** (Pro): pair a Chessnut Move over
  Bluetooth for two-way sync with the app — moves you tap in the book or make
  on the virtual board move the physical pieces, and moves you make on the
  physical board update the app. On-board LEDs guide you back in sync if a
  mismatch is detected.
- **Play vs Computer** (Pro): play a full game against the built-in Stockfish
  engine from any position — a book anchor, a diagram, or a fresh start — at
  an adjustable, human-like strength. If a Chessnut Move is connected, the
  engine's moves are prompted on the physical board via LEDs.
- **Guess the Move** (Pro): a training mode that quizzes you to predict the
  next move in a book's game line before it's revealed, with hints and a
  running score.
- **Pro Unlock**: a one-time in-app purchase unlocks Chessnut Move sync, Play
  vs Computer, and Guess the Move for good, with 5 free trial sessions shared
  across the three so you can try them first.
- The empty-library screen now links to the Internet Archive to browse
  public-domain chess books.

### Fixed
- The macOS About panel now shows the author's name instead of the bundle
  identifier.

## [1.4.15] — 2026-08-19

### Changed
- New app icon and promotional artwork.

### Fixed
- Android release builds no longer abort during ONNX diagram recognition.
  ONNX Runtime's Java classes are now preserved from R8 obfuscation so its
  native JNI lookups resolve correctly.

## [1.4.9] — 2026-07-04

### Fixed
- **Orphaned entries on the Converted-books screen can now be deleted.** A
  converted book whose source file had been moved, deleted, or modified would
  linger on the screen but refuse to open (its tile was disabled) or erase (the
  delete re-derived the cache key from the now-missing source and silently
  failed). Deletion now targets the actual cache file recorded when the list is
  built, so the ghost entry clears on the first tap.

## [1.4.8] — 2026-07-04

### Added
- **Training diagrams are now rendered instead of dropped.** Teaching books
  like *Bobby Fischer Teaches Chess* draw arrows and mark squares with "x" on
  their diagrams; the reader previously discarded those diagrams entirely. It
  now rebuilds the position and draws the annotations on top — green arrows
  (recovered from the arrow segmenter's mask) and red ✕ marks on the x‑ed
  squares. A training diagram that still can't be read reliably (e.g. the
  letter‑labelled flight‑square pages) is kept in the reading view as its
  printed image instead of vanishing. Conversion cache bumped to v21, so books
  reconvert on first open.

## [1.4.1] — 2026-06-28

### Changed
- **Native OCR everywhere.** Scanned books are now read with the operating
  system's built‑in text recognizer on every platform — Apple Vision on
  iOS/macOS, Google ML Kit on Android, and Windows.Media.Ocr on Windows. This is
  faster and more accurate than the previously bundled engine and lets every
  build ship ~13 MB smaller (the bundled ONNX OCR models are gone). Diagram
  recognition is unchanged.

## [1.4.0] — 2026-06-28

### Changed
- **Better OCR for scanned books.** On iPhone and Android, scanned books are now
  read with the device's built‑in text recognizer (Apple Vision / Google ML
  Kit) by default — faster and more accurate than the previously bundled engine,
  which also lets the mobile app ship ~13 MB smaller. No setting to configure.
- On Windows and macOS the bundled OCR engine was upgraded (PP‑OCRv4), and on
  macOS it now runs with CoreML hardware acceleration. Diagram recognition is
  CoreML‑accelerated on Apple devices too.

## [1.2.0] — 2026-06-28

### Added
- **Scan a paper book** (iOS/Android): a new "Scan a paper book" action on the
  library screen opens the device's native document scanner (VisionKit on iOS,
  ML Kit on Android) to photograph the pages of a printed book. Captured pages
  are auto‑cropped and de‑skewed, assembled into a PDF, then run through the
  existing import pipeline — so on‑device OCR and diagram recognition happen
  automatically, exactly as when opening a scanned PDF. Adds an iOS camera‑usage
  permission prompt. The action is hidden on desktop.

## [1.1.3] — 2026-06-27

### Fixed
- Improved scanned‑PDF OCR accuracy with wider detector line‑box padding, so
  leading/trailing glyphs are no longer clipped.

## [1.1.2] — 2026-06-27

### Fixed
- Removing a book from the bookshelf grid no longer removes the wrong book.

## [1.1.0] — 2026-06-25

### Added
- On‑device OCR for scanned/image‑only PDFs, giving them a text layer for the
  reflowed reading view, search, and clickable moves.

## [1.0.0] — 2026-06-21

### Changed
- Rebranded to **ChessBook Reader** with a new app identity, full‑bleed icon, and
  a bundled sample book.

[1.4.1]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.4.1
[1.4.0]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.4.0
[1.2.0]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.2.0
[1.1.3]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.1.3
[1.1.2]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.1.2
[1.1.0]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.1.0
[1.0.0]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.0.0
