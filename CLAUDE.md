# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

yolo-meet is a native macOS app (Swift 6.2, Core AI, Metal, RealityKit, SpriteKit). It runs Ultralytics YOLO (and
RF-DETR, MediaPipe, Apple Vision) models on the camera and draws effects into a **Stage** window that is shared in
Google Meet. A private **panel** window controls it. It needs macOS 27+ on Apple silicon and Xcode 27. `README.md`
covers the user-facing features in detail.

## Commands

`swift build`, `swift test` and `xcodebuild` need `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
first: the Command Line Tools lack the SwiftUI macro plugin. `scripts/build.sh` sets it itself.

```bash
./scripts/build.sh                       # build/yolo-meet.app (release, ad-hoc signed, story assets and fonts copied in)
./scripts/build.sh --dmg                 # + build/yolo-meet.dmg
swift test                               # all tests (swift-testing, @Test)
swift test --filter PenLinkTests         # one suite; --filter also takes a test name, e.g. sessionsSeal
YOLO_MEET_MODELS=/path/to/aimodels YOLO_MEET_IMAGE=/path/to/bus.jpg swift test   # + real-model tests
xcodebuild -project iPad/YoloMeetPen.xcodeproj -scheme YoloMeetPen -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
swift format -i -r --parallel Sources iPad Tests   # format (config: .swift-format, 4 spaces, 120 columns)
swift format lint -r Sources iPad Tests            # lint; kept at zero warnings
```

- **Formatting is automatic:** a PostToolUse hook (`.claude/hooks/swift-format.sh`) formats every `.swift` file
  Claude edits, then lints it and reports any warnings to fix by hand. Expect the file to change after an edit.

- **Model tests** are skipped unless `YOLO_MEET_MODELS` (unzipped `yolo26n*.aimodel` folders) and `YOLO_MEET_IMAGE`
  (Ultralytics' `bus.jpg`) are set. MediaPipe tests need `YOLO_MEET_MEDIAPIPE` (see README).
- **Pen-link network tests** use Bonjour. If the user's own yolo-meet is running with iPad pen on, a test pad or a
  second app copy can connect to their real iPad: run with `YOLO_MEET_NO_NETWORK=1` (or `--filter` around
  `padReachesHost`). Don't launch a second copy of the app while theirs runs.
- **The iPad pen app** (`iPad/`) can only be compile-checked here unless an iOS simulator runtime is installed
  (`xcrun simctl list runtimes`).
- **Stories render offscreen** with `.claude/skills/story-scenes/scripts/render_story.sh` (see the `story-scenes`
  skill): steps to PNGs, with no camera, models or window.

## Architecture

Swift package (`Package.swift`), main-actor isolation by default (`.defaultIsolation(MainActor.self)`):

- **`YoloMeetCore`**: models and their decoding, UI-free and tested. `YOLOModel` / `Predictor` run Core AI models
  (YOLO and RF-DETR families, all 7 YOLO tasks), `Decoders` turn outputs into `Results`, `Tracker` assigns track IDs,
  `Landmarker` runs MediaPipe's two-stage pipeline in Swift, `VisionLandmarker` wraps Apple Vision, `ModelStore` and
  `CustomModels` manage downloaded and imported models, and `PTConverter` drives the bundled
  `scripts/export_models.py --convert` for PyTorch weights.
- **`PenLink`**: the encrypted link between the Mac and the iPad pen app (TLS-PSK from a pairing code, then
  per-session X25519 + ChaChaPoly in `PenSession`). It's a library product so `iPad/YoloMeetPen.xcodeproj` builds it
  too: changing the messages changes both apps.
- **`YoloMeet`** (the app):
  - `App/`: `AppModel` (state, the current scene, `applyScene`), the panel UI, keys, the clicker, pen input.
  - `Pipeline/`: `Camera` / `MediaPlayer` → `Pipeline`. Vision person segmentation replaces the background. Each
    active model runs at its own rate on the newest frame. Detections are carried forward to the shown frame, so the
    video has no added delay.
  - `Render/`: `StageView` (`StageRenderer`) draws each frame into one Metal drawable at 60 fps. Core Image draws the
    video, RealityKit (`RealityLayer`) draws 3D and `ParticleSystem` (`Particles.swift`, GPU) draws particles, then
    SpriteKit draws 2D. `Effect` / `StageFrame` (`Effect.swift`) is what every overlay implements. `HandGestures` and
    `MouseGestures` produce the same gestures. `DisplayEffects` is Display mode's overlay per task. `Theme` holds each
    model family's brand look.
  - `Stories/`: presentations made of steps, the presenter stepping through them. `Story.all` is the registry. One
    folder per story, with shared building blocks in `Kit/`. Assets live in `Stories/Assets/<Story>/`: they aren't
    compiled, `build.sh` copies them in. **Read `Sources/YoloMeet/Stories/README.md` before touching a story**: it
    documents the Effect API, particles, gestures, keys, transitions, branches and the CV onboarding story's layouts. Keep
    it up to date when adding patterns or layout options.
- **`scripts/`**: `export_models.py` and `export_mediapipe.py` export models to Core AI, with their outputs attached
  to the GitHub `models` release that the app downloads from. `make_icon.swift` draws the app icon.

## Conventions

- **Styling stays where it belongs:** a story's look goes in its own constants (e.g. `NNColors`), not in `Theme`,
  the decoders or shared effects. Changing those changes Display mode and the other stories. Overlays follow each
  vendor's brand (README › Visual style).
- **Sizes:** stage sizes are multiplied by `frame.stage.unit` (the stage is 1280 × 720 at unit 1). Use `set(_:_:)`
  for SpriteKit properties written every frame, to skip writes that change nothing.
- **Commits** go straight to `main`, only when asked. Push only when asked. `SCENES.md` and `optimizations.md` are
  local notes, excluded in `.git/info/exclude`: never commit them.
- **The user's app:** don't quit or relaunch the user's running app. Build it and tell them to relaunch.
