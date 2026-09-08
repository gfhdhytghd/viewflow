#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
# Account, capabilities and automatic profiles are configured through Xcode UI.
# This build uses those existing profiles; it does not contact the developer portal.
xcodebuild -project VFTrackpadProbe.xcodeproj -scheme VFTrackpadProbe \
  -configuration Debug -destination 'platform=macOS,variant=DriverKit,arch=arm64' \
  -derivedDataPath build-signed build
python3 verify-profile-device.py build-signed/Build/Products/Debug-driverkit/org.viewflow.trackpad-probe.dext/embedded.provisionprofile
xcodebuild -project VFTrackpadHost/VFTrackpadHost.xcodeproj -scheme VFTrackpadHost \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build-host build
codesign --verify --deep --strict --verbose=2 build-host/Build/Products/Debug/VFTrackpadHost.app
codesign --verify --strict --verbose=2 build-host/Build/Products/Debug/VFTrackpadHost.app/Contents/Library/SystemExtensions/org.viewflow.trackpad-probe.dext
python3 verify-profile-device.py build-host/Build/Products/Debug/VFTrackpadHost.app/Contents/embedded.provisionprofile build-host/Build/Products/Debug/VFTrackpadHost.app/Contents/Library/SystemExtensions/org.viewflow.trackpad-probe.dext/embedded.provisionprofile
