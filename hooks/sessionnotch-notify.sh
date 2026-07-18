#!/usr/bin/env bash
set -euo pipefail
SN_INPUT="$(cat)"; export SN_INPUT
source "$(dirname "$0")/sessionnotch-lib.sh"
msg=$(printf '%s' "$SN_INPUT" | jq -r '.message // ""')
if printf '%s' "$msg" | grep -qi 'permission'; then
  sn_post waiting_permission "$msg"
else
  sn_post idle "$msg"
fi
