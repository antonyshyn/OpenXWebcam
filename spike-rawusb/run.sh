#!/bin/bash
# Run the Phase 1 raw-USB spike. MUST be root to seize the interface.
# Frames land in ./frames, full log in ./rawusb.log
set -uo pipefail
cd "$(dirname "$0")"

BIN="build/rawusb"
[ -x "$BIN" ] || ./build.sh

if [ "$(id -u)" -ne 0 ]; then
	echo "Re-running under sudo (needed to seize the USB interface from ptpcamerad)..."
	exec sudo "$0" "$@"
fi

echo "Running raw-USB spike as root (also logging to rawusb.log)..."
echo
"$BIN" 2>&1 | tee rawusb.log
echo
echo "Saved frames:"
ls -la frames/*.jpg 2>/dev/null | tail -5 || echo "  (no frames captured)"
