# Static SAP runtime bridge

The validated ipatool engine is reused behind a narrow C ABI instead of rewriting
the Mach-O loader and the guest OS shims. The reference Go sources are compiled
ahead of time into a static archive in CI; users do not install Go or Unicorn.
Swift will own the bag, SAP setup HTTP requests, authentication body, and UI.
The bridge only downloads the pinned Apple assets and executes the guest code.

`prepare_static.py` adapts the exact reference checkout produced by SAPProbe:

- Replace dynamic library loading and purego callbacks with direct C calls and a
  statically compiled C callback trampoline.
- Reuse the existing reference loader, shims, hash-checked asset cache, and tests.
- Expose opaque numeric session handles, exchange/sign operations, cancellation,
  and explicit C allocation release; never return pointers into the Go heap.
- Allow the caller to choose an app-sandbox cache directory.

`build_static.sh` runs reference guest tests through this static binding, builds
the C archive, and checks Swift lifecycle/cancellation without downloading Apple
assets. With `ASSPP_SAP_LIVE_PROBE=1`, the same Apple acceptance test is repeated
through the static binding. The Swift app has not been wired to this prototype.

The engine still needs iOS cross-compilation and device validation. C-archive
support in the Go toolchain does not establish those results. Preserve the
reference licenses when packaging these components; no Apple binaries are
included in this repository.
