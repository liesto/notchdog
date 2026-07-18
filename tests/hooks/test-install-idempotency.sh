#!/usr/bin/env bash
# Verifies hooks/install-hooks.sh is idempotent: running it twice against the
# same settings.json must not duplicate SessionNotch hook entries.
#
# IMPORTANT: this always runs against a THROWAWAY HOME (mktemp -d), never the
# real ~/.claude/settings.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT

mkdir -p "$FAKE_HOME/.claude"
echo '{}' > "$FAKE_HOME/.claude/settings.json"

HOME="$FAKE_HOME" bash "$ROOT/hooks/install-hooks.sh" testmachine "http://127.0.0.1:47823/event" >/dev/null
HOME="$FAKE_HOME" bash "$ROOT/hooks/install-hooks.sh" testmachine "http://127.0.0.1:47823/event" >/dev/null

SETTINGS="$FAKE_HOME/.claude/settings.json"
fail=0
for key in Notification Stop UserPromptSubmit SessionEnd; do
  count=$(jq "[.hooks.${key}[]?.hooks[]?.command | select(test(\"sessionnotch\"))] | length" "$SETTINGS")
  if [ "$count" -eq 1 ]; then
    echo "ok: hooks.$key has exactly 1 sessionnotch entry after two installs"
  else
    echo "FAIL: hooks.$key has $count sessionnotch entries after two installs (expected 1)"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "--- settings.json ($SETTINGS) ---"
  jq . "$SETTINGS"
  exit 1
fi

echo "install-hooks.sh idempotency check passed"
