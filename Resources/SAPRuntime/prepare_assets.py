"""Download and verify Apple assets on the CI runner, never on the user's Mac."""

import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "SAPProbe"))
from prepare import IPATOOL_REVISION, fetch_source
from sap_assets import verify_directory


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("Apple resource preparation is CI-only; nothing was downloaded.")
    root = Path(sys.argv[1]).resolve()
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve()
    if runner_temp not in root.parents:
        raise SystemExit("Resource preparation must use a child of RUNNER_TEMP")
    repository = Path(__file__).resolve().parents[2]
    destination = repository / "Packages/ApplePackage/Sources/ApplePackage/Resources/SAPAssets"
    if destination.exists():
        verify_directory(destination)
        print("Existing bundled resources verified")
        return
    reference = root / "ipatool"
    fetch_source("majd/ipatool", IPATOOL_REVISION, reference)
    # This exporter exists only in the temporary build checkout, not in the app.
    (reference / "internal/sap/assets/asspp_export.go").write_text('''package assets
import "context"
func ExportDirectory(ctx context.Context, directory string) error {
    bundle, err := download(ctx)
    if err != nil { return err }
    return writeCache(directory, bundle)
}
''')
    command = reference / "internal/assppexport"
    command.mkdir()
    (command / "main.go").write_text('''package main
import (
    "context"
    "log"
    "os"
    "github.com/majd/ipatool/v2/internal/sap/assets"
)
func main() {
    if err := assets.ExportDirectory(context.Background(), os.Args[1]); err != nil { log.Fatal(err) }
}
''')
    temporary_assets = root / "SAPAssets"
    subprocess.run(["go", "run", "./internal/assppexport", str(temporary_assets)], cwd=reference, check=True)
    verify_directory(temporary_assets)
    # Publish the complete set only after verification; failure leaves no bundle.
    shutil.copytree(temporary_assets, destination)
    verify_directory(destination)
    print("Verified Apple resources staged for bundling")


if __name__ == "__main__":
    main()
