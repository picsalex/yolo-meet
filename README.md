# yolo-meet

Native macOS app (Swift, Core AI, Metal, RealityKit, SpriteKit) that runs Ultralytics YOLO models on your camera and draws effects
into a **Stage** window you share in Google Meet (Present → A window). The **yolo-meet** panel window stays private.

Requires macOS 27+ on Apple silicon and Xcode 27.

## Build

```bash
./scripts/build.sh          # build/yolo-meet.app (ad-hoc signed)
./scripts/build.sh --dmg    # + build/yolo-meet.dmg
```

The app and disk icon (`Support/AppIcon.icns`) is drawn by `swift scripts/make_icon.swift`.

Recipients of an ad-hoc signed app allow it once in System Settings › Privacy & Security › Open Anyway.

## Test

```bash
YOLO_MEET_MODELS=/path/to/unzipped/aimodels YOLO_MEET_IMAGE=/path/to/bus.jpg swift test
```

Model tests run the real `yolo26n*` Core AI models on Ultralytics' `bus.jpg` and are skipped when the variables are unset.
MediaPipe tests run when `YOLO_MEET_MEDIAPIPE` points to unzipped `mediapipe-*.aimodel` folders with an `img` folder of
MediaPipe's sample photos (woman_hands, thumb_up, pose, portrait) and `reference.json` from
`scripts/export_mediapipe.py --reference img`.
The pen link's network tests connect a pad to a host on this machine, some over Bonjour (one at a time, and with no
other yolo-meet advertising the pen nearby); `YOLO_MEET_NO_NETWORK=1` skips them.

## How it works

`Camera` → `Pipeline` (Vision person segmentation, on its own queue, replaces the background; each active model runs
at its own rate on the newest frame, once per frame, and a `Tracker` assigns IDs) → `StageRenderer` (Core Image draws the frame, RealityKit the effects' 3D content and particles, SpriteKit their 2D content, into one Metal
drawable at 60 fps). Models run at their own rate on older frames than the one shown, so detections are carried forward
at the speed they moved between the last two runs: the video has no added delay and overlays keep up with fast hands.

Models come from `ModelCatalog`: YOLOv5u (detect), YOLOv8 and YOLO11 (detect, segment, pose, OBB, classify), YOLO26 (all 7 tasks), sizes n–x, and RF-DETR (detect n–l, segment n–2xl, pose preview), exported to Core AI by `scripts/export_models.py`; MediaPipe hand, pose (lite, full, heavy) and face landmarkers, exported by `scripts/export_mediapipe.py`; all attached to the `models` release. Apple Vision's hand, body and face landmarks are built into macOS. They are downloaded from the panel,
and live in `~/Library/Application Support/YoloMeet/Models`.

## Visual style

Overlays follow each vendor's brand so the families stay distinct (`Sources/YoloMeet/Render/Theme.swift`):

- **YOLO** — [Ultralytics brand](https://www.ultralytics.com/brand): the 20-color annotation palette, Arial labels, 3 px boxes, skeletons in Aqua Blue (left), Neon Pink (right) and Light Blue with Neon Yellow joints, depth in the Ultralytics gradient, captions in Archivo on Dark Blue.
- **RF-DETR** — [Roboflow brand](https://roboflow.com/brand) and supervision's annotator defaults: supervision's palette, Geist Mono labels, 2 px boxes, Purple/Lavender skeletons with Cream joints.
- **MediaPipe** — MediaPipe's `drawing_utils` defaults: light gray connections, red landmarks; the face as a thin mesh.
- **Apple Vision** — white lines, system blue joints.

Archivo and Geist Mono are bundled from Google Fonts under the SIL Open Font License (`Support/Fonts`).

## MediaPipe and Apple Vision

Under Models › Other, next to RF-DETR:

- **MediaPipe** (Google, Apache-2.0): its official hand, pose and face landmarker models, converted TFLite → ONNX →
  Core AI by `scripts/export_mediapipe.py` (each step checked against the previous runtime; the pose detector's sparse
  weights are densified first). `Landmarker` runs MediaPipe's two-stage pipeline in Swift: the detector on the
  letterboxed frame (SSD anchors, weighted NMS), then the landmark model on a square crop rotated upright (palm, hips
  or eyes), with MediaPipe's heatmap refinement for pose. As in MediaPipe's video mode, each result's next crop comes
  from its landmarks, so the detector only runs to find new ones; crops run in parallel. Landmarks match MediaPipe
  Tasks within 0.1–0.4% of the image on its sample photos, detected or tracked (`LandmarkerTests`). Up to two hands,
  one body and one face (MediaPipe's defaults; the scenes show one person); MediaPipe's own 0.5 thresholds apply.
- **Apple Vision**: the hand (21 points), body (17, COCO order) and face landmark requests built into macOS. Faces are
  tracked from frame to frame, so face detection only runs every 10 frames or when a face is lost.

Both produce detections with keypoints, so tracking, smoothing and the pose effects work on them like on YOLO pose.

## Custom models

Models › Custom › Import Model… takes PyTorch weights (`.pt`/`.pth`) from Ultralytics or RF-DETR, or an `.aimodel` (`.aimodel.zip`) already exported to Core AI.

- **PyTorch weights** are converted by the bundled `export_models.py --convert` in a private Python environment (`~/Library/Application Support/YoloMeet/Converter`), created with [uv](https://github.com/astral-sh/uv) on the first conversion (about 1.3 GB; uv is downloaded if it is not installed). Everything it installs stays in that folder — uv's own Python, the venv, Ultralytics' settings — and uv's download cache is disabled; Models › Custom › Remove… deletes it. The exported model is copied into `Custom` and its temporary files are removed, on failure too. Python is only used to convert, never to run models. RF-DETR needs a training checkpoint that records its settings (`checkpoint_best_ema.pth`).
- **Core AI models**: the family is detected from the model's input/output names and the task from its metadata (Ultralytics) or outputs (RF-DETR); RF-DETR class names are read from the `.rfdetr.json` sidecar next to the asset when present. YOLO end-to-end (NMS) exports and Core ML files are refused with instructions.

Imported models live in `~/Library/Application Support/YoloMeet/Custom` and can be renamed or deleted.

## Sources

The panel's Source section picks what the stage shows under the effects:

- **Camera**: switch it off to stop capture (the camera light goes off); the stage then shows the background, or black.
  Background replacement and mirroring apply to the camera only.
- **Media**: images and videos added with "+", or downloaded from a pasted link (YouTube and most video sites) with
  [yt-dlp](https://github.com/yt-dlp/yt-dlp). yt-dlp is fetched from its GitHub release on first use into
  `~/Library/Application Support/YoloMeet/Tools`, checked against the release's SHA-256 list, and refreshed every two
  weeks. Only the video stream is downloaded (H.264 MP4 up to 1080p; the stage is muted). Media lives in
  `~/Library/Application Support/YoloMeet/Media`. Videos loop, with play/pause and a scrubber; models, tracking and
  stories run on media exactly as on the camera. Images and video frames are scaled to the camera's 1080p, and models
  run once on a still or paused frame.

## Inference settings

The panel's Inference section applies to every model on stage:

- **Image size**: by default each model runs at the size it was trained at, as Ultralytics does (640; 1024 for OBB
  and semantic; 768 for depth; 224 for classify), or set one size (160–1280) for all. It is the frame's long side.
  Preprocessing matches Ultralytics' (plain bilinear letterbox, gray 114 padding, RGB 0–1) within FP16 rounding.
  YOLO models are exported with a variable input height and width, so each frame is letterboxed to its own aspect in multiples of 32, like Ultralytics' rectangular inference (a 16:9 camera at 640 runs at 640×384). Classify keeps its training size; RF-DETR and YOLO26 depth keep their fixed export size (variable-size depth falls back to the CPU). Each new size is compiled once by Core AI, so the slider applies on release.
- **Confidence**: minimum score for boxes, masks and keypoints.
- **IoU**: NMS overlap threshold for YOLO (RF-DETR has no NMS).

## Debug mode

Toggle it in the panel's Status section. It draws on the stage (so it is visible in Meet): the recognized hand gesture or the one charging, with each hand's pinch, curl, thumb and speed measures (top left), and (top right) camera and stage resolution and FPS, and per model its rate, latency, size on disk, parameters, GFLOPs, architecture (CNN or Transformer), input size and precision. Parameters, GFLOPs and architecture come from each asset's metadata, written by the export script.

## Mouse and trackpad

Everything but the fist also works with the mouse or trackpad on the stage, e.g. to rehearse without a camera: press
and move to drag, pinch the trackpad (or scroll with Command held) to zoom around the cursor, and in action mode the
cursor points like a fingertip (hold Space, hover an item, release).

## Draw

The panel's Draw section (or **P** on stage) turns on freehand ink over the stage, as Meet's annotations do: press and
move the mouse or trackpad to draw. While it's on the mouse draws instead of making gestures; hands still do. Pick the
color and width in the panel; **C** clears and **Backspace** undoes the last stroke. Ink stays on stage when Draw is
turned off, until it is cleared.

- **Tool**: the pencil draws; the eraser removes the strokes it touches, whole (a ring shows how far it reaches; it
  grows with the width). Erasing can't be undone. Picking a color takes the pencil back.
- **Fading ink**: off, strokes stay until they are undone, erased or cleared; on, each fades out once it has stayed
  the time set under it (1 to 30 seconds).

### iPad pen

With **iPad pen** on in the Draw section, an Apple Pencil draws on the stage from the **yolo-meet pen** app on an
iPad. The iPad is a pad that stands for the stage and shows it: where the pencil is on it is where it is on stage.

- The pad shows the stage as it is drawn (camera, effects and ink), up to 20 pictures a second (4 while the pencil
  has been away from the pad for a few seconds, back to 20 as soon as it hovers), so you draw on what you see. Your line follows the pencil on the pad at once; the stage's picture, a moment behind, takes it over when
  it has it. With nothing on stage yet (no camera or media), the pad is black and shows its own ink.
- Touching draws, and a harder press makes a wider line. With the eraser, touching removes the strokes under it.
- Hovering over the glass (iPads that sense it) shows the nib on stage, in a ring that closes in as the pencil comes
  down, so you can aim while looking at the Mac.
- A double tap on the pencil switches between the pencil and the eraser; a squeeze (Apple Pencil Pro) picks the next
  color, with a tap in the barrel.
- The bar under the pad has the panel's ink settings: pencil or eraser, the colors, and under the sliders button the
  width, Fading ink and its time. They are the same settings: a change on either shows on the other. It also undoes
  and clears.
- Fingers draw too until a pencil has touched the pad; after that they are ignored, so a resting hand leaves no ink.

The two find each other on their own (Bonjour) and neither needs the internet: over the Wi-Fi network they share,
or straight between the devices when they share none (Wi-Fi turned on, on both). A USB cable charges the iPad but
doesn't carry the strokes. Each asks once to use the local network. The stage's pictures are a couple of megabytes a
second on that link; a slow one gets fewer of them. One pad draws at a time, named in the panel.

The link is paired and encrypted, so it is safe on a network you share with strangers. yolo-meet makes a **pairing
code** (20 characters, next to iPad pen in the panel: Show reveals it) that is typed once in the pen app, which keeps
it in the iPad's keychain. Both ends make the link's key from the code (TLS 1.2, pre-shared key, AES-256-GCM):
without it a device can't connect, see the stage or draw, can't push the connected iPad out, and can't read what
crosses. Inside that, each connection makes keys of its own (X25519, then ChaChaPoly, `PenSession`) that are never
sent nor kept, so a session someone recorded stays unreadable even if they learn the code later. **New** makes another
code and lets go of every iPad that had the old one; the pen app's key button takes the new one. Devices that don't
have the code can't connect or read anything, and make it hard to keep the iPad out: the Mac always makes room for a
new connection (the address holding the most unfinished ones gives one up, and never one that has shown the code),
and the iPad moves on from a host that doesn't answer. A sustained, fast flood from many addresses could still delay
or block the iPad's connection, only while it lasts. Both ends check they speak
the same version of the link; if not, the iPad says to update both apps. What others nearby can still see is that a
Mac offers the yolo-meet pen service: it is advertised under the app's name, but its address points at the Mac's
network name (`<name>.local`), as for any service a Mac shares. The Mac's own name only goes to an iPad that has the
code, for its status line. On the Mac the code is kept with the app's settings, readable by anything that runs as you
there.

The app is the Xcode project in `iPad/` (iPadOS 18+): open `iPad/YoloMeetPen.xcodeproj`, pick your team under
Signing & Capabilities, and run it on the iPad. It shares its messages and connection with yolo-meet (`Sources/PenLink`).

## Keys

While yolo-meet is the active app (not typing in the panel), scenes can use R, Z, Q, S, D, 0 and the space bar, read by position
(AZERTY letters; the same keys are W, A, S, D on QWERTY, and 0 works without Shift). In the Test story's Particles
scene: **R** turns the slow spin on or off, **Q**/**D** turn the shape left or right and **Z**/**S** tilt it while held,
**0** resets the turn, tilt and zoom, and holding **Space** enters action mode: the item your index fingertip (or the cursor) points at grows,
and releasing Space acts on it (in the Test story, the 3D shape or the cube's top face: it shows "Action"). H hides the camera image (black stage) and shows it again. Arrows and Page Up/Down step through the story while yolo-meet is active,
and from any app with Clicker keys on; the stage's other keys (R, Q/D, Z/S, 0, Space) never work from other apps, so typing in Meet's chat can't trigger them.

## Extending

- **Display mode**: any downloaded model, rendered by `displayEffects(for:model:)` according to its task.
- **Stories**: one folder per story under `Sources/YoloMeet/Stories/`, with its steps, effects and assets; see
  [Stories/README.md](Sources/YoloMeet/Stories/README.md). An `Effect` owns a 2D `SKNode` and a 3D RealityKit `Entity`
  and gets `update(_:)` every frame with all model outputs and a `Stage` that maps frame pixels to the screen.
