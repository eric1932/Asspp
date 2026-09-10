# ApplePackage source snapshot

This directory is based on Lakr233/ApplePackage 1.2.7, commit
`28710fec47fa89dfdedf2bf47cc284a2334ddfdc`. Only package sources, tests, the
manifest, documentation and license were copied; no checkout, dependency cache,
Apple binaries or generated native libraries are included.

The changes intended for the library are in `Authentication/`, `Authenticate.swift`,
`Bag.swift`, the HTTP client/logger/cookie helpers, the package manifest, and the
new `OfflineAuthenticationTests`/`LiveSAPTests`. Existing account serialization
and the public authenticate/rotate entry points remain compatible.

Asspp uses this local package so the library fix is reviewable without relying on
an unpublished upstream version. After an upstream release includes these changes,
replace the local package reference with that pinned release.

For offline tests (on an environment with the existing Swift dependencies):

```sh
swift test --package-path Packages/ApplePackage --filter OfflineAuthenticationTests
```

This filter never calls Apple, reads account files, starts Asspp, or requires a
simulator runtime. Resolving SwiftPM dependencies still needs disk/network on a
fresh machine; the current work runs it only in CI. The original upstream test
suite includes live tests; do not substitute an unfiltered `swift test`.

The generated `Artifacts/ApplePackageSAP.xcframework` is optional for offline
mock tests and mandatory for Asspp builds. Native builds and opt-in live tests are
documented in `Resources/SAPRuntime/README.md` at the repository root.

Optional `Sources/ApplePackage/Resources/SAPAssets` files are staged by CI only.
Their presence selects the bundled-resource build and adds the SwiftPM resource
copy rule. Absence selects the original download/cache path. Bundled builds never
download replacements for missing or corrupt embedded files. `BundledSAPTests`
checks real resource initialization only when explicitly enabled in CI.
