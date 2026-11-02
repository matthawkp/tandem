#!/bin/zsh
# Builds a Tandem anyone can install: signed with Developer ID, notarized by Apple, and packed
# in build/Tandem.dmg with a link to Applications.
#
# Once, beforehand, save the notarization password (an app-specific password from
# appleid.apple.com) in the keychain:
#   xcrun notarytool store-credentials tandem --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
set -euo pipefail
cd "${0:A:h}"

PROFILE=tandem
VERSION=1.2.3
BUILD=$(date +%Y%m%d%H%M)
TEAM=${TANDEM_TEAM:-$(cat Support/team 2>/dev/null || true)}
[[ -n $TEAM ]] || { echo "Put your Apple Developer team ID in Support/team"; exit 1; }
# Your own, registered to your team; com.example.tandem otherwise.
BUNDLE=${TANDEM_BUNDLE_ID:-$(cat Support/bundle-id 2>/dev/null || echo com.example.tandem)}
OUT=build/release
mkdir -p build && rm -rf $OUT build/Tandem.dmg && mkdir -p $OUT

notarize() {
  xcrun notarytool submit "$1" --keychain-profile $PROFILE --wait --timeout 30m | tee $OUT/notary.log
  grep -q "status: Accepted" $OUT/notary.log || {
    id=$(awk '/^  id:/ { print $2; exit }' $OUT/notary.log)
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile $PROFILE
    echo "Notarization failed"; exit 1
  }
}

xcrun notarytool history --keychain-profile $PROFILE >/dev/null 2>&1 || {
  echo "No notarization password saved; see the top of release.sh"; exit 1
}

echo "Archiving…"
TANDEM_TEAM=$TEAM TANDEM_BUNDLE_ID=$BUNDLE xcodegen generate --quiet
xcodebuild -project Tandem.xcodeproj -scheme Tandem -configuration Release -derivedDataPath .xcode \
  -archivePath $OUT/Tandem.xcarchive -destination "generic/platform=macOS" -allowProvisioningUpdates -quiet \
  CURRENT_PROJECT_VERSION=$BUILD MARKETING_VERSION=$VERSION archive

echo "Signing with Developer ID…"
cat > $OUT/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath $OUT/Tandem.xcarchive -exportPath $OUT \
  -exportOptionsPlist $OUT/export.plist -allowProvisioningUpdates -quiet

echo "Notarizing the app…"
ditto -c -k --keepParent $OUT/Tandem.app $OUT/Tandem.zip
notarize $OUT/Tandem.zip
xcrun stapler staple $OUT/Tandem.app

echo "Making the disk image…"
mkdir -p $OUT/dmg
cp -R $OUT/Tandem.app $OUT/dmg/
ln -s /Applications $OUT/dmg/Applications
# Built by hand (blank image, copy, compress): hdiutil's -srcfolder shortcut often fails with
# "Resource busy" on recent macOS.
SIZE=$(( $(du -sm $OUT/dmg | cut -f1) + 40 ))
hdiutil create -size ${SIZE}m -fs HFS+ -volname Tandem -ov $OUT/blank.dmg >/dev/null
MOUNT=$(hdiutil attach -nobrowse -noautoopen $OUT/blank.dmg | awk -F'\t' '/\/Volumes\// { print $NF }')
ditto $OUT/dmg "$MOUNT"
hdiutil detach "$MOUNT" -quiet || { sleep 2; hdiutil detach "$MOUNT" -force -quiet; }
hdiutil convert $OUT/blank.dmg -format UDZO -o build/Tandem.dmg -ov >/dev/null
# The disk image is signed and notarized too when a Developer ID certificate is in the keychain
# (Xcode → Settings → Accounts → Manage Certificates). The app inside is notarized either way.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' "/Developer ID Application: .*\\($TEAM\\)/ { print \$2; exit }")
if [[ -n $IDENTITY ]]; then
  codesign --sign "$IDENTITY" --timestamp build/Tandem.dmg
  notarize build/Tandem.dmg
  xcrun stapler staple build/Tandem.dmg
fi

spctl --assess --type execute -v $OUT/Tandem.app
echo "Done: build/Tandem.dmg"
