#!/bin/bash
# Builds Livewall.app in this folder
set -euo pipefail
cd "$(dirname "$0")"
APP=Livewall.app
# Build and sign outside iCloud Drive: iCloud tags files on the Desktop, which code signing rejects.
STAGE="$(mktemp -d)/Livewall.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
[ -f Resources/AppIcon.icns ] || swift tools/make_icon.swift Resources

# Newest SDK first. The standalone Command Line Tools for some SDKs are missing
# SwiftUI's macro plugin, so fall back to an older SDK when that happens.
SDK_DIR="$(dirname "$(xcrun --show-sdk-path)")"
LOG="$(dirname "$STAGE")/build.log"
built=0
for sdk in $(find "$SDK_DIR" -maxdepth 1 -name 'MacOSX[0-9]*.sdk' -type d | sort -r); do
  if swiftc -sdk "$sdk" -O -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
       Sources/*.swift -o "$STAGE/Contents/MacOS/Livewall" 2> "$LOG"; then
    echo "Compiled with $(basename "$sdk")"
    built=1
    break
  fi
  echo "$(basename "$sdk") didn't work, trying an older SDK…"
done
if [ $built -eq 0 ]; then cat "$LOG"; exit 1; fi

cp Resources/Info.plist "$STAGE/Contents/"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/"
xattr -cr "$STAGE"
codesign --force --sign - "$STAGE"
rm -rf "$APP"
ditto "$STAGE" "$APP"
rm -rf "$(dirname "$STAGE")"
echo "Built $APP"
