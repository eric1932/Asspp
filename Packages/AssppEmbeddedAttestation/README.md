# AssppEmbeddedAttestation

A thin Swift wrapper around `AssppAttest.xcframework`, which is asspp-attestd
(`Tools/attestd`) built as an in-process library for iOS with an
interpreter-only Unicorn. It lets the iOS app produce Apple's device
attestation on the device, with no service to run elsewhere.

This is a fork-only, opt-in module. It is not part of ApplePackage and is not
proposed upstream.

- The xcframework is not in the repository. The `embedded-runtime` workflow
  builds it, and the iOS build copies it into `Artifacts/`. Without it the
  package still builds and `EmbeddedAttestationRuntime.isAvailable` is false.
- The runtime links Unicorn, which is GPL-2.0. An app that includes it has to be
  distributed under terms compatible with that. License texts ship next to the
  xcframework in `NOTICES/`.
- Apple's components are downloaded on the device at first use, as ipatool does.
  Nothing from Apple is in the repository or in the build.
