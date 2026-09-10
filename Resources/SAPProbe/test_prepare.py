import io
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import prepare


def archive_bytes(name, body=b"source", kind=tarfile.REGTYPE):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        member = tarfile.TarInfo(name)
        member.type = kind
        member.size = len(body) if kind == tarfile.REGTYPE else 0
        archive.addfile(member, io.BytesIO(body) if member.isfile() else None)
    return buffer.getvalue()


class PreparationTests(unittest.TestCase):
    def test_local_preparation_never_downloads(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}), patch.object(prepare, "fetch_source") as fetch:
            with self.assertRaisesRegex(SystemExit, "CI-only"):
                prepare.main()
            fetch.assert_not_called()

    def test_output_must_be_inside_runner_temp(self):
        with tempfile.TemporaryDirectory() as temporary:
            for target in [temporary, str(Path(temporary).parent / "outside-probe")]:
                with self.subTest(target=target), patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": temporary}):
                    with patch("sys.argv", ["prepare.py", target]), patch.object(prepare, "fetch_source") as fetch:
                        with self.assertRaisesRegex(SystemExit, "child of RUNNER_TEMP"):
                            prepare.main()
                        fetch.assert_not_called()

    def test_archive_paths_cannot_escape_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "source"
            with patch("urllib.request.urlopen", return_value=io.BytesIO(archive_bytes("root/../../escape"))):
                with self.assertRaisesRegex(RuntimeError, "Unsafe archive path"):
                    prepare.fetch_source("owner/repo", "revision", destination)

    def test_archive_links_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch("urllib.request.urlopen", return_value=io.BytesIO(archive_bytes("root/link", kind=tarfile.SYMTYPE))):
                with self.assertRaisesRegex(RuntimeError, "Unsupported archive member"):
                    prepare.fetch_source("owner/repo", "revision", Path(temporary) / "source")

    def test_archive_extraction_strips_only_repository_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "source"
            with patch("urllib.request.urlopen", return_value=io.BytesIO(archive_bytes("root/nested/source.c"))):
                prepare.fetch_source("owner/repo", "revision", destination)
            self.assertEqual((destination / "nested/source.c").read_bytes(), b"source")

    def test_existing_directory_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary, patch("urllib.request.urlopen") as fetch:
            with self.assertRaisesRegex(RuntimeError, "Refusing to overwrite"):
                prepare.fetch_source("owner/repo", "revision", Path(temporary))
            fetch.assert_not_called()

    def test_loader_patch_requires_expected_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            reference = Path(temporary)
            loader = reference / "internal/sap/unicorn/library_unix.go"
            loader.parent.mkdir(parents=True)
            loader.write_text("unexpected upstream code")
            with self.assertRaisesRegex(RuntimeError, "does not match"):
                prepare.patch_loader(reference)
            self.assertEqual(loader.read_text(), "unexpected upstream code")


if __name__ == "__main__":
    unittest.main()
