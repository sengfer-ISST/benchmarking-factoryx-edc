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
# orchestration/ is checked too: run.sh defines the measurement window, the warmup,
# the snapshot and the recorded provenance, so drift there is as much a confound as
# drift in the driver itself. Nothing in orchestration/ is connector-specific — every
# script reads config/<connector>.json or results/**/meta.json — so the whole directory
# is covered, screenshot-urls.sh included (its Grafana URL and theme are env overrides,
# not per-repo constants: a hardcoded server default drifted for a day and was caught
# only by hand on 2026-07-30).
for sub in lib scenarios orchestration; do
  if ! diff -ruq "$CANON/$sub" "$HERE/$sub" >/dev/null 2>&1; then
    echo "DRIFT in $sub/ vs canonical:"
    diff -ruq "$CANON/$sub" "$HERE/$sub" || true
    rc=1
  fi
done

# tools/ is guarded too: gen-payloads.sh defines the payload ladder (1KB..100MB), which
# is a controlled variable — if it drifted, connectors would be swept over different
# sizes and the data-plane comparison would be meaningless. dsp-callback-sink/ is
# excluded because it genuinely exists only in the BaSyx repo: it is the raw-DSP
# callback receiver for that connector's identity-OFF arm, the same per-connector
# exception as basyx-off/.
if ! diff -ruq -x dsp-callback-sink "$CANON/tools" "$HERE/tools" >/dev/null 2>&1; then
  echo "DRIFT in tools/ vs canonical:"
  diff -ruq -x dsp-callback-sink "$CANON/tools" "$HERE/tools" || true
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "parity OK: lib/ + scenarios/ + orchestration/ + tools/ identical to $CANON"
else
  echo "PARITY FAILED: sync canonical lib/ + scenarios/ + orchestration/ + tools/ into this repo (only config/ may differ)."
fi
exit "$rc"
