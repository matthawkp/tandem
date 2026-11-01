#!/bin/zsh
# Builds build/Tandem.app: one universal app for both Macs (extending needs macOS 14+, a display macOS 11+), with its Tandem Camera
# extension. Each Mac picks its role on first launch.
#
# Xcode signs it with the developer account signed in to Xcode. The team ID is in Support/team
# (or TANDEM_TEAM); it's on developer.apple.com → Membership. Development signing only runs on
# Macs registered to that account (developer.apple.com → Devices).
set -euo pipefail
cd "${0:A:h}"

OUT=build
VERSION=1.0
BUILD=$(date +%Y%m%d%H%M)
TEAM=${TANDEM_TEAM:-$(cat Support/team 2>/dev/null || true)}
[[ -n $TEAM ]] || { echo "Put your Apple Developer team ID in Support/team"; exit 1; }
# Your own, registered to your team; com.example.tandem otherwise.
BUNDLE=${TANDEM_BUNDLE_ID:-$(cat Support/bundle-id 2>/dev/null || echo com.example.tandem)}

rm -rf $OUT && mkdir -p $OUT
TANDEM_TEAM=$TEAM TANDEM_BUNDLE_ID=$BUNDLE xcodegen generate --quiet
xcodebuild -project Tandem.xcodeproj -scheme Tandem -configuration Release -derivedDataPath .xcode \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -destination "generic/platform=macOS" -quiet \
  CURRENT_PROJECT_VERSION=$BUILD MARKETING_VERSION=$VERSION build
cp -R .xcode/Build/Products/Release/Tandem.app $OUT/
echo "Done: $OUT/Tandem.app"
