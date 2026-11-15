# Pitfalls and facts learned

Things that cost time before. Read this when something on stage behaves oddly (it lingers, never moves, renders
black, appears late), and before changing gesture thresholds.

## Models

- Ids come from `ModelCatalog` (`Sources/YoloMeetCore/ModelStore.swift`). Prefer the smallest model that looks good:
  a step often runs two or three.
- Always guard keypoint indices: `detection.keypoints[safe: i]`.
- The hand model tracks hands from frame to frame and only runs its palm detector to find new ones, so a second hand
  can take a few frames to appear. A hand is dropped as soon as its presence falls under 0.5.
- Hand and pose presence outputs are probabilities, face's is a logit (`presenceIsLogit` in `Landmarker`). A double
  sigmoid once kept lost hands alive as ghosts. If something lingers on stage, check whether the model really dropped
  it before touching the effect.
- Still images and paused videos are not re-inferred: a scene that needs motion must come from the camera or a
  playing video.
- Media is processed at 1080p (`Pipeline.workingSize`, cover). Models and effects never see 4K frames.

## Gestures

- A hand touching the frame's edge counts as open, since its points become unreliable there.
- A "regression" in gesture stability was once the laptop's position (lighting, hand angle), not the code. Compare
  with the previous build, and read Debug mode's measures (pinch, curl, thumb, speed) on your own hands, before
  changing a threshold in `HandGestures`.

## 3D (RealityKit)

- `.usdz` models load asynchronously. Start loading in `init`, and scale them to stage points:

  ```swift
  Task {
      guard let url = Story.asset("ship.usdz", in: "Space") else { return }   // nil when the file is missing
      let ship = try await Entity(contentsOf: url)
      ship.scale = .init(repeating: 200 / ship.visualBounds(relativeTo: nil).extents.max())  // 200 points wide at unit 1
      entity.addChild(ship)
  }
  ```

- 3D content is removed at once when the step changes, with no fade. Animate `OpacityComponent` if a fade matters.
- `ParticleEmitterComponent`: `fieldSimulationSpace = .global` leaves trails, `.additive` blending makes light.
- The 3D pass only runs when some effect's `entity` has children, the particle pass only when some effect has
  `particles`, and the behind layer only when some effect is `behind`. A step that doesn't use them pays nothing.

## Build

- Long SIMD or tuple-literal expressions can time out Swift's type checker: split them and annotate the types.
- Each `scripts/build.sh` signs the app anew, so the relaunched app can ask for camera permission again. Say so when
  you tell the user to relaunch.
