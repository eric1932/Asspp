# SAP runtime and authentication integration

Asspp's local ApplePackage snapshot signs authentication requests using the
Unicorn TCI interpreter. Swift owns bag parsing, SAP setup HTTP requests, exact
serialized request bytes, redirects, errors and progress. A static C ABI reuses
the pinned ipatool Mach-O loader, guest system shims and asset verifier.

Go is a CI build tool: its ahead-of-time runtime is linked into the app. Users do
not install Go or Unicorn. No code is compiled on the device and the guest code
buffer uses read/write memory, never executable memory. Only the x86 guest is
built. Static callback trampolines replace purego callbacks and dynamic loading.

## Reproducible sources

- `1rhino2/unicorn-tci`: `6d0794492de065cdf7e05d7658b4c1b157a34062`.
- Unicorn 2.1.4 base: `8028ec436f2d9376525352dd38ed9ed6b9f6be10` restores
  `qemu/target`, accidentally omitted by the TCI fork's ignore rules. Only x86 is enabled.
- `majd/ipatool` v2.5.0: `d5d0b56faf64e3fdef885d49e7928b390aadb6c7`.
- ApplePackage base: `28710fec47fa89dfdedf2bf47cc284a2334ddfdc` (1.2.7).

`Resources/SAPProbe/prepare.py` fetches exact commits only in a GitHub Actions
temporary directory. `prepare_static.py` checks every source patch before applying
it. Missing native code never falls back to downloading stock Unicorn or sending
unsigned credentials.

## Resource ownership

The first sign-in downloads the four Apple SAP assets from the fixed Apple
software-update URL in the pinned reference `assets.go`. Each file's exact size
and SHA-256 are checked on download and every cache load. About 38 MB is cached
under the app's Caches/ApplePackage/SAP/apple-assets-v2 directory. Assets are
replaced atomically. Apple binaries are never committed or included in CI artifacts.

One native session is allowed at a time across accounts. A serial dispatch queue
runs expensive guest operations off the main actor. Swift task cancellation stops
HTTP requests, the asset download and active emulation; completion/failure closes
the guest and frees C buffers. The Go bridge returns opaque numeric handles and
C-owned allocations, never pointers to Go heap memory. Credentials, cookies,
tokens and action signatures are excluded from authentication logs.

## Build and validation

The `SAP authentication regression` workflow runs:

1. `OfflineAuthenticationTests` without the native module or Apple resources.
2. `build_xcframework.sh` for macOS arm64/x86_64, iOS arm64, and Simulator
   arm64/x86_64, asserting `CONFIG_TCG_INTERPRETER=1` in every slice.
3. The same offline tests with the native module linked.
4. Opt-in `LiveSAPTests`, exercising the Swift handshake/C ABI/request path with
   the hardcoded fictional `example.invalid` account only.
5. Unsigned iOS and macOS Asspp compilation. No simulator is started.

Build App and Release reuse this validation workflow and download its native
artifact before packaging. The signed upstream workflow prepares the runtime
only when the selected source includes it.

For a future local app build, copy the `ApplePackageSAP-xcframework` artifact from
a successful run of the same commit into `Packages/ApplePackage/Artifacts/`.
The directory must contain `ApplePackageSAP.xcframework/Info.plist` and `NOTICES/`.
Then resolve the workspace packages and build using the existing instructions.
The app deliberately fails its build phase if the artifact is absent.

Do not run the native preparation scripts locally on a disk-constrained machine.
They refuse non-CI execution. Offline tests with injected signers can be run
independently when SwiftPM dependencies are available.

## Evidence and remaining device acceptance

- The reference interpreter and static binding passed guest loader/shim tests,
  Swift C ABI lifecycle/cancellation, and actual Apple signature validation in
  run https://github.com/eric1932/Asspp/actions/runs/34441535617.
- The paired fictional-credential probe returned empty HTTP 403 without a
  signature and HTTP 200 with Apple's bad-credentials plist with a signature.
- iOS/macOS/Simulator cross-compilation passed in run
  https://github.com/eric1932/Asspp/actions/runs/34442171675; that run then failed
  Swift compilation on the HTTP task cancellation API, which was corrected.

These results do not establish real-account login, 2FA, token refresh, downloads,
or the memory/latency behavior on an iPhone. Perform those checks manually on a
normal signed iPhone build and macOS build before calling the fix device-verified.
Do not put real credentials into CI. Do not infer a successful login from HTTP 200
with fictional credentials.

## Source and license notices

ApplePackage and ipatool retain their MIT licenses. Unicorn and its QEMU-derived
code retain their GPL-2.0 and included per-file licenses. The static runtime is a
combined artifact; the repository's MIT notice does not replace these component
licenses. Generated artifacts include their notices and pinned source/build
references. Preserve these notices and provide the corresponding source when
distributing builds. Apple's downloaded assets remain local to the device and
are not redistributed with the app.
