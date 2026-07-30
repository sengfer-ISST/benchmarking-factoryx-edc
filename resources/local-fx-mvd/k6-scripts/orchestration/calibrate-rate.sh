#!/usr/bin/env bash
# Find the highest SUSTAINABLE arrival rate for one connector — the input that
# `steady` and `soak` require and that the first campaign never measured.
#
# Why this exists: steady.js documents "pick a rate safely BELOW the saturation
# knee", but nothing computed that number, so the default (5/s) was used against a
# connector that sustained ~3-5 tx/s. All three steady repetitions then returned
# 0-9% success — they measured an unbounded queue, not a steady state.
#
#   ./orchestration/calibrate-rate.sh <connector> [rates] [duration]
#   ./orchestration/calibrate-rate.sh factoryx "1 2 3 4 5 6" 3m
#
# A rung PASSES when it meets all three conditions below; the highest passing rung
# is that connector's sustainable rate. Run it on EVERY connector, then set ONE
# campaign-wide RATE at or below the lowest result (steady compares connectors at
# equal offered load, so the rate cannot vary per connector).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

CONNECTOR="${1:?usage: calibrate-rate.sh <connector> [rates] [duration]}"
RATES="${2:-1 2 3 4 5 6 8}"
DURATION="${3:-3m}"

# Pass criteria for a rung (all must hold):
MAX_FAILED_RATE="${MAX_FAILED_RATE:-0.01}"   # <1% transactions failed
MAX_E2E_P95_MS="${MAX_E2E_P95_MS:-20000}"    # tail still inside the steady gate
MAX_DROPPED="${MAX_DROPPED:-0}"              # k6 delivered the full offered rate

OUT="$ROOT/results/${CONNECTOR}/calibration-$(date -u +%Y-%m-%dT%H-%M-%SZ)"
mkdir -p "$OUT"
echo "Calibrating $CONNECTOR over rates [$RATES] x $DURATION each -> $OUT"
echo "pass = failed_rate<$MAX_FAILED_RATE AND e2e_p95<${MAX_E2E_P95_MS}ms AND dropped<=$MAX_DROPPED"
echo

printf '%-6s %-10s %-12s %-12s %-9s %-8s %s\n' rate ok/attempts failed_rate e2e_p95_ms edr_polls dropped verdict | tee "$OUT/summary.txt"

BEST=""
for r in $RATES; do
  # SKIP_WARMUP=0: each rung gets the same warmup treatment as a measured run, so
  # the JIT state matches what steady will see.
  RATE="$r" DURATION="$DURATION" SCENARIO_TAG="calibrate" \
    "$HERE/run.sh" "$CONNECTOR" steady >"$OUT/rate-$r.log" 2>&1 || true

  # Newest steady run folder is this rung's.
  RUN_DIR="$(ls -1dt "$ROOT/results/$CONNECTOR/steady/"*/ 2>/dev/null | head -1)"
  S="$RUN_DIR/k6-summary.json"
  [ -f "$S" ] || { printf '%-6s %s\n' "$r" "NO SUMMARY (see $OUT/rate-$r.log)" | tee -a "$OUT/summary.txt"; continue; }

  read -r ok att fr p95 polls dropped <<EOF
$(jq -r '
  (.metrics.dsp_transactions_succeeded.values.count // 0) as $ok
  | (.metrics.dsp_transactions_failed.values.count // 0) as $bad
  | [ $ok, ($ok+$bad),
      (.metrics.dsp_transaction_failed_rate.values.rate // 0),
      (.metrics.e2e_transaction_duration.values."p(95)" // 0),
      (.metrics.edr_polls.values.count // 0),
      (.metrics.dropped_iterations.values.count // 0) ] | @tsv' "$S")
EOF

  verdict=FAIL
  awk -v fr="$fr" -v p95="$p95" -v d="$dropped" \
      -v mfr="$MAX_FAILED_RATE" -v mp="$MAX_E2E_P95_MS" -v md="$MAX_DROPPED" \
      'BEGIN { exit !(fr < mfr && p95 < mp && p95 > 0 && d <= md) }' && verdict=PASS
  [ "$verdict" = "PASS" ] && BEST="$r"

  pt=$(awk -v p="$polls" -v a="$att" 'BEGIN { printf "%.1f", (a>0 ? p/a : 0) }')
  printf '%-6s %-10s %-12.4f %-12.0f %-9s %-8s %s\n' \
    "$r" "$ok/$att" "$fr" "$p95" "$pt" "$dropped" "$verdict" | tee -a "$OUT/summary.txt"
  cp "$S" "$OUT/rate-$r-summary.json" 2>/dev/null || true
done

echo
if [ -n "$BEST" ]; then
  echo "Highest sustainable rate for $CONNECTOR: ${BEST}/s" | tee -a "$OUT/summary.txt"
  echo "Campaign RATE must be <= the MINIMUM of this value across ALL connectors." | tee -a "$OUT/summary.txt"
else
  echo "No rung passed — the connector cannot sustain even ${RATES%% *}/s under these criteria." | tee -a "$OUT/summary.txt"
  echo "Investigate before benchmarking: check dsp_failures_terminated vs dsp_failures_timeout." | tee -a "$OUT/summary.txt"
fi
echo "Details: $OUT"
