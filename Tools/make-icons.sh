#!/bin/zsh
# Draws the app icon and writes Resources/Tandem.icns.
set -e
cd "${0:A:h}/.."
work=$(mktemp -d)
swiftc -O Tools/MakeIcons/main.swift -o $work/make-icons
$work/make-icons $work
for name in "Tandem"; do
  set=$work/$name.iconset
  mkdir -p $set
  for s in 16 32 128 256 512; do
    sips -z $s $s "$work/$name.png" --out "$set/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$work/$name.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns $set -o "Resources/$name.icns"
  cp "$work/$name.png" "Resources/$name.png"
done
rm -rf $work
ls Resources
