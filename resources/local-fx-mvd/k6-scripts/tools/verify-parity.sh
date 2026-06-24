#!/usr/bin/env bash
# Enforce the anti-drift rule: lib/ and scenarios/ must be BYTE-IDENTICAL to the
# canonical copy. The per-repo k6-scripts layout means the load driver is
# duplicated across three repos; if a copy drifts, the load generator itself
# becomes a confound (defeating the normalized-deployment fairness argument).
#
#   verify-parity.sh <path-to-canonical-k6-scripts>
set -euo pipefail

CANON="${1:?usage: verify-parity.sh <canonical-k6-scripts-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # this k6-scripts/

[ -d "$CANON" ] || { echo "ERROR: canonical dir not found: $CANON"; exit 2; }

rc=0
for sub in lib scenarios; do
  if ! diff -ruq "$CANON/$sub" "$HERE/$sub" >/dev/null 2>&1; then
    echo "DRIFT in $sub/ vs canonical:"
    diff -ruq "$CANON/$sub" "$HERE/$sub" || true
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  echo "parity OK: lib/ + scenarios/ identical to $CANON"
else
  echo "PARITY FAILED: sync the canonical lib/ + scenarios/ into this repo (only config/ may differ)."
fi
exit "$rc"
