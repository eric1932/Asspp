#!/bin/bash
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
    echo "SAP cross-compilation runs in CI only; no local resources were downloaded." >&2
    exit 1
fi
runtime_directory="${1:?Provide the prepared runtime directory}"
runtime_scripts="$(cd "$(dirname "$0")" && pwd)"
repository="$(cd "$runtime_scripts/../.." && pwd)"
unicorn_sources="$runtime_directory/unicorn/unicorn-engine-sys-tci"
python3 "$runtime_scripts/prepare_static.py" "$runtime_directory"
mkdir -p "$runtime_directory/slices/include"
cp "$runtime_scripts/ApplePackageSAP.h" "$runtime_directory/slices/include/"
cat > "$runtime_directory/slices/include/module.modulemap" <<'MODULE'
module CApplePackageSAP {
    header "ApplePackageSAP.h"
    export *
}
MODULE

build_slice() {
    local sdk="$1" arch="$2" goos="$3" goarch="$4" triple="$5"
    local slice="$runtime_directory/slices/$sdk-$arch"
    local sysroot
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    local options=()
    if [[ "$sdk" != macosx ]]; then options+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0); else options+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0); fi
    cmake -S "$unicorn_sources" -B "$slice/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_C_COMPILER="$(xcrun --sdk "$sdk" --find clang)" \
        -DCMAKE_C_COMPILER_TARGET="$triple" -DCMAKE_SYSTEM_PROCESSOR="$arch" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DUNICORN_INTERPRETER=ON -DUNICORN_ARCH=x86 -DUNICORN_BUILD_TESTS=OFF \
        -DUNICORN_INSTALL=OFF -DBUILD_SHARED_LIBS=OFF "${options[@]}"
    python3 - "$slice/build/config-host.h" <<'PY'
from pathlib import Path
import sys
if '#define CONFIG_TCG_INTERPRETER 1' not in Path(sys.argv[1]).read_text():
    raise SystemExit('Refusing a runtime with executable code generation')
PY
    cmake --build "$slice/build" --parallel 3
    (
        cd "$runtime_directory/ipatool"
        export CGO_ENABLED=1 GOOS="$goos" GOARCH="$goarch"
        export CC="$(xcrun --sdk "$sdk" --find clang)"
        export CGO_CFLAGS="-target $triple -isysroot $sysroot -I$unicorn_sources/include"
        export CGO_LDFLAGS="-target $triple -isysroot $sysroot $slice/build/libunicorn.a -lm -lpthread"
        go build -trimpath -ldflags='-s -w' -buildmode=c-archive -o "$slice/bridge.a" ./internal/assppbridge
    )
    xcrun libtool -static -o "$slice/libApplePackageSAP.a" "$slice/bridge.a" "$slice/build/libunicorn.a"
}

build_slice macosx arm64 darwin arm64 arm64-apple-macos11
build_slice macosx x86_64 darwin amd64 x86_64-apple-macos11
build_slice iphoneos arm64 ios arm64 arm64-apple-ios15
build_slice iphonesimulator arm64 ios arm64 arm64-apple-ios15-simulator
build_slice iphonesimulator x86_64 ios amd64 x86_64-apple-ios15-simulator
mkdir -p "$runtime_directory/slices/macos" "$runtime_directory/slices/simulator"
xcrun lipo -create "$runtime_directory/slices/macosx-arm64/libApplePackageSAP.a" "$runtime_directory/slices/macosx-x86_64/libApplePackageSAP.a" -output "$runtime_directory/slices/macos/libApplePackageSAP.a"
xcrun lipo -create "$runtime_directory/slices/iphonesimulator-arm64/libApplePackageSAP.a" "$runtime_directory/slices/iphonesimulator-x86_64/libApplePackageSAP.a" -output "$runtime_directory/slices/simulator/libApplePackageSAP.a"
artifact_directory="$repository/Packages/ApplePackage/Artifacts"
mkdir -p "$artifact_directory/NOTICES"
xcodebuild -create-xcframework \
    -library "$runtime_directory/slices/macos/libApplePackageSAP.a" -headers "$runtime_directory/slices/include" \
    -library "$runtime_directory/slices/iphoneos-arm64/libApplePackageSAP.a" -headers "$runtime_directory/slices/include" \
    -library "$runtime_directory/slices/simulator/libApplePackageSAP.a" -headers "$runtime_directory/slices/include" \
    -output "$artifact_directory/ApplePackageSAP.xcframework" | xcbeautify
cp "$runtime_directory/ipatool/LICENSE" "$artifact_directory/NOTICES/ipatool-LICENSE"
cp "$unicorn_sources/COPYING" "$artifact_directory/NOTICES/unicorn-COPYING"
cp "$runtime_scripts/README.md" "$artifact_directory/NOTICES/BUILD-SOURCES.md"
