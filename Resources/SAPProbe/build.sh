#!/bin/bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
    echo "This interpreter build is CI-only; nothing was built locally." >&2
    exit 1
fi

probe_directory="${1:?Provide the prepared probe directory}"
probe_sources="$probe_directory/unicorn/unicorn-engine-sys-tci"
probe_build="$probe_directory/build"
probe_scripts="$(cd "$(dirname "$0")" && pwd)"

cmake -S "$probe_sources" -B "$probe_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
    -DUNICORN_INTERPRETER=ON \
    -DUNICORN_ARCH=x86 \
    -DUNICORN_BUILD_TESTS=OFF \
    -DUNICORN_INSTALL=OFF \
    -DBUILD_SHARED_LIBS=ON

python3 - "$probe_build" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
configuration = (root / 'config-host.h').read_text()
if '#define CONFIG_TCG_INTERPRETER 1' not in configuration:
    raise SystemExit('Refusing to run: CONFIG_TCG_INTERPRETER is not enabled')
PY

cmake --build "$probe_build" --parallel 3

python3 - "$probe_build" "$probe_directory/library-path.txt" <<'PY'
from pathlib import Path
import sys
libraries = sorted(Path(sys.argv[1]).rglob('libunicorn.2.dylib'))
if len(libraries) != 1:
    raise SystemExit(f'Expected one interpreter library, found {len(libraries)}')
Path(sys.argv[2]).write_text(str(libraries[0].resolve()) + '\n')
PY

mkdir -p "$probe_directory/CUnicorn"
cat > "$probe_directory/CUnicorn/module.modulemap" <<EOF
module CUnicorn [system] {
    header "$probe_sources/include/unicorn/unicorn.h"
    export *
}
EOF

probe_library="$(cat "$probe_directory/library-path.txt")"
xcrun swiftc -I "$probe_directory/CUnicorn" \
    "$probe_scripts/SwiftBridgeProbe.swift" "$probe_library" \
    -Xlinker -rpath -Xlinker "$(dirname "$probe_library")" \
    -o "$probe_directory/swift-bridge-probe"
"$probe_directory/swift-bridge-probe"
