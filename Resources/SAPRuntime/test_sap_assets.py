import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
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

    def test_ipa_modes_and_resource_integrity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Asspp.ipa"
            name = "Payload/Asspp.app/ApplePackage.bundle/SAPAssets/CoreFP"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(name, self.payload)
            sap_assets.verify_ipa(path, bundled=True)
            with self.assertRaisesRegex(ValueError, "unexpectedly contains"):
                sap_assets.verify_ipa(path, bundled=False)
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(name, b"X" * len(self.payload))
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                sap_assets.verify_ipa(path, bundled=True)
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/Asspp.app/Info.plist", b"fixture")
            sap_assets.verify_ipa(path, bundled=False)
            with self.assertRaisesRegex(ValueError, "complete set"):
                sap_assets.verify_ipa(path, bundled=True)

    def test_resources_outside_app_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Asspp.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("SAPAssets/SAPAssets/CoreFP", self.payload)
            with self.assertRaisesRegex(ValueError, "inside the application"):
                sap_assets.verify_ipa(path, bundled=True)


if __name__ == "__main__":
    unittest.main()
