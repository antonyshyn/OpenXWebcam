#!/bin/bash
# Build the Phase 1 raw-USB spike.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
echo "Compiling rawusb ..."
xcrun clang -fobjc-arc -O2 -Wall \
	-framework Foundation -framework IOKit -framework CoreFoundation -framework IOUSBHost \
	-o build/rawusb \
	rawusb.m

echo "Ad-hoc signing..."
codesign --force --sign - build/rawusb

echo "Built: build/rawusb"
