# Stories

A story is a sequence of steps the presenter moves through (panel, or clicker keys). Each step names the models it
needs and builds the effects drawn on the stage. A story's code lives in its own folder, and its files in a folder of
the same name under `Assets/`.

```
Stories/
  Story.swift          Story and Step types, the registry (Story.all), Story.asset(_:in:)
  Kit/                 building blocks shared by stories (text, glow, particles)
  Test/                one folder per story
    TestStory.swift            the story: its steps
    FingertipGlowEffect.swift  effects only this story uses
  Assets/              not compiled; copied into the app by scripts/build.sh
    <Story>/           .usdz models, images, sounds of that story
```

## Adding a story

1. Create `Stories/<Name>/<Name>Story.swift` with `extension Story { static let <name> = Story(id:title:steps:) }`.
2. Add it to `Story.all` in `Story.swift`.
3. Put effects only this story uses in its folder. Move something to `Kit/` once a second story needs it.
4. Put its files in `Assets/<Name>/` and find them with `Story.asset("file.usdz", in: "<Name>")`, in the built app
   (`scripts/build.sh`) and with `swift run`.

A step lists models by catalog id (`ModelCatalog`); missing ones are downloaded when the step is shown. Effects are
built anew each time a step starts.

## Models

Results arrive in `frame.outputs[modelID]` as `ModelOutput`s: detections in frame pixels (top-left origin), tracked
(stable `trackID`) and predicted to the shown video frame.

| Id | Keypoints per detection |
| --- | --- |
| `mediapipe-hand`, `vision-hand` | 21 in MediaPipe's order: wrist 0; thumb 1–4, index 5–8, middle 9–12, ring 13–16, little 17–20 (tips 4, 8, 12, 16, 20). `classIndex` 0 left, 1 right |
| `yolo26n-pose` (any YOLO pose), `vision-pose` | 17 in COCO's order (wrists 9, 10) |
| `mediapipe-pose-*` | 33 (MediaPipe's pose order) |
| `mediapipe-face` | 478 (face mesh); `vision-face`: Vision's landmark regions |

Other tasks: boxes (`detect`), masks as `overlay` images (`segment`, `semantic`, `depth`), `topClasses` (`classify`).

## Effects

Subclass `Effect` and override `update(_ frame: StageFrame)`, called every rendered frame (60 fps). The stage draws
the video, then every effect's 3D content, then every effect's 2D content.

- **2D (SpriteKit):** add nodes to `node`. Positions in stage points (bottom-left origin): `frame.stage.point(_:)`
  converts a frame pixel.
- **3D and particles (RealityKit):** add entities to `entity`. The camera is orthographic and one world unit is one stage
  point: x right, y up, z toward the viewer (0 is the video plane). `frame.stage.position(_:z:)` converts a frame
  pixel. Particles: `ParticleEmitterComponent`. Custom objects: load a `.usdz` from the story's assets with
  `Task { entity.addChild(try await Entity(contentsOf: Story.asset("ship.usdz", in: "Space")!)) }`, then scale it to
  stage points. Lit materials get a default studio light (soft environment and a key light from the upper
  left); unlit materials and particles ignore it.
- **Sizes:** multiply by `frame.stage.unit` (1 at a 720-point-high stage) so effects look the same at any stage size.
  RealityKit particle sizes and speeds don't follow an entity's scale: set them from the unit (see `GlowingDot.resize`).
- **Per object:** `TrackedNodes(in: node)` or `TrackedNodes(in: entity)` keeps one node or entity per track ID, created
  when a track appears and removed (2D: faded) when it's gone.
- **Smoothing:** move toward targets with `frame.smoothing(gap:)` (or `frame.smoothing`); it is 1 when the panel's
  Smoothing switch is off.

## Kit

- `TextEffect`, `titleCard(_:)`: captions and a lower-third title that fades after 3 s.
- `GlowingDot`: a steady additive light with trailing sparks (3D layer); `glowTexture` for your own particles.

The `Test` story is the reference: MediaPipe hand tracking drives `GlowingDot`s on each fingertip.
