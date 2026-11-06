# YOLO-meet

Native macOS app (Swift, Core AI, Metal, SpriteKit) that runs Ultralytics YOLO models on your camera and draws effects
into a **Stage** window you share in Google Meet (Present → A window). The **YOLO-meet** panel window stays private.

Requires macOS 27+ on Apple silicon and Xcode 27.

## Build

```bash
./scripts/build.sh          # build/YOLO-meet.app (ad-hoc signed)
./scripts/build.sh --dmg    # + build/YOLO-meet.dmg
```

Recipients of an ad-hoc signed app allow it once in System Settings › Privacy & Security › Open Anyway.

## Test

```bash
YOLO_MEET_MODELS=/path/to/unzipped/aimodels YOLO_MEET_IMAGE=/path/to/bus.jpg swift test
```

Model tests run the real `yolo26n*` Core AI models on Ultralytics' `bus.jpg` and are skipped when the variables are unset.

## How it works

`Camera` → `Pipeline` (Vision person segmentation replaces the background, then every active model runs on the newest
frame and a `Tracker` assigns IDs) → `StageRenderer` (Core Image draws the frame, SpriteKit draws effects, one Metal
pass at 60 fps). Models run at their own rate; effects animate toward the latest results, so motion stays smooth.

Models come from `ModelCatalog` (Core AI exports made by `scripts/export_models.py`, attached to the `models-v1` release), are downloaded from the panel,
and live in `~/Library/Application Support/YoloMeet/Models`.

## Extending

- **Display mode**: any downloaded model, rendered by `displayEffects(for:model:)` according to its task.
- **Stories**: add a file like `Sources/YoloMeet/Stories/HelloStory.swift`, then list it in `Story.all`. Each step
  names its models and builds `Effect`s. An `Effect` owns an `SKNode` and gets `update(_:)` every frame with all model
  outputs and a `Stage` that maps frame pixels to the screen.
