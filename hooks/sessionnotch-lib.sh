#!/usr/bin/env bash
# Shared helpers for SessionNotch hooks. Sourced by each hook script.
set -euo pipefail

SN_DIR="${SESSIONNOTCH_DIR:-$HOME/.sessionnotch}"

sn_post() {
  # $1=event kind, $2=message (optional). Reads Claude hook JSON from $SN_INPUT.
  local kind="$1" message="${2:-}"
  local cfg="$SN_DIR/config.json" secret_file="$SN_DIR/secret"
  [ -f "$cfg" ] && [ -f "$secret_file" ] || exit 0   # not configured: no-op

  local endpoint machine secret
  endpoint=$(jq -r '.endpoint' "$cfg")
  machine=$(jq -r '.machine' "$cfg")
  secret=$(cat "$secret_file")

  local session cwd project ts
  session=$(printf '%s' "$SN_INPUT" | jq -r '.session_id // "unknown"')
  cwd=$(printf '%s' "$SN_INPUT" | jq -r '.cwd // "."')
  project=$(basename "$cwd")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local payload
  payload=$(jq -nc --arg m "$machine" --arg s "$session" --arg p "$project" \
    --arg c "$cwd" --arg e "$kind" --arg msg "$message" --arg t "$ts" \
    '{machine:$m, session_id:$s, project:$p, cwd:$c, event:$e,
      message:(if $msg=="" then null else $msg end), ts:$t}')

  curl -s --max-time 2 -X POST "$endpoint" \
    -H "X-SessionNotch-Secret: $secret" -d "$payload" >/dev/null 2>&1 || true
}
