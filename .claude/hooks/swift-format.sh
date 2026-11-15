#!/bin/bash
# PostToolUse hook: after Claude edits or writes a .swift file, format it with swift-format
# (bundled with Xcode, configured by .swift-format at the repo root), then lint it.
# Lint warnings go back to Claude (exit 2) so it fixes them; everything else exits 0.

file=$(jq -r '.tool_input.file_path // empty')
[[ "$file" == *.swift && -f "$file" ]] || exit 0

# The Command Line Tools may lack swift-format; prefer Xcode's toolchain (see CLAUDE.md › Commands).
[[ -z "$DEVELOPER_DIR" && -d /Applications/Xcode.app ]] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift_format=$(xcrun --find swift-format 2>/dev/null) || exit 0

# A file mid-edit may not parse yet: swift-format then refuses it, and the compiler will report it anyway.
"$swift_format" format --in-place "$file" 2>/dev/null || exit 0

warnings=$("$swift_format" lint "$file" 2>&1)
if [[ -n "$warnings" ]]; then
    echo "swift-format formatted $file; these lint warnings need a fix by hand:" >&2
    echo "$warnings" >&2
    exit 2
fi
exit 0
