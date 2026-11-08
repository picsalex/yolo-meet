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
    ManipulationEffect.swift   effects only this story uses
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
the video, then the 2D content of effects marked `behind`, then every effect's 3D content, then its particles, then
its 2D content.

- **2D (SpriteKit):** add nodes to `node`. Positions in stage points (bottom-left origin): `frame.stage.point(_:)`
  converts a frame pixel.
- **3D and particles (RealityKit):** add entities to `entity`. The camera is orthographic and one world unit is one stage
  point: x right, y up, z toward the viewer (0 is the video plane). `frame.stage.position(_:z:)` converts a frame
  pixel. Particles: `ParticleEmitterComponent`. Custom objects: load a `.usdz` from the story's assets with
  `Task { entity.addChild(try await Entity(contentsOf: Story.asset("ship.usdz", in: "Space")!)) }`, then scale it to
  stage points. Lit materials get a default studio light (soft environment and a key light from the upper
  left); unlit materials and particles ignore it.
- **Particles that form shapes:** set `particles = ParticleSystem()` (60,000 glowing points, simulated on the GPU,
  `Render/Particles.swift`) and steer it every frame: `center`, `radius` (cloud), `size` and `rotation` (shape), in
  stage points. `form(shape)` flies them into a `ParticleShape` (one point per particle in -1...1, e.g.
  `ParticleShapes.cube(count)`), `scatter(kick:)` breaks it back into a swirling cloud, and `explode` (0...1) moves
  each point along its shape's offset (a cube's faces out along their normals). See `ParticleMorphEffect`.
- **Keys:** `frame.keys.pressed` (this frame, for toggles), `frame.keys.held` (hold to act) and
  `frame.keys.released` (this frame), while yolo-meet is
  the active app. Only `StageFrame.Keys.reserved` keys reach effects: R, Z, Q, S, D, 0 and `"space"`, read by position
  and named as on AZERTY (W, A, S, D on QWERTY); arrows and page keys step through the story. See `ParticleMorphEffect`
  (R spin on or off, Q/D turn, Z/S tilt, 0 reset, Space acts on the pointed face when released).
- **Actionable items** (hold the space bar, point with an index fingertip, release to act): keep an `Actionable` per
  item and call `if item.update(frame, isOn: { … }) { act }` every frame, with a test of whether a stage point is on
  the item (nil while it can't be pointed at). Holding Space is action mode: the item pointed at grows (`item.scale`:
  draw and hit-test the item at it) and so does the fingertip's joint in `handSkeleton()`. `update` returns true on
  the frame Space is released while it's pointed at (one item per release). Hit tests: a 3D entity's
  `stageBounds.contains`; a particle shape's part with `ParticleSystem.stagePoint` (e.g. `CubeFace.corners` mapped
  through it) and `point.isInside(polygon)`, grown with `ParticleSystem.highlight` (its `parts`). `PopLabel` confirms
  an action. See `ManipulationEffect` (the 3D shape) and `ParticleMorphEffect` (the cube's top face). Lower level:
  `frame.pointers` (the index fingertips of the hands in view, not fists) and `frame.pointer(on:)`.
- **Sizes:** multiply by `frame.stage.unit` (1 at a 720-point-high stage) so effects look the same at any stage size.
  RealityKit particle sizes and speeds don't follow an entity's scale: set them from the unit (see `GlowingDot.resize`).
- **Per object:** `TrackedNodes(in: node)` or `TrackedNodes(in: entity)` keeps one node or entity per track ID, created
  when a track appears and removed (2D: faded) when it's gone.
- **Smoothing:** move toward targets with `frame.smoothing(gap:)` (or `frame.smoothing`); it is 1 when the panel's
  Smoothing switch is off.

## Hand gestures

The stage recognizes hand gestures for every scene from `mediapipe-hand` (else `vision-hand`), so a scene that wants
them lists that model. Effects read `frame.gesture` (`Render/HandGestures.swift`), positions in stage points:

| Gesture | `kind` | How |
| --- | --- | --- |
| Drag | `.drag(start:location:)` | one hand pinches thumb and middle finger, then moves; or both hands pinch and move together (`hands` 2, the point between them) |
| Zoom | `.zoom(scale:center:)` | both hands pinch and move apart or closer; `scale` > 1 apart (since they started pinching) |
| Fist | `.fist(location:)` | a closed fist; `location` is the hand's center, to follow it |

`phase` is `.began` once, `.changed` every frame, then `.ended` once (e.g. act on a fist's release), with the
values from 0.1 s before the end, since releasing a pinch or a hand leaving the frame moves them. A hand at the frame's
edge counts as open. A pinch or fist missed for under 0.15 s doesn't end its gesture. One gesture at a
time: a fist wins; two pinching hands become a zoom or a two-hand drag once they have moved
12 points (whichever changed more, their distance or their midpoint, kept until they let go); a one-hand drag ends
when the second hand pinches and becomes a fist when its hand
closes (closing a fist passes through a pinch). Positions are One Euro filtered
(steady at rest, quick when moving fast); `gesture.location` is where the hand acts (pinch, between the pinches,
hand's center): on `.began`, compare it with your object so gestures only act on the object the hand is on (see
`ManipulationEffect`). Debug mode shows the gesture and each hand's
measures; tune the thresholds in `HandGestures`.

## Kit

- `TextEffect`, `titleCard(_:)`: captions and a lower-third title that fades after 3 s.
- `ObjectTitle(_:subtitle:)`: an object's title and subtitle beside it; `Callouts([...])`: descriptions with a line to
  points of an object (its parts), in a column on each side. Both follow the object, fade with `visible`, and take the
  object's stage rectangle (`CGRect(enclosing:)`, `Entity.stageBounds`). See `ParticleMorphEffect` (the cube's title,
  its faces described once exploded).
- `handSkeleton(opacity:)`: the hands' skeletons from `mediapipe-hand` (light gray, white joints, 15%), drawn
  `behind` objects and particles, to guide the gestures; the index fingertip's joint grows on an actionable item.
- `ParticleShapes`: shapes for `ParticleSystem.form(_:)`, with how they explode (cube: faces apart) and their parts
  (cube: `CubeFace`, with each face's corners).
- `Actionable`, `PopLabel`: items to point at and act on with the space bar (hold, point, release), and a word that pops to confirm; with
  hit-test helpers `Entity.stageBounds`, `CGPoint.isInside(_:)`, `CGRect(enclosing:)`.
- `GlowingDot`: a steady additive light with trailing sparks (3D layer); `glowTexture` for your own particles.

The `Test` story is the reference: hand gestures move, resize and change a 3D shape (`ManipulationEffect`), particles
form and explode a cube (`ParticleMorphEffect`), and both are actionable.
