# SAP interpreter feasibility gate

This is the first gate for the proposed ApplePackage authentication change. It
does **not** change Asspp's dependencies or claim to fix login. No Apple resources
or emulator binaries are stored in this repository.

The preparation and build scripts refuse to run outside GitHub Actions, to avoid
installing runtimes or filling a developer's disk. They use the runner's temporary
directory and do not install the emulator system-wide.

## What runs

1. Fetch exactly Unicorn TCI `6d0794492de065cdf7e05d7658b4c1b157a34062` and
   ipatool `d5d0b56faf64e3fdef885d49e7928b390aadb6c7` (v2.5.0). The TCI snapshot
   omits `qemu/target`; restore its x86 guest sources from Unicorn 2.1.4 commit
   `8028ec436f2d9376525352dd38ed9ed6b9f6be10`, retaining the fork's TCI changes.
2. Build only the x86 guest interpreter with `UNICORN_INTERPRETER=ON`; fail if
   the generated configuration does not confirm `CONFIG_TCG_INTERPRETER=1`.
3. Exercise the C API from Swift, including a long straight-line guest block.
4. Run the reference Mach-O loader and guest service tests using **only** this
   interpreter. The probe replaces ipatool's runtime loader in its temporary
   checkout; it cannot fall back to a downloaded stock JIT library.
5. If explicitly enabled, download and hash-check Apple's SAP resources using
   ipatool, complete setup, and send the same fictional credential body with and
   without its signature. Require empty HTTP 403 for the unsigned control and
   HTTP 200 with the expected bad-login plist for the signed request.

The online probe is enabled by the `live_signing` workflow-dispatch input or by
explicitly pushing the probe to `codex/sap-auth-403-live`. Ordinary pushes to
`codex/sap-auth-403` do not contact Apple's authentication service. The Go probe
also independently requires `ASSPP_SAP_LIVE_PROBE=1`. It never reads account
credentials from environment variables, files, or Keychain.

## Required follow-up

Only after the real signing gate passes should the engine be ported behind the
ApplePackage Swift interfaces and integrated into Asspp. Successful macOS tests
do not establish iOS compatibility, acceptable latency, or real-account 2FA.
Those remain separate device and integration acceptance criteria. Preserve the
upstream license notices when packaging the engine: the interpreter reference is
GPL-2.0, whereas Asspp and the ipatool reference have their own licenses.

Local checks requiring no downloads:

```sh
bash -n Resources/SAPProbe/build.sh
python3 -m unittest discover -s Resources/SAPProbe -p 'test_*.py'
```
