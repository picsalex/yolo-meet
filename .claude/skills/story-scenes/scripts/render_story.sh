#!/bin/zsh
# Renders steps of a yolo-meet story offscreen, to PNGs: see RenderStory.swift for what it does and doesn't do.
#
#   render_story.sh <out dir> <story id> [--black] [--size WxH] [--background image] [--dwell s] STEP@T[,T...]...
#
# e.g. render_story.sh /tmp/shots nn-explained --black 12@1,4.5,8.3 29@3 (run it from the repo or a worktree of it)
# It copies the app's sources (all of YoloMeetCore and PenLink, and YoloMeet's Render and Stories, without the app
# shell and the live stage view) into a build folder, drops the module imports so they compile as one program with
# RenderStory.swift, and builds it optimized (about a minute the first time; again only when sources change).
set -euo pipefail
here=${0:A:h}
# The checkout it's run from (a worktree renders its own sources), else the one holding this script.
repo=$(git rev-parse --show-toplevel 2>/dev/null || echo ${here:h:h:h:h})
[[ -d $repo/Sources/YoloMeet/Stories ]] || repo=${here:h:h:h:h}
build=$repo/.build/story-render
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

src=$build/src
mkdir -p $src
sources=(
  $repo/Sources/YoloMeetCore/**/*.swift(N)
  $repo/Sources/PenLink/**/*.swift(N)
  $repo/Sources/YoloMeet/Render/**/*.swift(N)
  $repo/Sources/YoloMeet/Stories/**/*.swift(N)
)
# The live stage and what only it uses (the app model, the pen, stats): the harness stands in for them.
skip=(StageView.swift Drawing.swift StatsEffect.swift StagePicture.swift)
# The stories' assets, where `Story.asset` looks for them from the copied sources.
ln -sfn $repo/Sources/YoloMeet/Stories/Assets $src/Assets
stamp=$build/stamp
fresh=1
for f in $sources $here/RenderStory.swift; do
  [[ -f $stamp && $f -ot $stamp ]] || fresh=0
done
if (( ! fresh )) || [[ ! -x $build/render ]]; then
  rm -f $src/*.swift(N)
  for f in $sources; do
    name=${f:t}
    (( ${skip[(Ie)$name]} )) && continue
    # Same file name in two folders: keep both.
    target=$src/$name
    [[ -e $target ]] && target=$src/${f:h:t}-$name
    sed -E '/^(@preconcurrency )?import (YoloMeetCore|PenLink)$/d' $f > $target
  done
  cp $here/RenderStory.swift $src/main.swift
  echo "building the story renderer…" >&2
  swiftc -O -swift-version 6 -default-isolation MainActor -module-name YoloMeet -o $build/render $src/*.swift
  touch $stamp
fi
exec $build/render "$@"
