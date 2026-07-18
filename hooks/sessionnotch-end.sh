#!/usr/bin/env bash
set -euo pipefail
SN_INPUT="$(cat)"; export SN_INPUT
source "$(dirname "$0")/sessionnotch-lib.sh"
reason=$(printf '%s' "$SN_INPUT" | jq -r '.reason // ""')
case "$reason" in
  error|crash|aborted) sn_post error "$reason" ;;
  *) sn_post session_end "" ;;
esac
