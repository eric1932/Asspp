# asspp-attestd

A small local service that gives Asspp the device attestation Apple's Store
started requiring around 2026-11-06 (anisette machine headers, Store
provisioning, `X-Apple-AMD` / `X-Apple-AMD-M` proof, kbsync).

It is not part of Asspp or ApplePackage. It is built inside a pinned
[ipatool](https://github.com/majd/ipatool) source tree (`IPATOOL_COMMIT`) and
calls ipatool's internal `storeauth`, `sap/assets` and `sap/machine` packages.
Like ipatool, it downloads Apple's components from Apple's CDN and `libunicorn`
from PyPI at runtime into the user cache directory; neither is embedded here.
Unicorn is GPL-2.0; this program only loads it at runtime.

## Run

```sh
./asspp-attestd serve                          # 127.0.0.1:18765
./asspp-attestd serve --listen 192.168.50.11:18765 --state-dir /data/state
```

On first start it generates an API token, saves it as `<state-dir>/token` and
prints it once. Every request needs `Authorization: Bearer <token>`.

- State: one file per device GUID in `--state-dir` (default
  `~/Library/Application Support/asspp-attestd` on macOS,
  `$XDG_CONFIG_HOME/asspp-attestd` on Linux), mode 0600.
- Caches: ipatool's defaults (`~/Library/Caches/ipatool` on macOS,
  `$XDG_CACHE_HOME/ipatool` on Linux). A Mac that already ran
  `ipatool auth login` reuses its 167 MB of Apple components.
- The service never receives Apple ID passwords. It sees device GUIDs, DSIDs,
  Store provisioning challenges and the session cookies needed for
  provisioning.

## API

All endpoints are JSON. Errors are `{"code", "message"}` with codes
`unauthorized` (401), `invalid_request` (400), `not_provisioned` (409),
`assets_unavailable` (503), `upstream_failed` (502), `emulator_failed` (500),
`canceled` (499). One emulator operation runs at a time; `health` answers
while one runs. Its `assetBytes` counts the bytes read so far from Apple's
update CDN, so a client can show how far the first download has got.

| Endpoint | Request | Response | ipatool |
|---|---|---|---|
| `GET /v1/health` | | `version, ipatoolCommit, assetsCached, unicornCached, assetBytes` | |
| `POST /v1/prepare` | `{}` | `{}` | `assets.Load` |
| `POST /v1/machine-headers` | `guid` | `headers` | `storeauth.AnisetteHeaders` (drops existing Store provisioning) |
| `POST /v1/provision` | `guid, challenge, endpoint, userAgent, machineHeaders, cookies` | `cookies` set by Apple | `machine.GenerateKBSync(^1)` + `storeauth.ProvisionStoreAnisette` |
| `POST /v1/store-headers` | `guid, url` | `headers` (`X-Apple-AMD`, `X-Apple-AMD-M`) | `storeauth.StoreAMDHeaders` |
| `POST /v1/kbsync` | `guid, dsid` (decimal string) | `kbsync` (base64) | `machine.GenerateKBSync` |

Example:

```sh
TOKEN=$(cat ~/Library/Application\ Support/asspp-attestd/token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18765/v1/health
curl -s -H "Authorization: Bearer $TOKEN" -d '{"guid":"A1B2C3D4E5F6"}' http://127.0.0.1:18765/v1/machine-headers
```

## Build

CI (`.github/workflows/attestd.yml`) checks out ipatool at `IPATOOL_COMMIT`,
copies these files to `cmd/asspp-attestd`, then runs `go vet`, the offline
tests and `go build` for darwin/arm64 and linux/amd64.
