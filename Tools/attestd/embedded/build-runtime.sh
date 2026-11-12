#!/bin/bash
# Builds AssppAttest.framework for one Apple SDK.
#
# The framework is one dynamic library holding the embedded asspp-attestd (a Go
# c-archive built inside the pinned ipatool tree) and an interpreter-only
# Unicorn with the aarch64 guest. It never maps executable memory, so it runs
# on a stock iPhone. ipatool finds Unicorn through dlsym(RTLD_DEFAULT), which
# sees this library's exported uc_* symbols once the app has loaded it.
#
#   build-runtime.sh <ipatool-dir> <unicorn-source-dir> <out-dir> <sdk> <triple> [version] [ipatool-commit]
#
# <ipatool-dir> must already contain cmd/asspp-attestd. <sdk> is iphoneos or
# iphonesimulator, <triple> for example arm64-apple-ios16.0-simulator.
set -euo pipefail

ipatool="$(cd "$1" && pwd)"
unicorn="$(cd "$2" && pwd)"
mkdir -p "$3"
out="$(cd "$3" && pwd)"
sdk="$4"
triple="$5"
version="${6:-dev}"
commit="${7:-unknown}"
here="$(cd "$(dirname "$0")" && pwd)"

sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
cc="$(xcrun --sdk "$sdk" --find clang)"
work="$out/work"
mkdir -p "$work"

case "$sdk" in
    iphoneos) platform=iPhoneOS ;;
    iphonesimulator) platform=iPhoneSimulator ;;
    *) echo "unsupported sdk: $sdk" >&2; exit 2 ;;
esac

cmake -S "$unicorn" -B "$work/unicorn" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DCMAKE_C_COMPILER="$cc" \
    -DCMAKE_C_COMPILER_TARGET="$triple" \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DUNICORN_INTERPRETER=ON \
    -DUNICORN_ARCH=aarch64 \
    -DUNICORN_BUILD_TESTS=OFF \
    -DUNICORN_INSTALL=OFF \
    -DBUILD_SHARED_LIBS=OFF
grep -q '#define CONFIG_TCG_INTERPRETER 1' "$work/unicorn/config-host.h" || {
    echo "refusing a Unicorn build that generates executable code" >&2
    exit 1
}
cmake --build "$work/unicorn" --parallel 4
test -f "$work/unicorn/libunicorn.a"

(
    cd "$ipatool"
    export CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$cc"
    export CGO_CFLAGS="-target $triple -isysroot $sysroot"
    export CGO_LDFLAGS="-target $triple -isysroot $sysroot"
    go build -trimpath -tags asspp_embedded -buildmode=c-archive \
        -ldflags "-s -w -X main.version=$version -X main.ipatoolCommit=$commit" \
        -o "$work/attestd.a" ./cmd/asspp-attestd
)

framework="$out/AssppAttest.framework"
rm -rf "$framework"
mkdir -p "$framework/Headers" "$framework/Modules"

"$cc" -dynamiclib -target "$triple" -isysroot "$sysroot" \
    -Wl,-force_load,"$work/attestd.a" \
    -Wl,-force_load,"$work/unicorn/libunicorn.a" \
    -framework CoreFoundation -framework Security -lresolv \
    -install_name @rpath/AssppAttest.framework/AssppAttest \
    -o "$framework/AssppAttest"

cp "$here/AssppAttest.h" "$framework/Headers/"
cat > "$framework/Modules/module.modulemap" <<'EOF'
framework module AssppAttest {
    header "AssppAttest.h"
    export *
}
EOF
cat > "$framework/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AssppAttest</string>
    <key>CFBundleIdentifier</key>
    <string>wiki.qaq.asspp.attest</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AssppAttest</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>$platform</string>
    </array>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>16.0</string>
</dict>
</plist>
EOF

# The four entry points and the Unicorn API must be visible to dlsym.
exported="$(nm -gU "$framework/AssppAttest" | awk '{print $NF}')"
for symbol in _asb_configure _asb_call _asb_cancel _asb_free _uc_version _uc_open _uc_emu_start; do
    grep -qx "$symbol" <<<"$exported" || { echo "missing exported symbol: $symbol" >&2; exit 1; }
done

file "$framework/AssppAttest"
ls -l "$framework/AssppAttest"
