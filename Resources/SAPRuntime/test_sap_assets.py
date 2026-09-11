import hashlib
import io
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

import prepare_assets
import sap_assets


class SAPResourceTests(unittest.TestCase):
    def setUp(self):
        self.payload = b"synthetic fixture"
        expected = {"CoreFP": (len(self.payload), hashlib.sha256(self.payload).hexdigest())}
        self.spec = patch.object(sap_assets, "FILES", expected)
        self.spec.start()
        self.addCleanup(self.spec.stop)

    def archive(self, entries=None):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data in entries if entries is not None else [("CoreFP", self.payload)]:
                archive.writestr(name, data)
        return buffer.getvalue()

    def test_preparation_refuses_local_download(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}), patch.object(prepare_assets, "fetch_source") as fetch:
            with self.assertRaisesRegex(SystemExit, "CI-only"):
                prepare_assets.main()
            fetch.assert_not_called()

    def test_directory_checks_corruption_missing_and_unexpected_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "CoreFP"
            path.write_bytes(self.payload)
            sap_assets.verify_directory(directory)
            path.write_bytes(b"X" * len(self.payload))
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                sap_assets.verify_directory(directory)
            path.unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                sap_assets.verify_directory(directory)
            path.write_bytes(self.payload)
            (Path(directory) / "unexpected").write_bytes(b"")
            with self.assertRaisesRegex(ValueError, "Unexpected"):
                sap_assets.verify_directory(directory)

    def test_archive_writer_keeps_exact_original_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.mkdir()
            (source / "CoreFP").write_bytes(self.payload)
            destination = Path(directory) / "bundle/SAPAssets.zip"
            sap_assets.write_archive(source, destination)
            sap_assets.verify_archive(destination)
            with zipfile.ZipFile(destination) as archive:
                self.assertEqual(archive.namelist(), ["CoreFP"])
                self.assertEqual(archive.read("CoreFP"), self.payload)
            self.assertFalse(destination.with_suffix(".zip.tmp").exists())

    def test_archive_rejects_missing_duplicate_traversal_symlink_and_corruption(self):
        symlink = zipfile.ZipInfo("CoreFP")
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        cases = [[], [("CoreFP", self.payload)] * 2, [("../CoreFP", self.payload)],
                 [(symlink, self.payload)], [("CoreFP", self.payload + b"resigned")],
                 [("CoreFP", b"X" * len(self.payload))]]
        for entries in cases:
            with self.subTest(entries=entries), warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with self.assertRaises(ValueError):
                    sap_assets.verify_archive(io.BytesIO(self.archive(entries)))
        with self.assertRaises(zipfile.BadZipFile):
            sap_assets.verify_archive(io.BytesIO(b"PK\x03\x04"))

    def test_ipa_modes_and_resource_integrity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Asspp.ipa"
            name = "Payload/Asspp.app/ApplePackage.bundle/SAPAssets.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(name, self.archive())
            sap_assets.verify_ipa(path, bundled=True)
            with self.assertRaisesRegex(ValueError, "unexpectedly contains"):
                sap_assets.verify_ipa(path, bundled=False)
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(name, self.archive([("CoreFP", b"X" * len(self.payload))]))
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                sap_assets.verify_ipa(path, bundled=True)
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/Asspp.app/Info.plist", b"fixture")
            sap_assets.verify_ipa(path, bundled=False)
            with self.assertRaisesRegex(ValueError, "exactly one"):
                sap_assets.verify_ipa(path, bundled=True)

    def test_raw_resources_are_rejected_in_both_variants(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Asspp.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/Asspp.app/ApplePackage.bundle/SAPAssets/CoreFP", self.payload)
            for bundled in (True, False):
                with self.assertRaisesRegex(ValueError, "vulnerable to re-signing"):
                    sap_assets.verify_ipa(path, bundled)

    def test_resources_outside_app_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Asspp.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("SAPAssets.zip", self.archive())
            with self.assertRaisesRegex(ValueError, "inside the application"):
                sap_assets.verify_ipa(path, bundled=True)


if __name__ == "__main__":
    unittest.main()
