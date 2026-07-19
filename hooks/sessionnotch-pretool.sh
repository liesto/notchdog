#!/usr/bin/env bash
# PreToolUse hook: a tool is about to run, so the session is working again —
# clear any standing "needs attention" (e.g. right after a permission is approved).
set -euo pipefail
SN_INPUT="$(cat)"; export SN_INPUT
source "$(dirname "$0")/sessionnotch-lib.sh"
sn_post working ""
