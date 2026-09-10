#!/bin/bash
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
    echo "Static SAP runtime builds run in CI only." >&2
    exit 1
fi
runtime_directory="${1:?Provide the prepared probe directory}"
runtime_scripts="$(cd "$(dirname "$0")" && pwd)"
python3 "$runtime_scripts/prepare_static.py" "$runtime_directory"

export CGO_ENABLED=1
export CGO_CFLAGS="-I$runtime_directory/unicorn/unicorn-engine-sys-tci/include"
export CGO_LDFLAGS="$runtime_directory/build/libunicorn.a -lm -lpthread"
cd "$runtime_directory/ipatool"
go test -count=1 -timeout=10m ./internal/sap/machimage ./internal/sap/cpio ./internal/sap/machine
mkdir -p "$runtime_directory/static/include"
go build -buildmode=c-archive -o "$runtime_directory/static/libApplePackageSAP.a" ./internal/assppbridge
cp "$runtime_scripts/ApplePackageSAP.h" "$runtime_directory/static/include/"
cat > "$runtime_directory/static/include/module.modulemap" <<'EOF'
module CApplePackageSAP {
    header "ApplePackageSAP.h"
    export *
}
EOF
xcrun swiftc -I "$runtime_directory/static/include" \
    "$runtime_scripts/SwiftLifecycleProbe.swift" \
    "$runtime_directory/static/libApplePackageSAP.a" "$runtime_directory/build/libunicorn.a" \
    -framework CoreFoundation -lresolv -o "$runtime_directory/static/lifecycle-probe"
"$runtime_directory/static/lifecycle-probe"

if [[ "${ASSPP_SAP_LIVE_PROBE:-}" == 1 ]]; then
    go test -v -count=1 -timeout=15m ./internal/sap -run '^TestAssppSignedAuthentication$'
fi
