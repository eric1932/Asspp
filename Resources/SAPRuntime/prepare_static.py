#!/usr/bin/env python3
"""Adapt the pinned, validated reference to a static C ABI in the CI checkout."""

import os
from pathlib import Path
import re
import shutil
import sys


def replace_once(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise RuntimeError(f"Pinned source did not match expected patch: {path.name}")
    path.write_text(source.replace(old, new, 1))


def prepare(root):
    reference = root / "ipatool"
    wrapper = Path(__file__).parent
    package = reference / "internal/sap/unicorn"
    retained = {"engine.go", "hook.go", "library.go", "engine_config_default.go"}
    for file in package.glob("*.go"):
        if file.name not in retained:
            file.unlink()
    engine = package / "engine.go"
    replace_once(engine, '\n\t"github.com/ebitengine/purego"\n', "\n")
    source = engine.read_text()
    source, count = re.subn(r"func \(e \*Engine\) register\(handle uintptr\) \{.*?\n\}\n", "", source, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError("Pinned engine register function did not match")
    engine.write_text(source)
    hook = package / "hook.go"
    replace_once(hook, '\n\t"github.com/ebitengine/purego"\n', "\n")
    source, count = re.subn(r"codeHookTrampoline = purego.NewCallback\(func\(.*?\n\t\}\)", "codeHookTrampoline uintptr = 0", hook.read_text(), count=1, flags=re.S)
    if count != 1:
        raise RuntimeError("Pinned hook callback did not match")
    hook.write_text(source)
    (package / "library_static.go").write_text('''package unicorn
import "context"
func openLibrary(ctx context.Context) (library, error) {
    if err := ctx.Err(); err != nil { return library{}, err }
    return library{handle: 1, close: func() error { return nil }}, nil
}
''')
    shutil.copyfile(wrapper / "static_api.go", package / "static_api.go")
    assets = reference / "internal/sap/assets/assets.go"
    replace_once(assets, "\tif bundle, err := readCache(directory); err == nil {", """    return LoadFromDirectory(ctx, directory)
}

func LoadFromDirectory(ctx context.Context, directory string) (Bundle, error) {
    if err := ctx.Err(); err != nil { return Bundle{}, err }
    if bundle, err := readCache(directory); err == nil {""")
    shutil.copyfile(wrapper / "bundled_assets.go", assets.with_name("asspp_bundled.go"))
    shutil.copyfile(wrapper / "bundled_assets_test.go", assets.with_name("asspp_bundled_test.go"))
    machine = reference / "internal/sap/machine/machine.go"
    with machine.open("a") as output:
        output.write("\n// Stop interrupts active emulation without tearing down its state.\nfunc (m *Machine) Stop() error { return m.engine.Stop() }\n")
    bridge = reference / "internal/assppbridge"
    bridge.mkdir()
    shutil.copyfile(wrapper / "bridge.go", bridge / "main.go")


if __name__ == "__main__":
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("Static runtime preparation is CI-only")
    prepare(Path(sys.argv[1]).resolve())
