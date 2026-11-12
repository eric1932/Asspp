#!/bin/bash
# Times asspp-attestd steps on the interpreter-only Unicorn, then on the stock
# JIT one, for comparison. Run it on a developer Mac with the two files from the
# tci-speed workflow's attestd-interpreter-probe-darwin-arm64 artifact.
#
#   time-attestd.sh <artifact-dir> <state-dir-copy> <guid> [work-dir]
#
# - <state-dir-copy> is a COPY of an asspp-attestd state directory that holds a
#   Store-provisioned <guid>.json and a token file. Each mode works on its own
#   throwaway copy of it; a running service and its state are not touched.
# - Prints only status codes and seconds. Tokens, headers and response bodies
#   are never printed.
# - machine-headers uses a made-up device ID, so it provisions an anonymous
#   machine with Apple the same way a first sign-in does. No account is used.
set -uo pipefail
umask 077

[ $# -ge 3 ] || { echo "usage: $0 <artifact-dir> <state-dir-copy> <guid> [work-dir]" >&2; exit 2; }
BIN="$1/asspp-attestd-probe"
LIB="$1/libunicorn-interpreter.dylib"
SRC_STATE="$2"
GUID="$3"
S="${4:-$(mktemp -d)}"
PORT=18766
URL="https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download?guid=$GUID"

for path in "$BIN" "$LIB" "$SRC_STATE/token" "$SRC_STATE/$GUID.json"; do
  [ -e "$path" ] || { echo "missing: $path" >&2; exit 1; }
done

run_mode() {
  local mode="$1"
  local state="$S/probe-state-$mode" log="$S/probe-$mode.log" body="$S/probe-last-body.json"
  local fresh_guid token pid
  fresh_guid="02$(openssl rand -hex 5 | tr a-f A-F)"
  rm -rf "$state"
  cp -Rp "$SRC_STATE" "$state"
  token=$(tr -d '[:space:]' < "$state/token")

  if [ "$mode" = interpreter ]; then
    ASSPP_UNICORN_LIBRARY="$LIB" "$BIN" serve --listen "127.0.0.1:$PORT" --state-dir "$state" >"$log" 2>&1 &
  else
    "$BIN" serve --listen "127.0.0.1:$PORT" --state-dir "$state" >"$log" 2>&1 &
  fi
  pid=$!

  local ready=""
  for _ in $(seq 1 50); do
    if curl -fsS -o /dev/null -H "Authorization: Bearer $token" "http://127.0.0.1:$PORT/v1/health" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.2
  done
  if [ -z "$ready" ]; then
    echo "$mode: service did not start, see $log" >&2
    kill "$pid" 2>/dev/null
    return 1
  fi

  call() {
    local label="$1" route="$2" payload="$3" out code secs note=""
    out=$(curl -sS -o "$body" -w '%{http_code} %{time_total}' --max-time 1800 \
      -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
      -d "$payload" "http://127.0.0.1:$PORT$route" 2>/dev/null)
    code=${out%% *}
    secs=${out##* }
    if [ "$code" != 200 ]; then
      note="  error: $(python3 -I -c 'import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("code", "?"), "-", str(data.get("message", ""))[:200])
except Exception:
    print("no readable error body")' "$body" 2>/dev/null)"
    fi
    rm -f "$body"
    printf '%-12s %-18s HTTP %s  %7.1fs%s\n' "$mode" "$label" "$code" "$secs" "$note"
  }

  call "kbsync #1" /v1/kbsync "{\"guid\":\"$GUID\",\"dsid\":\"12345678901\"}"
  call "kbsync #2" /v1/kbsync "{\"guid\":\"$GUID\",\"dsid\":\"12345678901\"}"
  call "store-headers #1" /v1/store-headers "{\"guid\":\"$GUID\",\"url\":\"$URL\"}"
  call "store-headers #2" /v1/store-headers "{\"guid\":\"$GUID\",\"url\":\"$URL\"}"
  call "machine-headers" /v1/machine-headers "{\"guid\":\"$fresh_guid\"}"

  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -rf "$state"
}

echo "mode         step               status     time"
run_mode interpreter
run_mode jit
echo "done"
