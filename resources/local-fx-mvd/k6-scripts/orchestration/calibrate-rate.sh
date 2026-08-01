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
CONFIG_PATH="$ROOT/config/${CONNECTOR}.json"
[ -f "$CONFIG_PATH" ] || { echo "ERROR: no config $CONFIG_PATH" >&2; exit 1; }

# Pass criteria for a rung (all must hold):
MAX_FAILED_RATE="${MAX_FAILED_RATE:-0.01}"   # <1% transactions failed
MAX_E2E_P95_MS="${MAX_E2E_P95_MS:-20000}"    # tail still inside the steady gate
MAX_DROPPED="${MAX_DROPPED:-0}"              # k6 delivered the full offered rate

OUT="$ROOT/results/${CONNECTOR}/calibration-$(date -u +%Y-%m-%dT%H-%M-%SZ)"
mkdir -p "$OUT"
echo "Calibrating $CONNECTOR over rates [$RATES] x $DURATION each -> $OUT"
echo "pass = failed_rate<$MAX_FAILED_RATE AND e2e_p95<${MAX_E2E_P95_MS}ms AND dropped<=$MAX_DROPPED"
echo

# --- preflight -------------------------------------------------------------
# run.sh exits BEFORE k6 on a missing tool (1), a parity failure (2) or a health-gate
# timeout (3). Without this check every rung burns its 90 s gate and the table fills
# with "NO SUMMARY", which reads like a connector result but means the runs never
# happened. Check once, up front, and say exactly what is wrong.
PROM_URL="${PROM_URL:-$(jq -r '.prometheus.baseUrl // "http://localhost:9090"' "$CONFIG_PATH")}"
CONSUMER_URL="$(jq -r '.consumerManagementUrl // empty' "$CONFIG_PATH")"
preflight_fail=0
CONSUMER_CODE="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$CONSUMER_URL" 2>/dev/null || true)"
if [ -z "$CONSUMER_CODE" ] || [ "$CONSUMER_CODE" = "000" ]; then
  echo "PREFLIGHT FAIL: consumer Management API not answering at $CONSUMER_URL" >&2
  echo "                Is the stack up?  docker compose -f <compose-file> ps" >&2
  preflight_fail=1
fi
if ! curl -sf -m 3 "$PROM_URL/-/ready" >/dev/null 2>&1; then
  echo "PREFLIGHT FAIL: Prometheus not ready at $PROM_URL" >&2
  echo "                (dst uses :9099 — check .prometheus.baseUrl in $CONFIG_PATH)" >&2
  preflight_fail=1
fi
if [ -n "${CANONICAL_DIR:-}" ] && ! "$ROOT/tools/verify-parity.sh" "$CANONICAL_DIR" >/dev/null 2>&1; then
  echo "PREFLIGHT FAIL: harness parity check failed against CANONICAL_DIR=$CANONICAL_DIR" >&2
  echo "                Run: ./tools/verify-parity.sh \"\$CANONICAL_DIR\"" >&2
  preflight_fail=1
fi
[ "$preflight_fail" -eq 0 ] || { echo; echo "Nothing was run. Fix the above and re-invoke." >&2; exit 3; }
echo "preflight OK (consumer API + Prometheus reachable)"
echo

printf '%-6s %-10s %-12s %-12s %-9s %-8s %s\n' rate ok/attempts failed_rate e2e_p95_ms edr_polls dropped verdict | tee "$OUT/summary.txt"

BEST=""
RUNS_WITH_DATA=0
for r in $RATES; do
  # SKIP_WARMUP=0: each rung gets the same warmup treatment as a measured run, so
  # the JIT state matches what steady will see.
  set +e
  RATE="$r" DURATION="$DURATION" \
    "$HERE/run.sh" "$CONNECTOR" steady >"$OUT/rate-$r.log" 2>&1
  RC=$?
  set -e

  # Prefer the path run.sh itself printed over newest-mtime guessing.
  RUN_DIR="$(grep -oP '^>>> .* ->  \K\S+' "$OUT/rate-$r.log" 2>/dev/null | head -1)"
  [ -n "$RUN_DIR" ] || RUN_DIR="$(ls -1dt "$ROOT/results/$CONNECTOR/steady/"*/ 2>/dev/null | head -1)"
  S="${RUN_DIR%/}/k6-summary.json"

  if [ ! -f "$S" ]; then
    # exit 99 = thresholds crossed and a summary DOES exist; anything else here is
    # infrastructure, and continuing would produce five more identical failures.
    case "$RC" in
      1) why="run.sh config error (missing config/scenario/k6/jq/curl)" ;;
      2) why="harness parity check failed" ;;
      3) why="health gate timed out — stack or Prometheus not up" ;;
      107) why="k6 script exception" ;;
      *) why="run.sh exited $RC before producing a summary" ;;
    esac
    printf '%-6s %s\n' "$r" "NOT RUN — $why" | tee -a "$OUT/summary.txt"
    echo >&2
    echo "ABORTING: $why" >&2
    echo "Last lines of $OUT/rate-$r.log:" >&2
    tail -15 "$OUT/rate-$r.log" >&2
    echo >&2
    echo "This is an INFRASTRUCTURE failure, not a connector result — no rate was tested." >&2
    exit "$RC"
  fi
  RUNS_WITH_DATA=$((RUNS_WITH_DATA + 1))

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

  # Name the criterion that failed. "the connector cannot do 2/s" and "k6 could not
  # offer 2/s" are different findings and only one of them is about the connector.
  verdict=PASS
  awk -v fr="$fr" -v mfr="$MAX_FAILED_RATE" 'BEGIN { exit !(fr < mfr) }' || verdict="FAIL(failures)"
  if [ "$verdict" = "PASS" ]; then
    awk -v p95="$p95" -v mp="$MAX_E2E_P95_MS" 'BEGIN { exit !(p95 < mp && p95 > 0) }' || verdict="FAIL(latency)"
  fi
  if [ "$verdict" = "PASS" ] && [ "${dropped:-0}" -gt "$MAX_DROPPED" ]; then
    # NOT a connector limit: raise PREALLOCATED_VUS and re-run this rung before
    # concluding anything about capacity.
    verdict="FAIL(harness:dropped)"
  fi
  [ "$verdict" = "PASS" ] && BEST="$r"

  pt=$(awk -v p="$polls" -v a="$att" 'BEGIN { printf "%.1f", (a>0 ? p/a : 0) }')
  printf '%-6s %-10s %-12.4f %-12.0f %-9s %-8s %s\n' \
    "$r" "$ok/$att" "$fr" "$p95" "$pt" "$dropped" "$verdict" | tee -a "$OUT/summary.txt"
  case "$verdict" in
    *harness*) echo "        ^ k6 could not OFFER this rate — not a connector limit." \
                    "Re-run with PREALLOCATED_VUS=200 before believing it." | tee -a "$OUT/summary.txt" ;;
  esac
  cp "$S" "$OUT/rate-$r-summary.json" 2>/dev/null || true
done

echo
if [ -n "$BEST" ]; then
  echo "Highest sustainable rate for $CONNECTOR: ${BEST}/s" | tee -a "$OUT/summary.txt"
  echo "Campaign RATE must be <= the MINIMUM of this value across ALL connectors." | tee -a "$OUT/summary.txt"
elif [ "$RUNS_WITH_DATA" -eq 0 ]; then
  # Never claim a capacity result from runs that produced no data.
  echo "INCONCLUSIVE: no rung produced a summary, so no rate was actually tested." | tee -a "$OUT/summary.txt"
  echo "This says nothing about the connector — see the logs in $OUT." | tee -a "$OUT/summary.txt"
else
  echo "No rung passed — $CONNECTOR did not sustain even ${RATES%% *}/s under these criteria" | tee -a "$OUT/summary.txt"
  echo "(based on $RUNS_WITH_DATA rung(s) that produced data)." | tee -a "$OUT/summary.txt"
  echo "Next: check dsp_failures_terminated vs dsp_failures_timeout in the summaries —" | tee -a "$OUT/summary.txt"
  echo "terminated = the connector rejected the transaction; timeout = it never got to it." | tee -a "$OUT/summary.txt"
fi
echo "Details: $OUT"
