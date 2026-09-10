"""Verify optional Apple resources and the contents of the final IPA, offline."""

import hashlib
from pathlib import Path
import sys
import zipfile

APPLE_UPDATE_URL = "https://swcdn.apple.com/content/downloads/27/34/041-98128-A_SYPWICN3KH/5dqkl4rqgbsr18yzy61yeie9g3cmjc5hiv/OSXUpd10.9.pkg"
FILES = {
    "CommerceKit": (3271840, "b84ff12c21987856c0a17b78f1ad82b73195a6dec5f3b208a17d245555a2c8a2"),
    "CommerceCore": (207744, "c5401e57402230f3c876409d295319ddf1e61287bc882683c5d61277be7bc1f2"),
    "CoreFP": (29014912, "f19141336be4198d0f8991bb00017c915efc7aeaece36c345f7faa1237ea6074"),
    "CoreFP.icxs": (5288352, "473e78af86979f5bd4f6269561caf770b3d16c098d918846eeac8cdd2fe6566a"),
}


def verify_stream(stream, size, digest):
    actual_size = 0
    actual_digest = hashlib.sha256()
    while chunk := stream.read(1024 * 1024):
        actual_size += len(chunk)
        if actual_size > size:
            raise ValueError("SAP resource exceeds its pinned size")
        actual_digest.update(chunk)
    if actual_size != size or actual_digest.hexdigest() != digest:
        raise ValueError("SAP resource does not match its pinned size and SHA-256")


def verify_directory(directory):
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("SAP resource directory is missing or a symlink")
    if {path.name for path in directory.iterdir()} != set(FILES):
        raise ValueError("Unexpected or missing files in the SAP resource directory")
    for name, (size, digest) in FILES.items():
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Invalid SAP resource: {name}")
        with path.open("rb") as stream:
            verify_stream(stream, size, digest)


def verify_ipa(path, bundled):
    with zipfile.ZipFile(path) as archive:
        resources = [entry for entry in archive.infolist() if "/SAPAssets/" in entry.filename and not entry.is_dir()]
        if not bundled:
            if resources:
                raise ValueError("Download-on-demand IPA unexpectedly contains Apple SAP binaries")
            return
        if len(resources) != len(FILES) or {Path(entry.filename).name for entry in resources} != set(FILES):
            raise ValueError("Bundled IPA must contain exactly one complete set of Apple SAP binaries")
        parents = {str(Path(entry.filename).parent) for entry in resources}
        if len(parents) != 1 or not next(iter(parents)).startswith("Payload/Asspp.app/"):
            raise ValueError("SAP resources must be inside the application bundle")
        for entry in resources:
            size, digest = FILES[Path(entry.filename).name]
            if entry.file_size != size:
                raise ValueError("Incorrect SAP resource size in IPA")
            with archive.open(entry) as stream:
                verify_stream(stream, size, digest)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "directory":
        verify_directory(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "ipa" and sys.argv[3] in ("bundled", "download"):
        verify_ipa(sys.argv[2], bundled=sys.argv[3] == "bundled")
    else:
        raise SystemExit("Usage: sap_assets.py directory PATH | ipa PATH bundled|download")
    print("SAP resource verification passed")
