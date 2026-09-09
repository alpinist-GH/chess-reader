# Interactive Chess Book Reader — Implementation Plan

## Context

Build a fully offline, cross-platform (Windows, macOS, Android, iOS) Flutter app that turns PDF/EPUB chess books into interactive books: moves printed in the text become clickable and an on-screen board follows along, an embedded Stockfish analyzes any position, and a local vision AI converts printed chess diagrams into board positions (like chessvision.ai, but with no server). The user's rough spec is `multi_platform_project_plan_v2.md`.

**UX reference: Forward Chess** (forwardchess.com — the commercial benchmark for interactive chess books). Patterns to adopt:
- Tap any move in the text → board instantly snaps to that position (core interaction).
- **Variation sandbox:** from any book position the user can play their own moves on the board and get engine evals, then **one-touch "snap back to book"** — exploring never loses your place. The board panel shows whether it's on the book line or a user excursion.
- Easy-to-reach Prev/Next move buttons for stepping through the game without hunting in the text.
- Auto-resume: reopening a book returns to the exact spot, board state included.
- Bookmarks and inline notes; table-of-contents navigation.
- Later (post-MVP, Forward Chess parity+): "Guess the Move" training mode, play vs Stockfish from any book position (detailed in Phase 7 below).

Where this app deliberately beats Forward Chess: it reads the **user's own** PDFs/EPUBs (Forward Chess cannot import PDF/PGN — store-only DRM content), works fully offline, allows setting up arbitrary positions (their analysis board can't), and ships real desktop apps (they dropped theirs in favor of web).

**Confirmed decisions:**
- Framework: Flutter; all four platforms kept building from day one (CI matrix).
- MVP scope: core reader + clickable moves + board + Stockfish + diagram-to-FEN vision. Camera-based physical-board recognition and BLE smart boards are **deferred** (extension points only).
- GPL-3.0 stack accepted (Stockfish, lichess packages) — app distributable under GPL.
- User will supply real chess PDFs/EPUBs for testing; supplement with public-domain books and a self-generated controlled test PDF.

## Package decisions (verified on pub.dev, June 2026)

| Concern | Package | Why |
|---|---|---|
| Board UI | `chessground` (lichess) | All 5 platforms, maintained, themable interactive board. **Pieces render from lichess's professional piece-set artwork bundled with the package (Merida, Cburnett, Alpha, …) — real vector-quality graphics, never Unicode text glyphs.** |
| Chess logic | `dartchess` (lichess) | SAN/PGN/FEN parsing, legality, variations; supersedes old `chess.dart` |
| State | `flutter_riverpod` | Async streams from engine/isolates |
| PDF | `pdfrx` (PDFium) | All platforms incl. Windows; per-character text rects (for tap overlays) + page raster (for vision); avoids Syncfusion licensing |
| EPUB | `epubx` + `package:html` + `flutter_html` | EPUB = zip+XHTML; we keep DOM access to wrap moves in tappable spans |
| Stockfish mobile | `multistockfish` (lichess) | FFI, SF16 with embedded NNUE (offline by default); Android/iOS only |
| Stockfish desktop | Bundled official binaries + `Process.start` UCI | **No maintained cross-desktop FFI package exists** — process-based UCI over stdin/stdout is lowest risk; contingency: vendor sources + own FFI |
| Inference | `flutter_onnxruntime` | One runtime for all platforms (simpler than spec's TFLite+ONNX dual path); needs iOS 16+/macOS 14+ |
| Image ops | `image` (pure Dart) | Crop/resize/threshold for vision preprocessing; defer `opencv_dart` to camera phase — printed diagrams are axis-aligned, no warp needed |
| Misc | `file_picker`, `path_provider`, `archive`, `url_launcher` | File dialogs, engine binary storage, EPUB zip, opening positions in lichess/chess.com |

## Project structure

```
chess_reader/
  lib/
    core/
      models/                 # BookSource, MoveToken, DiagramAnchor, GameContext, EngineEval
      state/game_session.dart # central providers: current Position, move list, anchor FEN
    features/
      library/                # file picker, recent books
      reader/
        data/    book_adapter.dart, pdf_book_adapter.dart, epub_book_adapter.dart
        domain/  figurine_map.dart, san_tokenizer.dart, move_resolver.dart
        presentation/ reader_screen.dart, pdf_page_view.dart, epub_chapter_view.dart
      board/     board_panel.dart (chessground wrapper), board_controller.dart
      engine/
        domain/  uci_engine.dart (abstract), uci_parser.dart
        data/    ffi_engine.dart (mobile), process_engine.dart (desktop), engine_factory.dart
        state/   analysis_provider.dart
      vision/
        domain/  board_locator.dart, square_classifier.dart, fen_assembler.dart
        data/    vision_isolate.dart
        state/   diagram_provider.dart
  assets/models/board_classifier.onnx
  assets/engines/             # desktop stockfish binaries
  test/fixtures/              # SAN text samples, PGN corpora, diagram PNGs + golden FENs
  tool/                       # Python: ONNX export, synthetic diagram generation
```

CI: GitHub Actions matrix building windows/macos/apk/ios(--no-codesign) + `flutter test` on every push.

## Phases

### Phase 0 — Scaffold + walking skeleton (~3 days)
`flutter create chess_reader --platforms=windows,macos,android,ios`; pin packages; CI green. App shell: placeholder reader pane + chessground board playing legal moves via dartchess on all platforms.

### Phase 1 — Vertical slice: PDF → clickable move → board (~2 weeks)
- `pdf_book_adapter`: open PDF, render with pdfrx, extract per-page text + char rects (in isolate, cached per page).
- `san_tokenizer` v1 (regex) + naive resolution (single game from move 1).
- `pdf_page_view`: positioned tap targets over detected move tokens (union of char rects, zoom-scaled), subtle highlight.
- Tap move → `game_session` replays sequence → board animates; move list + prev/next stepping.
- **Piece rendering rule (applies everywhere):** the board uses chessground's bundled lichess piece sets; figurines appearing in app UI text (move list, engine PV lines, diagram-anchor chips) are rendered as inline piece images from the same piece set via `WidgetSpan` — Unicode chess characters are never displayed, only used internally for parsing. (Book pages themselves render as the original PDF raster/EPUB text, untouched.)
- **Deliverable:** open a real chess PDF, click "12.Nf5", board shows the position.

### Phase 2 — Stockfish on all platforms (~1.5 weeks)
- `UciEngine` interface; `process_engine.dart` (desktop: copy bundled official binary from assets to app-support dir, exec bit on macOS, codesign within .app bundle for notarization; Windows AVX2 build with sse41 fallback); `ffi_engine.dart` (multistockfish); factory by platform.
- `analysis_provider`: debounce 300 ms on position change → `stop`/`position fen`/`go`; parse `info` lines → eval bar + best line (PV rendered as SAN via dartchess); engine toggle on/off.
- **Variation sandbox (Forward Chess pattern):** `game_session` tracks a book line + an optional user excursion branch. Playing a move on the board from any book position enters sandbox mode (engine follows); a prominent "back to book" button snaps to the saved book position. Prev/Next buttons step the book line.
- **External analysis links:** board panel buttons "Open in Lichess" / "Open in Chess.com" launch the current position in the browser via `url_launcher` — Lichess: `https://lichess.org/analysis/standard/{FEN with spaces as underscores}`; Chess.com: `https://www.chess.com/analysis?fen={URL-encoded FEN}`. (Online features are optional conveniences; the app itself stays fully offline.)
- **Deliverable:** clicking a book move shows live eval on all four platforms; user can explore own moves, snap back, and open the position on lichess/chess.com.

### Phase 3 — Robust move detection (~2 weeks)
- `figurine_map.dart`: figurine Unicode → letters (♘→N …); per-font Private-Use-Area override tables built empirically from the user's test books (many chess PDF fonts lack ToUnicode tables).
- Full tokenizer grammar: moves, move numbers (`12.` / `12...`), NAGs, results, variation parens.
- `move_resolver.dart` contextual resolution: maintain `GameContext` seeded from the last **anchor** (diagram FEN, user-set position, or detected game start). Per token: try dartchess SAN parse against current position; on failure recovery ladder — opposite side to move → re-seed from nearest anchor using move-number hint → variation paren push/pop of a position stack → mark unresolved (non-clickable, never wrong) with a 2–3 token lookahead beam so one bad token doesn't poison the rest. Runs per page in an isolate; cached.
- Manual "set position here" FEN anchor (the seam vision plugs into).
- **Deliverable:** corpus tests pass; unresolved tokens degrade visibly, not incorrectly.

### Phase 4 — EPUB support (~1.5 weeks)
- `epub_book_adapter`: epubx spine/chapters; preprocess DOM with `package:html` — run the same tokenizer/resolver over text nodes, wrap resolved moves in custom elements; render via flutter_html `TagExtension` as tappable spans into the same `game_session`.
- EPUBs carry figurines as real Unicode, so detection is more reliable than PDF.
- **Deliverable:** the Phase 1 vertical slice works for EPUB.

### Phase 5 — Vision: diagram → FEN (~3 weeks)
Pipeline: page raster (~200 dpi, already produced by pdfrx; EPUB images straight from zip) → **board locator** (classical CV in pure Dart: grayscale, adaptive threshold, near-square contour regions, verify 8×8 periodicity via projection profiles; behind a `BoardLocator` interface so a detector model or camera stage can replace it) → crop into 64 cells → resize → batched `64×1×64×64` tensor → ONNX 13-class per-square classifier → FEN assembly (orientation/side-to-move from caption heuristics like "White to move"; castling rights inferred from home squares; flip/edit affordance).
- **Model:** first reuse open source — export `tsoj/Chess_diagram_to_FEN` (PyTorch, built for book diagrams) to ONNX via `tool/` script; fallback: train a small per-cell CNN (~100k params) on synthetic data (python-chess renders random FENs in many diagram fonts + scan-noise augmentation).
- Preprocessing in a long-lived Dart isolate; ONNX `session.run` async off the UI thread; results cached per page.
- UX: "scan diagrams on this page" → recognized diagram becomes a tappable `DiagramAnchor` chip that sets the board and re-anchors move resolution. Correction UI (mini board editor) as backstop + future training-data source.
- **Deliverable:** golden-FEN suite passes; diagram anchors resync move detection mid-book.

### Phase 6 — Polish + extension points (~1.5 weeks)
- **Reading comfort (Forward Chess parity):** auto-resume (last book, exact page/scroll + board state); bookmarks; inline user notes attached to text locations; table-of-contents panel (PDF outline via pdfrx / EPUB nav document); adaptive layout (side-by-side desktop/tablet, board-overlay phone).
- **Search:** full-text search across the book with a results list and jump-to-hit highlighting — PDF via the already-cached pdfrx per-page text (search runs in an isolate over the cache), EPUB via the preprocessed chapter DOM text. Search box accepts plain text and chess moves (figurine-normalized, so searching "Nf5" also finds "♘f5"). Post-MVP stretch: search by position (find pages whose resolved positions match the current board).
- Settings: engine depth/threads, board theme/piece set, text size.
- Define `PositionSource` abstract interface (stream of FEN + confidence) for future camera and BLE smart-board pipelines — interface only, no implementation.

### Phase 7 — Play vs Computer (Pro feature, post-MVP)

**Goal:** from any position — book anchor, sandbox excursion, diagram, or a fresh start — the user plays a full game against Stockfish at an adjustable, human-like strength, on-screen and (if a Chessnut Move is connected) on the physical board via LED move prompts. Gated behind `proEntitlementProvider` (`lib/core/entitlements/pro_entitlement.dart`) alongside Chessnut Move, as already flagged in that file's doc comment and in `chessnut_settings_section.dart`.

- **New feature module, reusing engine + game_session rather than forking them:** `features/computer_opponent/state/computer_opponent_provider.dart` — `ComputerOpponentNotifier extends Notifier<ComputerOpponentState>` (`enabled`, `humanSide`, `strength`, `thinking`, `error`). It owns its own `UciEngine` via the existing `engine_factory.dart`, separate from `analysisProvider`'s instance, so opponent-move search and any live eval bar never contend for one process's UCI serialization. `ref.listen(gameSessionProvider, ...)`: whenever the position is legal, a game is active, and it's not the human's turn, send `position fen` + `go` on the dedicated engine and apply the resulting `bestmove` through `GameSession.playMove` — the same call path a tapped book move or a physical Chessnut move already uses, so move list, undo, and board highlighting need no new branching.
- **Mobile FFI caveat:** `multistockfish` (`data/ffi_engine.dart`) may only support one live instance; spike a two-engine round-trip on Android/iOS before committing to "analysis engine + opponent engine" running concurrently — fallback is auto-pausing `analysisProvider` for the duration of a game.
- **Human-like strength, not depth-capping:** a shallow full-strength search still finds sharp tactics and doesn't feel human. Use `setoption name UCI_LimitStrength value true` + `setoption name UCI_Elo value N` (official range ~1320–3190); verify both the desktop bundled binaries and `multistockfish`'s embedded build honor these options on all four platforms. Expose presets (Beginner/Club/Advanced/Full Strength → e.g. 1350/1650/2000/uncapped) plus a raw Elo slider, persisted in `AppSettings` next to `engineDepth`/`engineThreads`. Full Strength disables `UCI_LimitStrength` and reuses the existing depth/movetime budget.
- **Starting a game:** a "Play vs computer" action on the board panel (next to the external-links row), Pro-gated like Chessnut Move. Setup sheet: color (White/Black/Random), strength, and starting point — "from here" (current `gameSession` position, only when `state.legal`) or "new game" (`Chess.initial`).
- **While a game is active:** book move-tapping and diagram anchors are disabled (they'd desync the game); the sandbox's "back to book"/reset actions become "resign"/"end game" instead. Game end uses `dartchess`'s position outcome (checkmate/stalemate/insufficient material/repetition/50-move) for a result banner, with rematch or return-to-book. The live eval bar is off by default during play (a real game, not an assisted one) — an explicit "show eval" toggle in the setup sheet re-enables `analysisProvider`.
- **Physical board tie-in:** human moves already flow from Chessnut into `gameSession.playMove(origin: PositionOrigin.physical)` unchanged. For the engine's move — no robotic arm — light its from/to squares via `chessnut_codec.dart`'s existing `encodeSquareLedsCommand` (already used for mismatch highlighting) with `ledGreen`, clearing once the physical board reports the matching move. Genuine differentiator over Forward Chess, which has no physical-board support at all.
- **Deliverable:** start a game from any position, play it to completion against Stockfish at a chosen human-like strength, on-screen and (if connected) via Chessnut LED prompts; Pro-gated end to end.
- **Risks:** mobile single-FFI-instance limits (resolve via the spike above); `UCI_LimitStrength`/`UCI_Elo` behavior varies by Stockfish build — verify on the actual bundled/embedded binaries, not upstream docs; a game must leave `gameSession`/`computer_opponent_provider` consistent if the app backgrounds or the book closes mid-game (reuse the engine-stop-on-quit path already in `AnalysisNotifier.stopEngine()`).
- **Verification:** `uci_parser.dart` unit tests for full `bestmove` lines including promotions (`bestmove e7e8q`); widget test that `playerSide` stays locked to the human's side until the engine replies; per-platform smoke test playing a full game to checkmate at the lowest strength preset; Chessnut smoke test that the correct two squares light up and clear on match.

### Post-MVP backlog (not planned in detail)
"Guess the Move" training mode with accuracy tracking; spaced-repetition position trainer; camera physical-board sync.

## Key risks & mitigations
1. **Desktop Stockfish** — no maintained package → process-based UCI (decided); vendored-FFI contingency.
2. **Figurine fonts without ToUnicode** → PUA mapping tables; degrade to non-clickable; diagram anchors limit damage.
3. **Multi-game/variation ambiguity** → anchors + move-number resync + lookahead beam + explicit unresolved state; corpus metric tracked in CI.
4. **Vision accuracy across diagram styles** → synthetic multi-font training, golden-FEN regression set, correction UI.
5. **Large books freezing UI** → all heavy work in isolates, lazy per-visible-page, per-page caches keyed by book hash.
6. **flutter_onnxruntime minimums** → set iOS 16 / macOS 14 deployment targets.
7. **flutter_html CSS limits for EPUB** → chess books are typographically simple; webview is documented plan-B.

## Verification
- **Corpus:** `secrets-of-positional-chess.pdf` (already in the project folder — Gambit Publications, figurine notation + diagrams: the primary real-world test book) + any further user-provided PDFs/EPUBs + Project Gutenberg (Capablanca *Chess Fundamentals*, Lasker *Chess Strategy*) + a self-generated LaTeX (`xskak`) PDF with known moves/diagram FENs for deterministic golden tests. First task in Phase 1: dump this book's extracted text/codepoints with pdfrx to build its figurine mapping table.
- Phase 0: CI matrix green; widget test (board renders, legal move plays).
- Phase 1: tokenizer unit tests; integration test on the controlled PDF (detected-move count, tap → expected FEN).
- Phase 2: per-platform `go depth 10` → `bestmove` within timeout; `info`-line parser unit tests.
- Phase 3: resolver tests by round-tripping PGNs with variations rendered to text; % moves resolved per corpus book tracked in CI.
- Phase 4: same corpus through the EPUB DOM path; golden widget test for tappable spans.
- Phase 5: 100–200 diagram crops with golden FENs; per-square accuracy ≥99% synthetic + recorded baseline on real scans.
- Phase 6: manual cross-platform smoke checklist; search unit tests (plain text + figurine-normalized move queries against fixture text); link-builder unit tests (FEN → correct lichess/chess.com URLs, including encoding).
