# Changelog

All notable changes to ChessBook Reader are documented here. The project loosely
follows [Keep a Changelog](https://keepachangelog.com/) and
[Semantic Versioning](https://semver.org/).

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

[1.2.0]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.2.0
[1.1.3]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.1.3
[1.1.2]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.1.2
[1.1.0]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.1.0
[1.0.0]: https://github.com/alpinist-GH/chess-reader/releases/tag/chessbook-v1.0.0
