# Writing effects: the details

Read this when you write a new effect, or use labels, particles or pointing directly rather than through an existing
layout. The API overview is in `Sources/YoloMeet/Stories/README.md`. This adds a template, the coordinate spaces and
how the Kit pieces behave.

## A minimal effect

```swift
import RealityKit
import YoloMeetCore

/// One sentence on what it draws, with which model, and which gestures or keys act on it.
final class OrbitEffect: Effect {
    private lazy var hands = TrackedNodes(in: entity) { GlowingDot(color: .cyan) }  // one light per tracked hand

    override func update(_ frame: StageFrame) {
        let detections = frame.outputs["mediapipe-hand"]?.detections.filter { $0.trackID != nil } ?? []
        for (dot, detection) in zip(hands.sync(detections.map { $0.trackID! }, in: frame), detections) {
            guard let tip = detection.keypoints[safe: 8] else { continue }
            dot.position = frame.stage.position(tip.point, z: 10)
        }
    }
}
```

- **2D, 3D or particles?** Text, boxes, lines, flat shapes: 2D (`node`, SpriteKit). Objects, lights, glows: 3D
  (`entity`). Shapes made of points that morph or travel: `particles`. One effect can use all three. 2D draws on top
  unless the effect is `behind`.
- **Build once, update cheaply.** `update` runs 60 times a second. Create nodes and entities in `init` (or a
  `TrackedNodes` closure) and only change properties per frame. Write SpriteKit properties with `node.set(\.text,
  value)`, which skips writes that change nothing (text layout and shapes are costly).
- **Missing results.** `frame.outputs[id]` is nil while a model loads or without a camera, and `frame.gesture` is nil
  most of the time. Draw something sensible anyway.
- **Smoothing.** Results are already predicted to the shown frame and gestures are filtered. Ease toward targets with
  `frame.smoothing` (`smoothing(gap:)` for raw keypoints) and `approaching(_:_:)`, and snap on first placement.
  `OneEuroFilter` steadies your own tracked points (steady at rest, quick when moving).
- **Document the controls** in the effect's doc comment and the step's caption.

## Coordinates

| Space | Origin, axes | Use |
| --- | --- | --- |
| Frame pixels | top-left, y down | everything in `ModelOutput` |
| Stage points | bottom-left, y up | 2D nodes, gestures, pointers: `frame.stage.point(p)`, `frame.stage.rect(r)` |
| 3D world | same as stage points; z toward the viewer, 0 = video plane | entities: `frame.stage.position(p, z:)` |
| Particle world | 200 × `unit` stage points per unit (internal) | set `ParticleSystem` in stage points; shapes in -1...1 |

The stage aspect-fills the frame, so part of the frame can be cropped: `frame.stage.frameRect` is the frame's area in
stage points. The 3D camera is orthographic: an object's on-screen size is its size in points, while rotations still
show depth and lighting.

## Labels: `ObjectTitle` and `Callouts`

Create them once, add them to the effect's `node`, and call `update` every frame with the object's rectangle on stage
and whether they should show:

```swift
title.update(beside: rect, visible: !exploded, frame: frame)
parts.update(anchors: [leftPoint, rightPoint, topVisible ? topPoint : nil], around: rect, visible: exploded, frame: frame)
```

- **Placement.** The title sits beside the object's top right corner, and moves to the top left when it would run off
  the stage. Descriptions go in two columns, 40 points out from the rectangle: an anchor left of the object's middle
  puts its label in the left column. In a column, labels start at their anchor's height, keep at least 30 points
  apart and stay 16 points inside the stage.
- **Following.** Positions ease toward their targets, so labels trail a moving object instead of shaking with it.
  Lines and dots follow the anchors exactly.
- **Showing.** `visible` fades the set in or out in about a quarter of a second. They're always updated, so they come
  back in place. A nil anchor hides that one description (a part facing away, or not there yet).
- **Which one.** Show the title while the object is whole and the descriptions once it's taken apart, so they never
  crowd each other (`ParticleMorphEffect`).
- **Anchors.** A 3D entity: `entity.stageBounds`. A particle shape: `system.stagePoint(_:)` of a point in the shape's
  -1...1 space, and `CGRect(enclosing:)` of several such points. On moving particles, use `shownPoint` (below).

## Particles

| Property / call | Effect |
| --- | --- |
| `center`, `radius` | Where the cloud or shape is; the cloud's radius. Moving `center` drags the particles along. |
| `form(shape)` | Flies the particles into a `ParticleShape`, staggered. |
| `scatter(kick:)` | Breaks it back into a swirling cloud, with an outward burst. |
| `size`, `rotation` | Half the shape's size; its orientation (quaternion). |
| `explode` (0...1) | Moves each point along its shape's offset (a cube's faces apart). |
| `highlight = (part, center, scale)` | Grows one part (e.g. a cube face) around its center. |
| `stagePoint(p)`, `faces(normal)` | Where a shape point is on stage; whether a direction faces the viewer: hit-test parts. |
| `pointSize`, `color`, `brightness` | Look. |

- **A new shape** is a function returning a `ParticleShape`: one point per particle in -1...1, in random order, with
  `offsets` (where each point goes when exploded) and `parts` (for highlighting). `Brain.shape` shows folds by
  crowding points along the zero lines of a smooth wave pattern.
- **Things inside a shape** (a neuron, a line) are particles of the shape too, so they move with it exactly: a small
  ball of points as its own part, so `highlight` grows it, or points spread along a line.
- **2D drawn on particles** must use `system.shownPoint(p)` (call `system.follow(time:dt:)` after setting the
  placement), never `stagePoint(p)`. The particles spring to their points (`formStiffness`), so `stagePoint` runs
  visibly ahead of them. Draw with `SKSpriteNode`s, not `SKShapeNode`s: a disc texture, or a 1×1 sprite stretched for
  a line (`anchorPoint` (0, 0.5), `xScale` length, `zRotation` angle).
- **Zoom.** Particles stay 3 px wide whatever the zoom, so grow `pointSize` with it (`3 × √zoom`). Zooming around the
  hands' center lets the presenter zoom into one part:
  `home = center + (base.home - center) * zoom / base.zoom`.

## Many small pointable items

With hundreds of items (neurons), don't run overlapping `Actionable` hit tests. Find the one item under each
fingertip yourself (nearest center within its radius), pass `isOn` only for that one, and keep one `Actionable` per
item so each eases its own `scale`. Something only hovered, with no action (a synapse), calls
`frame.pointing.mark(hand)` so the fingertip still grows. See `NetworkEffect`.

## Smaller helpers

| Piece | Use |
| --- | --- |
| `PoseEffect(model:opacity:theme:)` | Any keypoint model's skeleton (hands, body, face mesh). `grownJoints` enlarges chosen joints. |
| `displayEffects(for:model:custom:)` | Display mode's drawings for a model's task (boxes, masks, depth, classes, poses). |
| `GlowingDot(color:radius:)` | A steady additive light with trailing sparks. Call `resize(unit:)` when the unit changes. |
| `glowTexture`, `radialGlow(size:stops:)` | A soft round light for your own emitter or sprites. |

## Why `Assets/` isn't inside each story's folder

SwiftPM needs every non-Swift file in a target excluded or declared, and its manifest cache doesn't notice new
folders. So one fixed `Stories/Assets` folder is excluded in `Package.swift` and copied whole by `scripts/build.sh`.
