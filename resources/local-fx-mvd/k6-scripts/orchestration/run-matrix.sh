#!/usr/bin/env bash
# Run the experiment matrix for ONE connector: each scenario × N repetitions,
# sequentially, in randomized order (to break ordering/thermal bias — see
# methodology §A2). NEVER run connectors in parallel: they share the host and
# Prometheus, which would cross-contaminate.
#
#   run-matrix.sh <connector> [reps] [scenario ...]
#   defaults: reps=2, scenarios="smoke steady saturation-open concurrency-closed"
#
# REPS=2 is a wall-clock compromise (~40 min/arm cheaper than 3, ~4 h over the six
# arms). It costs statistical power: two points give a median that is just their
# mean and an interquartile range that is not meaningful, so a scenario reported
# with n=2 cannot carry a variability claim. For the head-to-head RQ1 comparison,
# run `steady` at 3 separately -- it is the cheapest of the long scenarios and the
# one whose spread actually gets reported:
#   ./orchestration/run-matrix.sh <connector> 3 steady
# Alternative if wall clock is the binding constraint: keep 3 reps and shorten the
# windows instead (STAGE_DURATION=90s DURATION=5m), which costs about the same time
# as dropping to 2 but preserves the repetition count.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

CONNECTOR="${1:?usage: run-matrix.sh <connector> [reps] [scenario ...]}"; shift || true
REPS="${1:-2}"; shift || true
SCENARIOS=("$@")
[ "${#SCENARIOS[@]}" -eq 0 ] && SCENARIOS=(smoke steady saturation-open concurrency-closed)
CATALOG_SIZES="${CATALOG_SIZES:-1 10 100 1000}"   # G1.RQ6: catalog-sweep is run once per size

shuffle() { if command -v shuf >/dev/null; then printf '%s\n' "$@" | shuf; else printf '%s\n' "$@"; fi; }

echo "Matrix: connector=$CONNECTOR reps=$REPS scenarios=[${SCENARIOS[*]}]"
INDEX="$ROOT/results/${CONNECTOR}/matrix-$(date -u +%Y-%m-%dT%H-%M-%SZ).log"
mkdir -p "$(dirname "$INDEX")"

for rep in $(seq 1 "$REPS"); do
  echo "===== repetition $rep/$REPS ====="
  while read -r sc; do
    echo "----- $CONNECTOR / $sc (rep $rep) -----" | tee -a "$INDEX"
    # Don't abort the whole matrix if one run aborts (e.g. saturation hits the knee).
    # catalog-sweep (G1.RQ6) is run once per catalog size. IDENTITY_MODE (G1.RQ5) is
    # inherited from the env and applies to the whole matrix — run it twice (off, then
    # on) against the matching connector deployment to get the identity-overhead delta.
    if [ "$sc" = "catalog-sweep" ]; then
      for cs in $CATALOG_SIZES; do
        CATALOG_SIZE="$cs" "$HERE/run.sh" "$CONNECTOR" "$sc" 2>&1 | tee -a "$INDEX" || echo "  ($sc size=$cs rep $rep non-zero)" | tee -a "$INDEX"
      done
    else
      "$HERE/run.sh" "$CONNECTOR" "$sc" 2>&1 | tee -a "$INDEX" || echo "  ($sc rep $rep exited non-zero)" | tee -a "$INDEX"
    fi
  done < <(shuffle "${SCENARIOS[@]}")
done

echo "Matrix done. Index: $INDEX"
echo "TIP: aggregate the per-run k6-summary.json across reps into median+IQR before plotting."
