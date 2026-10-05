#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if ! xcodebuild -version >/dev/null 2>&1 &&
   [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
  export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/displayheight-clang-cache"
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/displayheight-checks.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

swiftc -swift-version 6 -parse-as-library -emit-module -emit-library \
  -module-name DisplayHeightCore \
  -Xlinker -install_name -Xlinker '@rpath/libDisplayHeightCore.dylib' \
  Sources/DisplayHeightCore/Layout.swift -o "$scratch/libDisplayHeightCore.dylib"

if ! swift run --disable-sandbox LayoutChecks; then
  echo "SwiftPM is unavailable; running checks with swiftc." >&2
  swiftc -swift-version 6 -I "$scratch" -L "$scratch" -lDisplayHeightCore \
    -Xlinker -rpath -Xlinker "$scratch" \
    Checks/main.swift -o "$scratch/checks"
  "$scratch/checks"
fi

swiftc -swift-version 6 -I "$scratch" -L "$scratch" -lDisplayHeightCore \
  -Xlinker -rpath -Xlinker "$scratch" \
  Sources/DisplayHeight/ProfileStore.swift CheckSupport/ProfileStoreChecks.swift \
  -o "$scratch/profile-checks"
"$scratch/profile-checks"

swiftc -swift-version 6 Sources/DisplayHeight/LaunchContext.swift \
  CheckSupport/LaunchContextChecks.swift -o "$scratch/launch-checks"
"$scratch/launch-checks"
