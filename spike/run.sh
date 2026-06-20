#!/bin/bash
# Run the Phase 0 spike. Frames land in ./frames, full log in ./spike.log
# Run from the spike/ directory. Builds first if needed.
set -uo pipefail
cd "$(dirname "$0")"

BIN="build/OpenXWebcamSpike.app/Contents/MacOS/OpenXWebcamSpike"
[ -x "$BIN" ] || ./build.sh

echo "Running spike (also logging to spike.log)..."
echo "If macOS prompts for camera access, click Allow."
echo
# Run the binary directly (keeps .app bundle identity for TCC) and tee output.
"$BIN" 2>&1 | tee spike.log
echo
echo "Saved frames:"
ls -la frames/*.jpg 2>/dev/null | tail -5 || echo "  (no frames captured)"
