#!/bin/zsh
# Usage: Tools/bc7check.sh <image> [decoded.png]
set -e
cd "${0:A:h}/.."
mkdir -p build
swiftc -O -target arm64-apple-macos14.0 \
  Sender/BC7Encoder.swift Tools/BC7Check/main.swift -o build/bc7check 2>&1 | grep -v warning || true
build/bc7check "$@"
