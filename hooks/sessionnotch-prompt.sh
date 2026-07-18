#!/usr/bin/env bash
set -euo pipefail
SN_INPUT="$(cat)"; export SN_INPUT
source "$(dirname "$0")/sessionnotch-lib.sh"
sn_post working ""
