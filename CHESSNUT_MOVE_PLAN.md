# Chessnut Move: two-way board integration

Status: implementation complete on `feat/chessnut-move` (codec, controller, transport,
fake board, UI, platform config, tests) as of 2026-09-08. Automatic movement remains
gated off (`motionProtocolVerified = false`) pending hardware validation; a first
real-hardware session on the user's Mac has started this — see the *Milestone 1
hardware validation log* below for confirmed findings and remaining open items.

## Summary

Implement on a new `feat/chessnut-move` branch, preserving existing unrelated changes.

Support **Android, iOS/iPadOS, macOS, and Windows**, with initial hardware validation on the user's Mac. While synchronization is active:

- Book diagrams, selected moves, and virtual-board actions move the physical pieces.
- Physical moves update the virtual board and engine as exploration, preserving the book anchor.
- Rapid navigation keeps only the latest pending position.
- Automatically reconnect to the remembered board, but require **Resume** before synchronization restarts.
- Allow an explicit override for imperfect diagrams that the hardware can represent.

## Architecture and protocol validation

The existing [GameSession](chess_reader/lib/core/state/game_session.dart) already centralizes position changes. Integrate there through a separate synchronization controller, keeping Bluetooth out of reader widgets.

Use `universal_ble`, pinned through the application lockfile, behind a mockable `ChessnutTransport` interface. It supports the four requested platforms. Keep Bluetooth optional for app installation. [Plugin documentation](https://pub.dev/packages/universal_ble)

**First milestone: establish the hardware contract.** The Chessnut repository provides BLE documentation and a decoding example, not an SDK. Implement an independent Dart codec for its square ordering, piece encoding, position commands, and notifications. Use non-force movement mode so manual interaction can interrupt motion. [Chessnut API](https://github.com/chessnutech/chess_move_api)

Before automatic synchronization, validate on the user's board:

- Complete command writes, including the 35-byte target payload; do not invent packet fragmentation.
- Notification framing and behavior after movement: verify how the board signals move completion (does `1b7e8273` emit a completion opcode, do FEN notifications resume automatically on `1b7e8262`, or must `[0x21, 0x01, 0x00]` be resent to re-enable FEN reports?).
- Reliable completion detection and manual interruption handling: capture packets emitted on `1b7e8273` when a user physically halts a moving piece in non-force mode (`forceFlag: 1`).
- In-flight retargeting vs. Stop command: test whether sending a new target (`0x42, 0x21`) or Stop mid-motion immediately redirects or halts in-flight pieces, avoiding sluggish waits during rapid book navigation.
- Stop-command encoding: the documented byte count contradicts its example.
- Moving between unrelated positions, including restoring captured pieces and available promotion pieces.
- The physical piece inventory: how many of each type and color the board can place, and how captured pieces and promotion spares are held (see *Piece inventory* below). Capture present, removed, powered-off, and returned pieces to establish whether status reports reliably identify availability; the published coordinate table has no explicit presence flag.
- Battery and piece status queries: verify responses to `[0x41, 0x01, 0x0C]` (board battery/charging) and `[0x41, 0x01, 0x0B]` (34-piece normalized coordinates and per-piece battery percentage).
- LED control: verify square LED command `[0x43, 0x20, ...ledData...]` (Red, Green, Blue nibbles per square).

Record firmware information and captured protocol fixtures. Where the documentation and the hardware disagree, the hardware wins and the discrepancy is recorded alongside the fixture. Do not treat a successful Bluetooth write as completed movement. If completion, stopping, required transport capacity, or required-piece availability cannot be established, finish the codec, connection UI, and tests, but keep automatic movement disabled pending resolution.

#### Milestone 1 hardware validation log (2026-09-08, macOS, user's Chessnut Move board)

First real-hardware session against the debug macOS build (ad-hoc signed). Findings below are from live BLE captures, not documentation; `motionProtocolVerified` remains hardcoded `false` in `UniversalBleTransport` — none of this unblocks automatic movement yet, it only narrows what's still unknown.

- **MTU:** negotiates to **185** on macOS (via CoreBluetooth `maximumWriteValueLength(for: .withoutResponse) + 3`), well above the 142-byte piece-status floor. Found a real bug getting here: the app originally queried MTU immediately after `connect()`, before GATT service discovery, and CoreBluetooth was still reporting the pre-negotiation default at that point — surfacing a false "Bluetooth capacity is insufficient for complete board reports" error even though the real negotiated value was fine. Fixed in `chessnut_controller.dart` by moving the MTU query to after `validateRequiredServices` (which runs `discoverServices`), with one 500ms-delayed retry if still below the piece-status floor. Not yet verified on iOS, Android, or Windows.
- **Command write acknowledgment:** every write to the command characteristic (`1b7e8272`) — enable-FEN-reporting, battery query, piece-status query, and the 35-byte target command alike — gets an immediate 3-byte `23 01 00` reply on `1b7e8273`. This is a generic "command received" ack, correlated 1:1 with writes sent, **not** a movement-completion signal. Confirmed by counting: every write produced exactly one `23 01 00`, including non-motion queries.
- **No distinct movement-completion opcode observed.** After sending a target command and physically watching the move happen, the *only* channel-1b7e8273 traffic was the generic write-ack above. The board does not appear to emit any separate "motion complete" notification. FEN reporting (`1b7e8262`) was never paused or interrupted by the move and needed no re-enable — it streamed continuously throughout, at what looks like a fast fixed cadence (tens of packets per second), always reflecting the live sensor state.
- **Working conclusion for completion detection:** since there's no explicit completion event, completion must be inferred the same way incoming physical moves are already recognized elsewhere in this plan — watch the streamed FEN placement until it matches the commanded target and stays stable (reuse the existing 350ms-attempt / ~1.5–2s-grace stability approach), rather than trusting the write ack or a fixed delay.
- **Target command format confirmed correct as encoded:** `42 21` + 32-byte board data + 1 force-flag byte (35 bytes total, `force: false` → last byte `0x01`) reliably moved the intended piece (tested: a knight toggled between b1 and a3 by directly swapping placement characters, independent of chess legality, to allow repeat testing without app-state involvement).
- **Piece-status query (`41 01 0b`) returns real, populated per-piece data** — varied, plausible x/y coordinates and ~100% battery levels across all 34 nominal pieces, not placeholder zeros. Presence/absence semantics (does an actually-missing piece report a sentinel, or just a stale/wrong coordinate?) were **not** tested — no piece was physically removed during this session.
- **Manual interruption: inconclusive.** A single-square knight hop (b1↔a3) completed too fast to grab mid-travel — by the time the piece could be held, the FEN report already showed it settled at the destination and stayed stable there for the whole hold, then reverted cleanly to the start position once manually placed back. A longer multi-square slide (e.g. a rook or queen run) is needed to get a real window for interruption/mid-motion testing.
- **Stop command (`0x42, 0x21` + 33 zero bytes): not yet tested.** No attempt was made to send it during an in-flight move this session.
- **Firmware version: not queried.** No existing command in the codec covers this; out of scope for this session.
- **LED command (`0x43, 0x20`): not exercised on real hardware this session** (mismatch-LED and clear-LED paths remain implemented but hardware-unverified).

Open items before `motionProtocolVerified` can honestly flip to `true`: ~~implement FEN-stability-based completion detection (per the working conclusion above) instead of trusting the write ack~~ (done, see below); test Stop mid-motion; test manual interruption with a longer move; verify piece-presence/absence semantics with a piece physically removed; repeat MTU/service verification on iOS, Android, and Windows.

**FEN-stability-based completion detection implemented (2026-09-08).** `ChessnutController._handleIncomingFenReport` no longer treats the first FEN packet matching the in-flight target as completion. It now starts a `_completionTimer` (reusing the existing 350ms `stabilityDuration`) when the reported placement first matches the target, and only calls the new `_completeMotion()` helper — transitioning to `synchronized` and sending any newer pending target — once that placement has stayed latest and stable for the full window. The timer is cancelled (not fired) if a different placement arrives first, mirroring the physical-move stability timer. The existing 30s `_motionTimer` remains the fallback if the placement never stabilizes. Updated `chessnut_controller_test.dart`, `chessnut_regression_test.dart`, and `chessnut_widgets_test.dart` throughout to settle past this window (via `tester.pump()` in widget tests, real `Future.delayed` in plain tests) wherever a test's premise depended on the board having already reached the target before the next simulated event — this was necessary in several tests where an outgoing target and a subsequent simulated physical event were previously fired back-to-back with no time passing between them. `flutter analyze` and the full test suite pass (one unrelated pre-existing failure: `engine_test.dart` needs a local Stockfish binary asset not present in this environment).

### Platform configuration

Concrete, because all of it is currently absent:

- **macOS:** add `com.apple.security.device.bluetooth` to *both* `macos/Runner/Release.entitlements` and `macos/Runner/DebugProfile.entitlements` (Release currently carries only app-sandbox and user-selected file access). Add `NSBluetoothAlwaysUsageDescription` to `macos/Runner/Info.plist` — macOS 11+ requires it for CoreBluetooth under the sandbox.
- **iOS/iPadOS:** add `NSBluetoothAlwaysUsageDescription` to `ios/Runner/Info.plist`.
- **Android:** declare `BLUETOOTH_SCAN` with `android:usesPermissionFlags="neverForLocation"` and `BLUETOOTH_CONNECT`, plus legacy `BLUETOOTH` / `BLUETOOTH_ADMIN` and `ACCESS_FINE_LOCATION` with `android:maxSdkVersion="30"`. Using the existing `permission_handler` dependency, request SCAN/CONNECT at runtime on API 31+, and location at runtime on supported API 23–30 devices before scanning. `neverForLocation` removes the location requirement only on the newer permission path; verify discovery with this flag on hardware. Declare BLE with `android:required="false"` to preserve installation without Bluetooth. [Android permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
- **ATT MTU and transport capacity:** On Android, request `UniversalBle.requestMtu(deviceId, 247)` after connection and before protocol traffic, then inspect the returned value; the request is best-effort. For single ordinary ATT writes/notifications, 35-byte target commands need MTU ≥38, 38-byte FEN reports need ≥41, and 139-byte piece-status reports need ≥142. On Apple and Windows, MTU is OS-managed; query available capacity and verify complete transfers. Record actual capacity and framing per connection, including after reconnect. Handle a smaller result, timeout, or failure explicitly: keep movement disabled unless the required complete transfers are supported by a hardware-verified mechanism. Do not invent packet fragmentation. [Plugin MTU API](https://pub.dev/documentation/universal_ble/latest/universal_ble/UniversalBle/requestMtu.html)
- **BLE discovery filtering:** During hardware validation, scan without service UUID filters and record actual names and advertised services. A `Chessnut` name prefix is a discovery hint, not proof of a Move board or a mandatory exclusion rule for unnamed devices. Validate required services and characteristic properties after connection before enabling commands. Advertising-size limitations are a hypothesis to check against captures, not evidence that this board omits its service UUIDs. Include already-connected system devices where the plugin supports discovery of them.
- **Bluetooth availability state:** Use the pinned plugin's documented `UniversalBle.onAvailabilityChange` callback or `availabilityStream`. If Bluetooth is powered off or unauthorized at the OS level, retain the Chessnut section and display recovery instructions instead of silently failing to scan.
- **Release verification:** verify Bluetooth entitlements in the signed macOS release archive and exercise Bluetooth in that build. Do not assume adding this sandbox entitlement requires App ID changes or provisioning-profile regeneration; change signing configuration only if archive validation establishes a requirement.
- Hide the Chessnut section only on platforms or devices confirmed to lack BLE support. Powered-off, permission-denied, and transient availability errors retain visible status and recovery controls.

### Development and test harness

Alongside the mockable transport, build a `FakeChessnutBoard` that replays the captured protocol fixtures and accepts position commands. It lets the whole board-to-app recognition path — settling, castling intermediates, mismatch grace, interruption — run in CI and on the Mac with the hardware powered off, and it separates "the BLE stack works on this platform" from "the logic works" during four-platform acceptance. This is what keeps the acceptance matrix from requiring real hardware everywhere.

## Implementation and behavior

### Prerequisite fixes in existing code

Two existing behaviours must change before a second input source is attached to the session:

- **`GameSession.reset()` is overloaded.** It is called both by the Reset button ([board_panel.dart:123](chess_reader/lib/features/board/board_panel.dart)) and by book open/close (`_resetReadingState` in [book_providers.dart:41](chess_reader/lib/features/reader/state/book_providers.dart)). These must behave oppositely: user Reset moves the pieces to the start position; opening or closing a book pauses instead. Origin tagging alone cannot separate them because it is the same method — split it into `reset({required PositionOrigin origin})` or a distinct `resetForBookChange()`.
- **`GameSession.playMove` does not guard on `legal`.** It checks only `pos.isLegal(move)`; on a display-only board `position` is `Chess.initial` while `displayFen` shows something else, so a "legal" move is played against the *initial* position. Today this is unreachable only because `board_panel` sets `playerSide: none`. Physical move recognition bypasses the widget, so the guard belongs in `playMove` itself (`if (!state.legal) return;`). This is also what enforces the imperfect-diagram rule below.

### Connection and controls

- Add a Chessnut Move section in Settings for discovery, connection, remembered device, automatic reconnection, and Forget.
- Add a compact board-panel status/control showing connection, synchronization, movement, and errors, with Start/Resume, Pause, Stop, and Disconnect.
- Connect initially in a paused state. Start/Resume sends the current app position; it never silently imports a different physical setup.
- Reconnect only to the remembered device while the app is foregrounded, using bounded exponential backoff. Explicit Disconnect cancels reconnection until the next Connect; Forget removes the saved device. If reconnection fails repeatedly (e.g. CoreBluetooth UUID cycling on macOS/iOS after reset), provide a quick "Scan again" action directly in the board-panel status indicator.
- Backgrounding pauses synchronization and clears pending motion. Request a verified stop when possible; foreground return requires Resume. Do not claim the board stopped if communication was lost.
- **Battery health monitoring:** Query board battery (`0x41, 0x01, 0x0C`) and individual piece battery levels (`0x41, 0x01, 0x0B`) on connect and periodically when idle. Every motorized piece relies on its internal battery; warn in the UI if the board or any piece drops below 15% to prevent mysterious stalls during auto-moves.

### State and interfaces

- Introduce a pure `ChessnutCodec`, the transport adapter, and an app-scoped Riverpod `ChessnutController`.
- Track connection separately from synchronization: paused, aligning, synchronized, moving, mismatch, and error.
- Add position-change origin and revision information to `GameSessionState`. Origins distinguish app changes, physical moves, and lifecycle resets.
- Track turn provenance separately from position-change origin: only a newly imported diagram with inferred/unknown turn is eligible for one-time turn recovery. Explicit FEN input, resolved book moves, Reset, and established play have a known turn. Clear recovery eligibility when the user confirms the turn or the first move is accepted; do not re-enable it merely because a later move fails to match.
- Physical moves use the existing legal-move/undo path without echoing commands back to the board. Ignore stale asynchronous results from older connections or position revisions.
- Expose a read-only previous-position snapshot for takeback matching rather than accessing the private `_undoStack` from the controller. Physical Undo must carry a physical origin and restore the exact saved position metadata.
- **Collision rule.** An app-origin position change bumps the revision, discards any in-flight physical-move settling buffer, and invalidates recognition results carrying an older revision. This covers the case where the user clicks a book move while a physical move is still settling; the app-origin change wins.
- Store only device identity and reconnection preference — two fields on the existing `AppSettings` ([lib/core/settings/app_settings.dart](chess_reader/lib/core/settings/app_settings.dart)), which is already an immutable class with `copyWith` and SharedPreferences persistence. Never persist active synchronization or queued commands.

### App to board

- Observe accepted positions centrally, covering PDF/EPUB diagrams, book navigation, pasted FEN, exploration, Undo, Reset, and Back to book.
- Update the virtual board immediately. Allow one physical target in flight and retain only the newest pending target.
- Send that pending target after verified completion. If Milestone 1 validates that the board accepts mid-motion retargeting or Stop+retarget, abort the in-flight move immediately upon rapid navigation rather than forcing the board to physically finish stale intermediate positions.
- **Deduplicate on the placement field of the FEN only** (field 1), not the full FEN: the hardware cannot represent turn, castling rights, en passant, or move counters, so an Undo that returns to the same placement, or a side-to-move correction, must cause zero physical motion.
- **Target inventory verification:** Before every target command, validate the required count of every piece type and color against hardware limits and currently verified availability. This covers ordinary moves, direct jumps to already-promoted diagrams, underpromotions, restored captures, and diagram overrides. Use the piece-status table only after milestone 1 establishes its presence/availability semantics. If a required piece is absent or availability is unknown, pause with a specific explanation and recheck after the user supplies it; coordinates alone are not proof of presence.
- On interruption, timeout, or uncertain completion, clear the pending target and pause for explicit resynchronization.
- Opening or closing a book pauses synchronization rather than moving pieces because of the reader's internal reset. The user-pressed Reset button does move the pieces (see the `reset()` split above).
- Screen orientation never changes physical square coordinates. Nor does the user's seating side: Chessnut squares are absolute, so a user sitting behind Black needs no setting — the pieces move correctly, only the user's view is inverted.

### Board to app

- Process physical moves only while synchronized and idle.
- Match a stable reported placement against positions reachable by one legal move from the current app position. Preserve turn, castling rights, en passant, and counters through the chess engine.
- **Restricted side-to-move recovery:** `tryLoadFen` ([board_loader.dart](chess_reader/lib/core/state/board_loader.dart)) retries the opposite turn only when validating the original turn fails; a quiet diagram with an inferred wrong turn can remain legal. For a newly imported diagram explicitly marked turn-uncertain, and only after legal-move and takeback matching fail, look for exactly one legal move from a validated opposite-turn setup. Offer a one-time confirmation to correct the diagram's turn and accept that move; do not adopt it automatically. Bind the proposal to the connection, position revision, and reported placement, and discard it if any changes before confirmation. Apply the corrected pre-move position, book anchor, and resulting physical move atomically through a session method so Undo restores the corrected diagram and no movement command is echoed. Never flip turns during established play: White playing `Nf3` then `Nc3` without a Black reply must be rejected.
- **Two timers, not one.** Use a configurable 350 ms stability interval to *attempt* a match, and stay silent when it fails. Only after a longer grace period (~1.5–2 s) of continued stable, unmatched placement does the mismatch UI appear. A single short timer flashes spurious mismatches mid-move: king-first castling parks the king on g1 with the rook still on h1, a placement reachable by no legal move, and a capture lifts the captured piece first. Distinguish "transient unknown" (silent) from "settled mismatch" (visible).
- **Intermediate castling & en passant recognition:** Explicitly recognize the 4 canonical intermediate castling placements (White O-O / O-O-O, Black O-O / O-O-O: King moved to destination square with rook unmoved) and intermediate en passant states. When detected, hold the mismatch grace timer or display a subtle hint ("Complete castling: move rook to f1") rather than timing out into a mismatch dialog after 1.5–2 s.
- **Physical takebacks (Seamless Undo):** Before considering turn recovery, match a stable placement against the exposed previous-position snapshot. Restore that saved position through `GameSession.undo()` with a physical origin, preserving turn, castling rights, en passant, counters, and the book anchor. For example, returning the knight from f3 to g1 immediately after `Nf3` must undo the move, not flip the turn and record another White move.
- Accept exactly one matching move; ignore duplicate reports and transient piece lifts.
- Handle captures, en passant, promotions, and king-first castling. Arbitrary physical rearrangements require app controls/resynchronization.
- **Mismatch handling and LED assistance:** Unmatched placements do not overwrite the app. Show a mismatch with actions to restore the pieces or send the app position. Simultaneously illuminate the mismatched squares in **Red** via `[0x43, 0x20]` on the physical board so the user can immediately identify misplaced pieces without scrutinizing the screen.
- Physical play remains exploration and does not advance book selection. Follow book is deferred (see below).
- Physical moves restart the engine search exactly as board taps do ([analysis_provider.dart:95](chess_reader/lib/features/engine/state/analysis_provider.dart)). This is accepted, not overlooked; revisit only if rapid physical play proves to thrash the engine.

### Imperfect diagrams

- Automatically send only validated positions within verified hardware inventory limits.
- For an invalid diagram, pause and offer **Send diagram anyway**, explicitly identifying it as an unvalidated placement.
- The override still requires valid encoding and available piece types/counts.
- After sending an invalid placement, keep legal-move input disabled until a valid app position is synchronized — enforced by the `playMove` guard above, not only by the widget. Never borrow the previous position's turn/history.

### Piece inventory

- Establish a maximum count table per piece type and color during milestone 1 from the hardware itself, and keep it as a constant with its own test. Track current verified availability separately; the nominal 34-piece inventory does not prove all pieces are present or usable.
- **Refuse, never substitute.** A position exceeding the verified inventory (for example, three queens of one color or too many knights) pauses with an explanation instead of approximating with an upside-down rook or a wrong piece. Apply this to every target, including composed studies and the "Send diagram anyway" override.

### Deferred enhancements

- **Follow book with board:** reconsider after basic synchronization and recovery pass hardware acceptance. Do not implement it by calling the current `activeLine.next()`: `_applyToBoard()` in [book_providers.dart](chess_reader/lib/features/reader/state/book_providers.dart) calls `GameSession.setPosition()`, which clears undo history and replaces the book anchor. A future design must define how book selection, anchors, physical origin, and takebacks advance together, use a dedicated session/navigation operation, and test those semantics before adding the preference.
- **Decorative move LEDs:** defer Green/Blue from/to flashes until core movement and recovery are reliable. Diagnostic red mismatch LEDs remain in scope after protocol verification; LED writes or failures must not delay Stop or block on-screen mismatch recovery.

## Tests and acceptance

- **Codec:** independently derived square/piece fixtures, complete command bytes, malformed notifications, invalid piece codes, inventory limits, battery query/response parsing (`0x41, 0x01, 0x0C` board battery and `0x41, 0x01, 0x0B` 34-piece battery/coordinates), LED command encoding (`0x43, 0x20`), and hardware captures.
- **Synchronization:** latest-target handling, in-flight retargeting/cancellation upon rapid navigation, placement-field deduplication, every-target inventory validation (including direct jumps to promoted positions, underpromotion, restored captures, absent pieces, and unknown availability), no feedback loops, stale callbacks, revision collisions between the two directions, interruption, timeout, disconnect/reconnect, backgrounding, and explicit Resume.
- **Move recognition:** ordinary moves, captures, castling (including the king-on-g1 intermediate pausing the mismatch timer), physical takebacks restoring exact saved metadata, en passant intermediates, promotion, lifts, rearrangements, mismatch grace period, and preservation of book anchors and undo history. Test that `Nf3` followed by `Nc3` without a Black reply is rejected, while returning f3 to g1 invokes Undo. Test one-time recovery only for turn-uncertain imported diagrams, explicit confirmation, stale confirmation rejection, corrected-anchor/Undo behavior, and no automatic book advancement.
- **Session:** user Reset moves the pieces while book open/close does not; `playMove` rejects moves on a display-only board.
- **Transport and platform:** actual negotiated MTU sufficient/insufficient, negotiation timeout/failure, complete command writes and notifications, revalidation after reconnect, API 23–30 runtime location and API 31+ SCAN/CONNECT permission paths, observed advertising/name variants, already-connected device discovery, and rejection of devices lacking required services/characteristics.
- **UI:** permissions denied, powered-off and transient availability recovery, section hidden only for confirmed unsupported BLE, discovery failure, connection status, board/piece low-battery warnings, inventory-unavailable explanation, turn-recovery confirmation, mismatch recovery with red LED indicators (including LED failure), and diagram override.
- Run `flutter analyze`, the Flutter test suite, and platform builds. Validate actual Bluetooth and movement on each requested platform before declaring that platform supported; emulator or build success alone is insufficient. `FakeChessnutBoard` covers the logic everywhere, so per-platform hardware validation is scoped to the BLE stack and real movement.
- On the user's Mac, exercise real PDF/EPUB selections, rapid navigation, exploration, Undo/Back to book, interrupted motion, reconnection, and unrelated diagram positions.

## Delivery defaults

Implement in reviewable stages: **prerequisite session fixes → protocol and Mac hardware validation → connection controls → outgoing synchronization → physical move recognition → four-platform acceptance**.

One Chessnut Move board at a time; foreground operation; no cloud service, background play, arbitrary physical-position import, or automatic book advancement. Keep work on the feature branch until reviewed and hardware acceptance is complete.
