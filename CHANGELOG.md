# Changelog

All notable changes to ChessBook Reader are documented here. The project loosely
follows [Keep a Changelog](https://keepachangelog.com/) and
[Semantic Versioning](https://semver.org/).

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
