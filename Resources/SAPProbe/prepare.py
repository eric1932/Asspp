#!/usr/bin/env python3
"""Prepare pinned sources in CI only; never install anything on the host."""

import io
import os
from pathlib import Path
import shutil
import sys
import tarfile
import urllib.request


UNICORN_REVISION = "6d0794492de065cdf7e05d7658b4c1b157a34062"
UNICORN_BASE_REVISION = "8028ec436f2d9376525352dd38ed9ed6b9f6be10"
IPATOOL_REVISION = "d5d0b56faf64e3fdef885d49e7928b390aadb6c7"


def fetch_source(repository, revision, destination):
    if destination.exists():
        raise RuntimeError(f"Refusing to overwrite {destination}")
    request = urllib.request.Request(
        f"https://codeload.github.com/{repository}/tar.gz/{revision}",
        headers={"User-Agent": "Asspp-SAP-Probe"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        archive = response.read(64 * 1024 * 1024 + 1)
    if len(archive) > 64 * 1024 * 1024:
        raise RuntimeError("Source archive exceeds 64 MiB")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as source:
        total = 0
        for member in source.getmembers():
            relative = Path(*Path(member.name).parts[1:])
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError("Unsafe archive path")
            target = destination / relative
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                total += member.size
                if total > 256 * 1024 * 1024:
                    raise RuntimeError("Expanded source archive exceeds 256 MiB")
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as content, target.open("wb") as output:
                    shutil.copyfileobj(content, output)
                target.chmod(member.mode & 0o777)
            else:
                raise RuntimeError(f"Unsupported archive member: {member.name}")


def patch_loader(reference):
    # Probe-only replacement. A missing explicit interpreter path is fatal;
    # the upstream downloader must never substitute a stock JIT runtime.
    loader = reference / "internal/sap/unicorn/library_unix.go"
    original = loader.read_text()
    if "paths, err := cachedRuntimePaths(ctx)" not in original:
        raise RuntimeError("Pinned ipatool library loader does not match")
    loader.write_text('''//go:build darwin || linux

package unicorn

import (
    "context"
    "fmt"
    "os"
    "path/filepath"

    "github.com/ebitengine/purego"
)

func openLibrary(ctx context.Context) (library, error) {
    if err := ctx.Err(); err != nil { return library{}, err }
    path := os.Getenv("ASSPP_SAP_UNICORN_LIBRARY")
    if !filepath.IsAbs(path) {
        return library{}, fmt.Errorf("explicit absolute interpreter library path is required")
    }
    handle, err := purego.Dlopen(path, purego.RTLD_NOW|purego.RTLD_LOCAL)
    if err != nil { return library{}, fmt.Errorf("load probe interpreter: %w", err) }
    return library{handle: handle, close: func() error { return purego.Dlclose(handle) }}, nil
}
''')


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("This download/build preparation is CI-only; no local resources were downloaded.")
    root = Path(sys.argv[1]).resolve()
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve()
    if root == runner_temp or runner_temp not in root.parents:
        raise SystemExit("Probe output must be a child of RUNNER_TEMP")
    root.mkdir(parents=True, exist_ok=False)
    fetch_source("1rhino2/unicorn-tci", UNICORN_REVISION, root / "unicorn")
    # The TCI snapshot omits qemu/target (its Rust .gitignore matches target/).
    # Restore only the x86 guest from the exact 2.1.4 base, keeping all TCI changes.
    fetch_source("unicorn-engine/unicorn", UNICORN_BASE_REVISION, root / "unicorn-base")
    shutil.copytree(
        root / "unicorn-base/qemu/target/i386",
        root / "unicorn/unicorn-engine-sys-tci/qemu/target/i386",
    )
    fetch_source("majd/ipatool", IPATOOL_REVISION, root / "ipatool")
    patch_loader(root / "ipatool")
    shutil.copyfile(
        Path(__file__).with_name("authentication_test.go"),
        root / "ipatool/internal/sap/asspp_authentication_test.go",
    )
    print(f"Prepared Unicorn {UNICORN_REVISION} and ipatool {IPATOOL_REVISION}")


if __name__ == "__main__":
    main()
