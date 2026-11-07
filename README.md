# YOLO-meet

Native macOS app (Swift, Core AI, Metal, SpriteKit) that runs Ultralytics YOLO models on your camera and draws effects
into a **Stage** window you share in Google Meet (Present → A window). The **YOLO-meet** panel window stays private.

Requires macOS 27+ on Apple silicon and Xcode 27.

## Build

```bash
./scripts/build.sh          # build/YOLO-meet.app (ad-hoc signed)
./scripts/build.sh --dmg    # + build/YOLO-meet.dmg
```

The app and disk icon (`Support/AppIcon.icns`) is drawn by `swift scripts/make_icon.swift`.

Recipients of an ad-hoc signed app allow it once in System Settings › Privacy & Security › Open Anyway.

## Test

```bash
YOLO_MEET_MODELS=/path/to/unzipped/aimodels YOLO_MEET_IMAGE=/path/to/bus.jpg swift test
```

Model tests run the real `yolo26n*` Core AI models on Ultralytics' `bus.jpg` and are skipped when the variables are unset.

## How it works

`Camera` → `Pipeline` (Vision person segmentation, on its own queue, replaces the background; each active model runs
at its own rate on the newest frame and a `Tracker` assigns IDs) → `StageRenderer` (Core Image draws the frame, SpriteKit draws effects, one Metal
pass at 60 fps). Models run at their own rate on older frames than the one shown, so detections are carried forward
at the speed they moved between the last two runs: the video has no added delay and overlays keep up with fast hands.

Models come from `ModelCatalog`: YOLOv5u (detect), YOLOv8 and YOLO11 (detect, segment, pose, OBB, classify), YOLO26 (all 7 tasks), sizes n–x, and RF-DETR (detect n–l, segment n–2xl, pose preview), exported to Core AI by `scripts/export_models.py` and attached to the `models` release. They are downloaded from the panel,
and live in `~/Library/Application Support/YoloMeet/Models`.

## Visual style

Overlays follow each vendor's brand so the families stay distinct (`Sources/YoloMeet/Render/Theme.swift`):

- **YOLO** — [Ultralytics brand](https://www.ultralytics.com/brand): the 20-color annotation palette, Arial labels, 3 px boxes, skeletons in Aqua Blue (left), Neon Pink (right) and Light Blue with Neon Yellow joints, depth in the Ultralytics gradient, captions in Archivo on Dark Blue.
- **RF-DETR** — [Roboflow brand](https://roboflow.com/brand) and supervision's annotator defaults: supervision's palette, Geist Mono labels, 2 px boxes, Purple/Lavender skeletons with Cream joints.

Archivo and Geist Mono are bundled from Google Fonts under the SIL Open Font License (`Support/Fonts`).

## Custom models

Models › Custom › Import Model… takes PyTorch weights (`.pt`/`.pth`) from Ultralytics or RF-DETR, or an `.aimodel` (`.aimodel.zip`) already exported to Core AI.

- **PyTorch weights** are converted by the bundled `export_models.py --convert` in a private Python environment (`~/Library/Application Support/YoloMeet/Converter`), created with [uv](https://github.com/astral-sh/uv) on the first conversion (about 1.3 GB; uv is downloaded if it is not installed). Everything it installs stays in that folder — uv's own Python, the venv, Ultralytics' settings — and uv's download cache is disabled; Models › Custom › Remove… deletes it. The exported model is copied into `Custom` and its temporary files are removed, on failure too. Python is only used to convert, never to run models. RF-DETR needs a training checkpoint that records its settings (`checkpoint_best_ema.pth`).
- **Core AI models**: the family is detected from the model's input/output names and the task from its metadata (Ultralytics) or outputs (RF-DETR); RF-DETR class names are read from the `.rfdetr.json` sidecar next to the asset when present. YOLO end-to-end (NMS) exports and Core ML files are refused with instructions.

Imported models live in `~/Library/Application Support/YoloMeet/Custom` and can be renamed or deleted.

## Inference settings

The panel's Inference section applies to every model on stage:

- **Image size** (160–1280): the frame's long side. YOLO models are exported with a variable input height and width, so each frame is letterboxed to its own aspect in multiples of 32, like Ultralytics' rectangular inference (a 16:9 camera at 640 runs at 640×384). Classify keeps its training size; RF-DETR and YOLO26 depth keep their fixed export size (variable-size depth falls back to the CPU). Each new size is compiled once by Core AI, so the slider applies on release.
- **Confidence**: minimum score for boxes, masks and keypoints.
- **IoU**: NMS overlap threshold for YOLO (RF-DETR has no NMS).

## Stats for nerds

Toggle it in the panel's Status section. It draws on the stage (so it is visible in Meet): camera and stage resolution and FPS, and per model its rate, latency, size on disk, parameters, GFLOPs, architecture (CNN or Transformer), input size and precision. Parameters, GFLOPs and architecture come from each asset's metadata, written by the export script.

## Extending

- **Display mode**: any downloaded model, rendered by `displayEffects(for:model:)` according to its task.
- **Stories**: add a file like `Sources/YoloMeet/Stories/HelloStory.swift`, then list it in `Story.all`. Each step
  names its models and builds `Effect`s. An `Effect` owns an `SKNode` and gets `update(_:)` every frame with all model
  outputs and a `Stage` that maps frame pixels to the screen.
