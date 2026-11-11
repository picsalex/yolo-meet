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
  each point along its shape's offset (a cube's faces out along their normals). See `ParticleMorphEffect`. The
  particles spring to their points, so they trail the shape when it moves: 2D content drawn on them uses
  `shownPoint(_:)` (after `follow(time:dt:)`), not `stagePoint(_:)`, to stay on them. See `NetworkEffect`.
- **Keys:** `frame.keys.pressed` (this frame, for toggles), `frame.keys.held` (hold to act; `"cmd"` while Command
  alone is held) and
  `frame.keys.released` (this frame), while yolo-meet is
  the active app. Only `StageFrame.Keys.reserved` keys reach effects: R, Z, Q, S, D, 0 and `"space"`, read by position
  and named as on AZERTY (W, A, S, D on QWERTY); arrows and page keys step through the story. See `ParticleMorphEffect`
  (R spin on or off, Q/D turn, Z/S tilt, 0 reset, Space acts on the pointed face when released).
- **Actionable items** (hold the space bar, point with an index fingertip, release to act): keep an `Actionable` per
  item and call `if item.update(frame, isOn: { … }) { act }` every frame, with a test of whether a stage point is on
  the item (nil while it can't be pointed at). A fingertip touches with a small circle (`Pointer.reach`, 18 points),
  not a point. Holding Space is action mode: the item pointed at grows (`item.scale`:
  draw and hit-test the item at it) and so does the fingertip's joint in `handSkeleton()`. `update` returns true on
  the frame Space is released while it's pointed at (one item per release). Hit tests: a 3D entity's
  `stageBounds.contains`; a particle shape's part with `ParticleSystem.stagePoint` (e.g. `CubeFace.corners` mapped
  through it) and `point.isInside(polygon)`, grown with `ParticleSystem.highlight` (its `parts`). `PopLabel` confirms
  an action. See `ManipulationEffect` (the 3D shape) and `ParticleMorphEffect` (the cube's top face). Lower level:
  `frame.pointers` (the index fingertips of the hands in view, not fists, then the mouse cursor over the stage) and `frame.pointer(on:)`.
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
| Fist | `.fist(location:)` | a closed fist, started while Command is held (fist mode) so a stray fist never acts; `location` is the hand's center, to follow it |

Keys split the gestures. Command held (fist mode): only fists start, at once. Space held (action mode): nothing
starts, fingertips point at actionable items. Neither: only drags and zooms. Pressing either key ends a drag or zoom
at once. A fist, once started, goes on until the hand opens, keys or not.

A one-hand pinch only starts its drag once its hand has held it still for 0.25 s (`HandGestures.charge`, `still`);
moving the hand restarts the wait, so pinching in passing never moves anything. Meanwhile `frame.charge` reports it
(location, progress). Two hands pinching start at once. A fist needs every finger curled into the palm and the thumb
folded in (`fist`, `thumbIn`), so a relaxed half-closed hand isn't one.

`phase` is `.began` once, `.changed` every frame, then `.ended` once (e.g. act on a fist's release), with the
values from 0.1 s before the end, since releasing a pinch or a hand leaving the frame moves them. A hand at the frame's
edge counts as open. A pinch or fist missed for under 0.15 s doesn't end its gesture. One gesture at a
time: a fist wins; two pinching hands become a zoom or a two-hand drag once they have moved
12 points (whichever changed more, their distance or their midpoint, kept until they let go); a one-hand drag ends
when the second hand pinches and becomes a fist when its hand
closes (closing a fist passes through a pinch). Positions are One Euro filtered
(steady at rest, quick when moving fast); `gesture.location` is where the hand acts (pinch, between the pinches,
hand's center): keep a `Grip` per object and act on `grip.update(frame, isOn: { … })`, the gesture while it holds the
object (it began on it), so gestures only act on the object the hand is on; draw the object at `grip.scale`, which
swells while a pinch charges on it and stays slightly larger while held (see `ManipulationEffect`). Debug mode
shows the gesture, the charge and each hand's measures (pinch, curl, thumb, speed); tune the thresholds in
`HandGestures`.

The mouse and trackpad make the same gestures (`Render/MouseGestures.swift`), with nothing for effects to add: press
and move on the stage to drag, pinch the trackpad or Command + scroll to zoom around the cursor (`hands` 2), and the
cursor over the stage points in action mode (`Pointer.mouse`). No fist with the mouse. A mouse gesture starts at once
and wins over the hands' while it acts.

## Kit

- `TextEffect`, `titleCard(_:)`: captions and a lower-third title that fades after 3 s.
- `ObjectTitle(_:subtitle:)`: an object's title and subtitle beside it (`update(above:)` puts them at the stage's top,
  centered over it, instead); `Callouts([...])`: descriptions with a line to
  points of an object (its parts), in a column on each side. Both follow the object, fade with `visible`, and take the
  object's stage rectangle (`CGRect(enclosing:)`, `Entity.stageBounds`). See `ParticleMorphEffect` (the cube's title,
  its faces described once exploded).
- `handSkeleton(opacity:)`: the hands' skeletons from `mediapipe-hand` (light gray, white joints, 15%), drawn
  `behind` objects and particles, to guide the gestures; the index fingertip's joint grows on an actionable item.
- `ParticleShapes`: shapes for `ParticleSystem.form(_:)`, with how they explode (cube: faces apart) and their parts
  (cube: `CubeFace`, with each face's corners).
- `Grip`: whether the gestures hold an object (they began on it), with its swell while a pinch charges and held (`scale`).
- `Actionable`, `PopLabel`: items to point at and act on with the space bar (hold, point, release), and a word that pops to confirm; with
  hit-test helpers `Entity.stageBounds`, `CGPoint.isInside(_:)`, `CGRect(enclosing:)`.
- `KeyTurn`: turns an object with the keys (R spin, Q/D turn, Z/S tilt, 0 reset); apply its `rotation`. `spinning:`
  false starts with the spin off; `restingTilt`/`restingTurn` set the view at rest (and on 0).
- `GlowingDot`: a steady additive light with trailing sparks (3D layer); `glowTexture` for your own particles.

`Callouts.setText(_:at:)` changes a description (e.g. a value of what's pointed at); `Callouts(_:font:size:line:)`
sets its look, and `update(…, left:)` puts every label in one column (e.g. beside a whole layout, as `NetworkEffect` does).

H on stage (or the panel's switch) hides the camera image: the stage is black behind the effects, and
`frame.cameraHidden` tells them (NN intro centers its object meanwhile, then puts it back).

A step can loop: `Step(…, loop: 7)` starts it over every 7 seconds. Effects read the step's clock from the frame
(`StageFrame.stepTime`, since the step or its loop started, and `loopCount`, 0 the first time through) and play their
timeline from it, fading back in when it starts over (`loopCount > 0`).

A step can follow the previous one with no transition, as in a slide deck: `Step(…, transition: .none)`. Moving
between the two (either way) swaps instantly instead of fading the 2D content out and in, and each new effect has
`continuing` set: what both steps share (e.g. the title and subtitle) shows at once and stays still (a title that changes cross-fades in
place), while what the
step adds or drops still fades in or out (NN intro: the arrows on the same object).

An effect can move the story on itself with `frame.nextStep()` (as the clicker's →), e.g. when a gesture completes
its step.

The `NNExplained` story is the first full scene: a black box (`NetworkLayout.blackBox`), its edges made of the
particles in dark gray and its faces filled black behind them (`BlackBoxEffect`, `behind`), turning on its own
(`NetworkLayout.spins`); Cmd + fist releases the particles, fading them to the system's blue
(`ParticleSystem.scatter(plainColors:)`), and opening the hand moves on (`releases`, as a cloud does),
then a brain (`Brain.shape`) holding a network of 300
neurons (balls of particles, each its own part) and their synapses (lines of particles); in action mode, the touched
neuron shows as a disc with its bias and the touched synapse with its weight, kept on the particles with `shownPoint`.
Its next step lays 23 of those neurons out as a multilayer perceptron (10 → 5 → 8): first only those neurons glide out of the brain to their place (a layout's `prelude`, formed first when coming from the layout it `splitsFrom`), then the rest of the brain glides on into the connections; and the last one shows YOLO's
architecture: blocks of layers as boxes of particles (a layout's `Neuron.box`, described with `info` when touched),
each holding its neurons as slices of dot grids (`Neuron.grid`: one slice per channel, one dot per cell), in
backbone, neck and head columns (`headers`). In action mode a touched block is outlined in gold (2D, over its
particles), and a touched header turns gold and outlines all its blocks. Then drawn arrows (`Arrow`, a layout's `arrows`) go into the
model's input and out of its output, and the last step gathers the architecture's dust into a colored picture of a cat
at the input (`NetworkLayout.picture`: the same shape with only those particles moved, formed with
`form(_:staggered: false)` so the others stay still; a shape colors its own points with `ParticleShape.colors`). Zoomed in, all the particles become that picture's
pixels (`pixels`: 32 × 32 solid squares, every particle gliding there from where the previous step left it, so the
picture grows instead of forming anew), which then split into red, green and blue layers back to back (`channels`:
each pixel's particles a third per channel, adding up to its color from the front; a layout that `splits` starts where
the one it follows (`splitsFrom`) left the particles and moves on through `ParticleSystem.explode` and the shape's `offsets`, eased, while the view turns to
its resting angle: the view always turns smoothly from the previous step's). Then only one layer stays, gray
(`grayscale`: the red layer turns gray in place, the green and blue ones fade to black, which adds no light), and it
fans out into five multispectral bands (`multispectral`: blue, green, red, red edge, near-infrared). Particles' colors
always fade from the previous shape's to the new one's (`ParticleSystem.colorFade`). Back at the picture, the last
step loops (`loop: 7`): its pixels flow through the model as pulses of gold light, from the input arrow down the
backbone, through the neck to a Detect block of the head (`NetworkLayout.flow`: a random path of the blocks'
connections per pixel), while the architecture stands still, its blocks lighting up gold as the pixels go through them
(`ParticleSystem.paint(_:color:)`, from how many are in each block), and once they're through, the result ("Cat",
`NetworkLayout.flowResult`) shows past the output arrow until the loop starts over; before, the bands merge back into the RGB pixels
and that picture glides home (`returning(to:from:through:)`, through `pixels` as a prelude); Then each YOLO task gets two
steps (`Tasks.swift`): its output on the cat picture (the particles glide into one large picture, recolored per task:
the cat's mask, class colors, an inferno depth map in relief; `TaskOutputEffect` draws the box, polygon, legend, top
classes, keypoints or oriented box over it; semantic segmentation also zooms in, `semanticZoom`, its pixels large
squares with their class ID written on them one after the other, Space + point shows one's class: the window's
particles grow into them while the rest turn black where they are, shift just enough to fill the grid, and light up
there through `NetworkLayout.arrivedColors`), then the real YOLO26n model of that task on the camera, with the app's
live overlays (`BoxesEffect`, `OverlayEffect`, `ClassifyEffect`, `PoseEffect`, `OrientedBoxesEffect`); as the model visualizer
draws them (class colors), except the depth map, inferno as on the cat (`OverlayEffect(depthColors:)`); the cat steps' boxes
are Ultralytics yellow. The last step, a **recap** (`NetworkLayout.recap`, `RecapEffect`), shows the input picture on top, an
arrow down into YOLO (the architecture, shrunk) and arrows splitting to the seven tasks' small pictures: the last task's
picture first glides whole to the input's place (its `prelude`), then each output comes out of it, dimmed on the way and lit
once there (`arrivedColors`). `ParticleSystem.place(_:at:colors:)` moves and colors
some particles every frame without forming again, and black particles stay unseen as they move. **Steps that continue each other**
share one state object created in the story file (`NeuralNetwork`: one `ParticleSystem` and its layouts), so the next
step's effect forms its shape from where the particles are; `ParticleShape.following(_:parts:)` orders a shape so a
part of the previous one (a neuron) flies into a chosen part of the new one.

The `Test` story is the reference: hand gestures move, resize and change a 3D shape (`ManipulationEffect`), particles
form and explode a cube (`ParticleMorphEffect`), and both are actionable.
