#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# The local Command Line Tools install has a newer default SDK than its Swift
# compiler supports. A full Xcode installation can use its selected SDK.
if ! xcodebuild -version >/dev/null 2>&1 &&
   [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
  export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/displayheight-clang-cache"
fi

bundle="$PWD/.build/DisplayHeight.app"
min_os="13.0"
target="$(uname -m)-apple-macosx${min_os}"
mkdir -p "$bundle/Contents/MacOS"
if swift build --disable-sandbox -c release --product DisplayHeight; then
  binary="$(swift build --disable-sandbox -c release --show-bin-path)/DisplayHeight"
  rm -f "$bundle/Contents/Frameworks/libDisplayHeightCore.dylib"
else
  echo "SwiftPM is unavailable; compiling with swiftc." >&2
  manual="$PWD/.build/manual"
  mkdir -p "$manual" "$bundle/Contents/Frameworks"
  swiftc -swift-version 6 -target "$target" -O \
    -parse-as-library -emit-module -emit-library \
    -module-name DisplayHeightCore \
    -Xlinker -install_name -Xlinker '@rpath/libDisplayHeightCore.dylib' \
    Sources/DisplayHeightCore/Layout.swift \
    -o "$manual/libDisplayHeightCore.dylib"
  swiftc -swift-version 6 -target "$target" -O \
    -I "$manual" -L "$manual" -lDisplayHeightCore \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    Sources/DisplayHeight/*.swift -o "$manual/DisplayHeight"
  cp "$manual/libDisplayHeightCore.dylib" "$bundle/Contents/Frameworks/"
  codesign --force --sign - --timestamp=none \
    "$bundle/Contents/Frameworks/libDisplayHeightCore.dylib"
  binary="$manual/DisplayHeight"
fi
cp "$binary" "$bundle/Contents/MacOS/DisplayHeight"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>ja</string>
<key>CFBundleExecutable</key><string>DisplayHeight</string>
<key>CFBundleIdentifier</key><string>dev.local.DisplayHeight</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>DisplayHeight</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>${min_os}</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# SwiftPM signs the standalone executable. Re-sign the finished bundle so
# macOS validates its Info.plist and binary together.
codesign --force --sign - --timestamp=none "$bundle"

echo "$bundle"
