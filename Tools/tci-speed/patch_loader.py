#!/usr/bin/env python3
"""Let ASSPP_UNICORN_LIBRARY override the libunicorn that pinned ipatool loads.

Measurement only: the probe runs the same workload on the stock JIT build and
on an interpreter-only build. The patch refuses to apply if the pinned source
does not match exactly.
"""

from pathlib import Path
import sys


def replace_once(source, old, new, name):
    if source.count(old) != 1:
        raise SystemExit(f"Pinned {name} did not match the expected text")
    return source.replace(old, new, 1)


def main():
    loader = Path(sys.argv[1]) / "internal/sap/unicorn/library_unix.go"
    source = loader.read_text()
    source = replace_once(source, '\t"fmt"\n', '\t"fmt"\n\t"os"\n', "imports")
    source = replace_once(
        source,
        "\tpaths, err := cachedRuntimePaths(ctx)\n",
        "\tif override := os.Getenv(\"ASSPP_UNICORN_LIBRARY\"); override != \"\" {\n"
        "\t\thandle, err := purego.Dlopen(override, purego.RTLD_NOW|purego.RTLD_LOCAL)\n"
        "\t\tif err != nil {\n"
        "\t\t\treturn library{}, fmt.Errorf(\"%s: %w\", override, err)\n"
        "\t\t}\n"
        "\n"
        "\t\treturn library{handle: handle, close: func() error { return purego.Dlclose(handle) }}, nil\n"
        "\t}\n"
        "\n"
        "\tpaths, err := cachedRuntimePaths(ctx)\n",
        "loader",
    )
    loader.write_text(source)


if __name__ == "__main__":
    main()
