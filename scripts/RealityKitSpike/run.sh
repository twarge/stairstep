#!/bin/sh
# RealityKit port feasibility rig. Renders offscreen and pixel-verifies:
#   A  RealityRenderer baseline (the QuickLook path)
#   B  section clip via discard_fragment in a CustomMaterial surface shader
#   C  screen-space hatch, zoom-invariant stripe period
#   D  wireframe via LowLevelMesh .line topology
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path)
xcrun -sdk macosx metal spike.metal -o spike.metallib
swiftc spike.swift -o spike -parse-as-library -sdk "$SDK" -target arm64-apple-macos26.0 -swift-version 6
./spike
