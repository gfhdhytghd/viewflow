#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
# Unsigned build proves SDK compatibility only; it cannot be activated as-is.
xcodebuild -project VFTrackpadProbe.xcodeproj -target VFTrackpadProbe \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
