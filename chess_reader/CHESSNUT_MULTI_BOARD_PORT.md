# Chessnut multi-board port

Ported from Chessformator's Chessnut implementation into Chess Reader's existing
Riverpod controller and transport interface.

- Scan results include Chessnut advertisements identified by name, raw name, or
  position-service UUID. Model detection recognizes Move, Evo, Air and Go.
- Move retains the existing motor, inventory and completion checks.
- Air, Evo and Go use physical move recognition and LED-guided manual placement.
  They receive no motor targets, stop commands or motor-piece inventory queries.
- Go uses the source app's row-bitmap LED command; Air/Evo use its nibble LED command.
- On Evo's Android device, the transport detects the installed Chessnut service
  and exposes it as a discoverable board without Bluetooth permission requests.
  Other devices use BLE. Android includes the source AIDL definitions and bridge.
- Remembered device names persist with identifiers so reconnect preserves model
  detection. Existing saved Move identifiers remain compatible.
- Access remains under the existing Pro gate. Bluetooth initialization/reconnect
  remains deferred until the user opens the feature.

## Use

Open Chessnut from the reader toolbar, scan and connect to the detected board.
A matching placement synchronizes automatically. Otherwise press Start/Resume:
Move aligns automatically; on Air/Evo/Go, move pieces to match the lit squares.
Subsequent physical legal moves update the reader; app moves guide the board.

## Validation

The focused Chessnut/controller/codec/widgets/prerequisites and computer-opponent
suite passed 75 tests. Added coverage includes native Evo discovery/FEN/LEDs,
BLE fallback, model recognition, manual alignment, physical and app-origin moves,
no motor commands on manual boards, and remembered model identity.
Targeted Dart analysis passed. The Android debug APK built successfully, including
the Evo Kotlin bridge and generated AIDL interfaces.

Physical acceptance remains required for Air/Evo/Go BLE behavior and the Evo
service on a real Evo. Evo LED orientation inherits the source app's unverified
mapping. Automated fake-transport tests do not establish hardware support.
