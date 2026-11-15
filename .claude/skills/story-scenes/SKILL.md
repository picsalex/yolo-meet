---
name: story-scenes
description: Create or change yolo-meet stories (the scenes presented on the stage), with their steps, branches and the phases inside a step. Covers designing scenes that explain, particle layouts and how particles fly from step to step, 2D overlays with live values, gestures, captions, loading, and checking the result by rendering steps offscreen. Use whenever the user wants a new story or scene, wants to add, insert, reorder or remove steps, wants an animation, transition, label, arrow, colour or gesture changed in a story, or says things like "add a state after 12", "make step 5 zoom in", "the particles should glide…", "new scene about X". Use it even if they don't say "story" or "skill", for example "can the brain explode into the perceptron", or a screenshot of the stage with a request.
---

# Making yolo-meet stories

yolo-meet's stories are live presentations. The presenter talks over them in a meeting, stepping with a clicker, to explain how neural networks and YOLO work. A scene succeeds when someone watching understands the idea from what's on screen. The best scenes explain, look good and move well, and that's what the user judges. Everything else in this skill serves those three.

Vocabulary:
- **Story:** a sequence of **steps** (the user calls them "states").
- **Phase** ("substate"): progress inside a step, driven by its own effect: a gesture, a timeline (`stepTime`, `loop`) or a staged glide (`prelude`).
- **Branch:** a sequence of steps entered from one step and returning to it (e.g. a quiz).

The API is documented in `Sources/YoloMeet/Stories/README.md`. Read it before writing code: it covers effects, particles, gestures, keys, transitions, branches and the Kit. `NNExplained/` (NN intro) is the full worked example of the look and feel. `Test/` is the small reference.

## Design the scene first

Before writing code, work out what each step shows. A sentence or two per step is enough.

**One idea per step, and show it working.** Ask what the audience should understand when the step ends, then put the mechanism itself on screen, not just a symbol of it:
- A neuron step shows its inputs, its weights, the weighted sum plus bias and the activation. The values update as inputs change, with lines from each input to its term.
- An attention step shows which tokens look at which, with the scores written on the links.

A scene with only a moving outline, or a table of parameters off to the side, tells the presenter's story less well than one that computes in front of the audience.

**Use the real numbers.** Compute values from the actual data on screen (the real colours of the picture shown, the real result of the operation) and write them out. Exact numbers that match what's shown make the explanation credible, and the presenter can point at them.

**Pace for someone talking:**
- When an operation repeats, take the first few examples slowly, so the presenter can walk through them.
- Then speed through the rest, so the whole thing completes.
- Hold the end state long enough to read before a loop restarts.
- Motion should carry meaning: things fly from where they come from to where they go, e.g. each output out of the input it was computed from.

**Give enough context.** When you zoom, keep the recognisable thing in frame: a whole feature of the object, not a crop too tight to recognise. People need to see where they are.

**Make the subject the brightest, most vivid thing on screen:**
- Supporting content stays readable and colourful. Don't dim neighbours into mud to make one element stand out.
- Use the story's accent instead: gold in NN intro, for outlines, lines, arrows and highlighted values.
- If particles add up to white, fix that element's colour or density so it stays vivid. Don't fade the focal element.

**Use the right tool for each part:**
- **Particles:** the substance, such as pictures, shapes and things that travel from step to step.
- **2D (SpriteKit):** precise things like numbers, equations, labels, grids of values, lines and outlines, placed with `shownPoint` so they stay on the particles.
- Don't force numbers into particles, or substance into 2D.

**Be generous.** When you're choosing between a minimal scene and one that explains more (an extra panel of values, a connecting line, slow first examples), choose the richer one. Mention in your report what you added, so the user can trim it.

**For a new story:** sketch the step list (title, the one idea, what's on screen, caption) and share it as you build. Each caption tells the presenter what to say or do ("Cmd + fist to open the black box"). Where the request leaves these open, pick and say what you picked:
- which beats the presenter advances (steps) and which the hands trigger inside one (phases);
- exact strings for titles, labels and captions;
- thresholds such as "zoom big enough", as numbers;
- data: random, fixed or real, with its range and format (e.g. `+0.42`).

## Build it

- **Shared state:** steps that continue each other share one state object created in the story file. NN intro's is `NeuralNetwork`: one `ParticleSystem` and its layouts. That's what makes particles fly from the previous step's shape into the next.
- **Build heavy state in `prepare`:** use `Story(…, prepare:)`, not launch. The app shows a loading card meanwhile. Build in chunks with short pauses, as `NeuralNetwork.init` does with `breathe`.
- **A step helper per story** (like `nnStep`): it adds the models every step needs, the hand skeleton and the caption.
- **Layout options** that already work: reuse them where they fit.
  - `splits` / `splitsFrom` / `prelude` for staged glides;
  - `arrivedColors` (travel unlit, light up on arrival) and `settled`;
  - `arrows` / `arrowFeeds`, `headers`, `dimensions`;
  - `flow` + `flowResult`;
  - `spins`, `releases`.
- **Generous scenes, minimal code:** delete before replacing, replace before adding, and no abstractions for a second use that doesn't exist yet.
- **Write the story's own effects** when the explanation needs something the existing ones don't do. Read `reference/effects.md` first: a template, the coordinate spaces, and how labels, particles and pointing behave in detail. A story's effects live in its folder. Don't reshape another story's effects or code just to reuse them. Copy the small pieces you need, or move a helper to `Kit/` once two stories truly share it (the README's rule).
- **2D on particles:** `system.shownPoint(_:)`. Fade overlays in once the layout has arrived (`network.formed === layout && split >= 1`).
- **Transitions and timelines:** `.none` between steps that continue the same object, `.fade` otherwise. `loop:` for timelines that replay (read `frame.stepTime`, `loopCount`).
- **Gestures:** `frame.nextStep()` for a gesture that ends a phase, `Grip` for acting on an object, `Actionable` with Space for pointing at items.

## Check it: render offscreen, then build

Rendering lets you see the scene before the user does. Use it to ask design questions, after you've built a full version of the scene:
- Does the idea read?
- Is the subject the clearest thing?
- Are the numbers legible and correct?
- Does the motion go from where things come from to where they go?
- Is anything cut off, washed out or muddy?

Fix what you find, then render again.

`scripts/render_story.sh` (in this skill's folder) compiles the app's stage code with a small driver and renders steps to PNGs, with no camera, no models and no window. It walks the story from step 1 the way the stage does, so particles arrive at your step as they would live. Run it from the repo root or a worktree of it:

```bash
.claude/skills/story-scenes/scripts/render_story.sh <out dir> <story id> [--black] [--background img.jpg] [--dwell 2.5] STEP@T[,T...] ...
# the inference loop at three moments, and the conclusion settled
.claude/skills/story-scenes/scripts/render_story.sh "$SCRATCH/shots" nn-explained --black 12@1,4.5,8.3 29@3
# a branch's step: S.B.N (step 13, branch 2, its step 1)
.claude/skills/story-scenes/scripts/render_story.sh "$SCRATCH/shots" nn-explained --black 13.2.1@2
```

- **Steps are numbered as in the panel, from 1.** Write shots to your scratch folder, and read the PNGs as images.
- **Batch your shots:** each render rebuilds the renderer after a source change (about 35 s), so ask for all the moments you need in one run. It reports `prepare`'s time, longest stall and memory.
- **Black or picture:** `--black` is the hidden-camera stage. `--background` stands in for the camera image.
- **What it can't show:**
  - gestures and pointing, so a phase waiting on a fist won't advance;
  - live model outputs;
  - the 3D layer;
  - the app's fonts.

  Colours come out a little lighter than in the app.
- **If it fails to build** after app changes, a new file probably only works in the app shell. Add it to `skip` in the script.

Then build the app with `scripts/build.sh`, which sets `DEVELOPER_DIR` itself, so the user can look live.

## Traps

When something on stage behaves oddly (it lingers, never moves, renders black, appears late), or before changing a gesture threshold, read `reference/pitfalls.md`.

- **Additive light:** many particles at one spot, or copies leaving one place together, saturate to white or flare. Fix that element with lower density or a colour that sums right, travel unlit and light up on arrival (`arrivedColors`), or dim only the travelling copies. Black particles are invisible and free to move.
- **Budget:** about 120,000 particles in all. N copies × M particles must fit (`NeuralNetwork.particles`).
- **Inserting a step between two that glide into each other** (the later one `splitsFrom` the earlier) breaks the glide the later one expects from its `splitsFrom`. Give the later step a way back (a prelude from your step), and check that jumping to it from the panel still looks right.
- **Styling stays in the story.** Looks the user asks for in a story stay in that story: story-level constants like `NNColors`, or parameters. Don't change `Theme`, the decoders or shared effects in a way that changes other demos. Live steps on the camera use the app's default look unless asked.
- **Name your geometry** on the layout (`pictureCorners`, `brace`), not by convention ("the last two outline points") or in globals.
- **Layouts must be complete when their step starts**, since `NetworkEffect.init` reads their headers, arrows and outline. Don't build them on a background thread.
- **Sizes:** multiply by `frame.stage.unit` (the stage is 1280 × 720 at unit 1), and keep labels off the edges. Use `set(_:_:)` for SpriteKit properties set every frame.

## Working with this user

- **They react to what they see,** often in short messages with a screenshot. When they ask for a change to an existing scene, make that change, render it, and say what they'll see.
- **When they push back:**
  - "choose one": keep one of two things you added;
  - "don't like it, reset": restore the files to the last commit and remove new ones.

  Otherwise, design freely and richly as above.
- **Use their wording** in titles and captions ("7 tasks", "YOLO" in titles).
- **Commits:** only when asked, straight on `main`, push only when asked. Never commit `optimizations.md` or other local notes.
- **Don't quit or relaunch their running app.** Build, and tell them to relaunch.

## Before you report

- [ ] Each step has one idea, shown working with real values, paced for narration, with its subject the clearest thing.
- [ ] Rendered offscreen at the moments that matter, looked at, and fixed what read badly.
- [ ] `scripts/build.sh` succeeds. A new story is in `Story.all`, each step has a caption, and heavy state goes through `prepare`.
- [ ] Styling stayed in the story. `Stories/README.md` mentions new patterns or options.
- [ ] The report says what the scene shows, what was checked offscreen, what needs a live look (colours over the camera, timing, gestures), and that nothing is committed.
