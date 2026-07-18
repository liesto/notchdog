#!/usr/bin/env bash
# Merge SessionNotch hooks into ~/.claude/settings.json and write ~/.sessionnotch/config.json.
# Usage: install-hooks.sh <machine-name> <endpoint-url>
#
# NOTE (confirm live in Task 9, do not trust blindly): the hook event key
# names used below (Notification, Stop, UserPromptSubmit, SessionEnd) and the
# command-hook JSON shape ({"matcher":"","hooks":[{"type":"command","command":"..."}]})
# are based on the Claude Code hooks contract at the time this brief was
# written. Verify both against the actual installed Claude Code version's
# hooks documentation/schema before relying on this in production, and adjust
# if the schema has changed.
set -euo pipefail
MACHINE="${1:?machine name}"; ENDPOINT="${2:?endpoint url, e.g. http://laptop.tail-scale.ts.net:47823/event}"
HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
SN_DIR="$HOME/.sessionnotch"; mkdir -p "$SN_DIR"

jq -n --arg m "$MACHINE" --arg e "$ENDPOINT" \
  '{machine:$m, endpoint:$e, port:47823}' > "$SN_DIR/config.json"

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.sessionnotch.bak"

hook() { printf '{"matcher":"","hooks":[{"type":"command","command":"%s"}]}' "$1"; }
NOTIFY=$(hook "$HOOKS_DIR/sessionnotch-notify.sh")
STOP=$(hook "$HOOKS_DIR/sessionnotch-stop.sh")
PROMPT=$(hook "$HOOKS_DIR/sessionnotch-prompt.sh")
END=$(hook "$HOOKS_DIR/sessionnotch-end.sh")

# Idempotent: strip any existing entries whose command references a
# sessionnotch hook script before appending the fresh one, so re-running this
# script (e.g. to pick up a new endpoint) never duplicates entries/POSTs.
jq --argjson n "$NOTIFY" --argjson s "$STOP" --argjson p "$PROMPT" --argjson e "$END" '
  def strip($arr): [ ($arr // [])[] | select((.hooks // []) | any(.command | test("sessionnotch")) | not) ];
  .hooks.Notification = (strip(.hooks.Notification) + [$n]) |
  .hooks.Stop = (strip(.hooks.Stop) + [$s]) |
  .hooks.UserPromptSubmit = (strip(.hooks.UserPromptSubmit) + [$p]) |
  .hooks.SessionEnd = (strip(.hooks.SessionEnd) + [$e])
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
echo "Installed hooks for machine '$MACHINE' -> $ENDPOINT (backup: $SETTINGS.sessionnotch.bak)"
