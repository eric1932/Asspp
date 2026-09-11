"""CI-only regression: raw guest code changes on re-sign; its ZIP data does not.

Uses Apple's codesign on disposable copies. This covers recursive re-signing,
not AllinSign itself; the delivered IPA remains unsigned.
"""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from sap_assets import verify_archive, verify_directory, verify_ipa


def digest(path):
    return hashlib.sha256(path.read_bytes()).digest()


def resign(path):
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", str(path)], check=True)


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("Re-signing regression is CI-only; no local files were modified.")
    ipa, source = map(Path, sys.argv[1:])
    verify_ipa(ipa, bundled=True)
    verify_directory(source)
    with tempfile.TemporaryDirectory(prefix="asspp-resign-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        root = Path(temporary)
        raw = root / "CommerceKit"
        shutil.copyfile(source / "CommerceKit", raw)
        original = digest(raw)
        resign(raw)
        if digest(raw) == original:
            raise ValueError("Raw CommerceKit fixture did not change on re-signing")
        print("Confirmed: re-signing raw CommerceKit changes its pinned bytes", flush=True)

        subprocess.run(["ditto", "-x", "-k", str(ipa), str(root)], check=True)
        app = root / "Payload/Asspp.app"
        resources = list(app.rglob("SAPAssets.zip"))
        if len(resources) != 1:
            raise ValueError("Expected one SAP data archive in the built app")
        resource = resources[0]
        original = digest(resource)
        resign(app)
        if digest(resource) != original:
            raise ValueError("Re-signing the app changed its SAP data archive")
        verify_archive(resource)
        print("Re-signing regression passed: all four original SAP files survive app re-signing", flush=True)


if __name__ == "__main__":
    main()
