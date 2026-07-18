#!/usr/bin/env bash
# Runs each hook against a fixture with a stub endpoint; asserts the posted event kind.
#
# Stub approach: BSD nc (macOS) does support `nc -l PORT` as a one-shot
# listener that accepts a single connection, prints a canned HTTP response,
# and exits -- confirmed working on this machine. Two adaptations were made
# vs. a naive single-port version to make repeated runs reliable:
#   1. Each assertion uses its own port (BASE_PORT+N) instead of reusing one
#      port six times back-to-back, to avoid TIME_WAIT/bind races.
#   2. BSD nc's `-w timeout` does NOT bound the accept() wait in listen mode
#      (verified empirically -- it just hangs), so a manual bounded poll loop
#      is used instead of a bare `wait`, with a pkill fallback, so a
#      misbehaving hook (e.g. one that silently no-ops) fails fast with a
#      clear message instead of hanging the test run forever.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
export SESSIONNOTCH_DIR="$TMP"
echo "testsecret" > "$TMP/secret"

BASE_PORT=47898
WAIT_TICKS=50   # 50 * 0.1s = 5s max wait per assertion before declaring failure

write_config() { # $1 port
  printf '{"machine":"testbox","endpoint":"http://127.0.0.1:%s/event","port":%s}' "$1" "$1" > "$TMP/config.json"
}

assert_kind() { # $1 hook script, $2 fixture, $3 expected kind, $4 port
  local port="$4"
  write_config "$port"
  local out="$TMP/req-$port.txt"
  : > "$out"

  # Stub server: nc writes the request body to a file, replies 204.
  ( printf 'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n' | nc -l "$port" > "$out" 2>/dev/null ) &
  local ncpid=$!
  sleep 0.2

  "$ROOT/hooks/$1" < "$ROOT/tests/hooks/fixtures/$2" || true

  # Bounded wait: nc should exit as soon as curl connects; poll instead of a
  # bare `wait` so a hook that fails to POST can't hang the suite forever.
  local ticks=0
  while kill -0 "$ncpid" 2>/dev/null; do
    sleep 0.1
    ticks=$((ticks + 1))
    if [ "$ticks" -ge "$WAIT_TICKS" ]; then
      break
    fi
  done
  # Best-effort cleanup regardless of how the loop above ended.
  kill "$ncpid" 2>/dev/null || true
  pkill -f "nc -l $port\$" 2>/dev/null || true

  if grep -q "\"event\":\"$3\"" "$out"; then
    echo "ok: $1 $2 -> $3"
  else
    echo "FAIL: $1 $2 expected $3"
    echo "--- captured request ($out) ---"
    cat "$out"
    exit 1
  fi
}

assert_kind sessionnotch-notify.sh notification-permission.json waiting_permission "$((BASE_PORT + 0))"
assert_kind sessionnotch-notify.sh notification-idle.json       idle               "$((BASE_PORT + 1))"
assert_kind sessionnotch-stop.sh   stop.json                     done               "$((BASE_PORT + 2))"
assert_kind sessionnotch-prompt.sh prompt.json                   working            "$((BASE_PORT + 3))"
assert_kind sessionnotch-end.sh    end-error.json                error              "$((BASE_PORT + 4))"
assert_kind sessionnotch-end.sh    end-normal.json               session_end        "$((BASE_PORT + 5))"

rm -rf "$TMP"
echo "all hook tests passed"
