#!/usr/bin/env bash
# Run ONE benchmark experiment end-to-end for one connector + scenario.
#
#   parity-check -> health-gate -> warmup(discarded) -> measured run -> Prometheus snapshot -> meta.json
#
# Everything lands in an immutable per-run folder so every thesis figure is
# reproducible and traceable. Usage:
#   ./orchestration/run.sh <connector> <scenario>
#   CONNECTOR knobs via env: POLL_INTERVAL_MS, RATE, DURATION, MAX_VUS, PAYLOAD_SIZE, ...
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"   # k6-scripts/
cd "$ROOT"

CONNECTOR="${1:?usage: run.sh <connector> <scenario>}"
SCENARIO="${2:?usage: run.sh <connector> <scenario>}"
CONFIG_PATH="$ROOT/config/${CONNECTOR}.json"
SCRIPT="$ROOT/scenarios/${SCENARIO}.js"
[ -f "$CONFIG_PATH" ] || { echo "ERROR: no config $CONFIG_PATH"; exit 1; }
[ -f "$SCRIPT" ]      || { echo "ERROR: no scenario $SCRIPT"; exit 1; }
command -v k6   >/dev/null || { echo "ERROR: k6 not installed (https://k6.io/docs/get-started/installation/)"; exit 1; }
command -v jq   >/dev/null || { echo "ERROR: jq not installed"; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not installed"; exit 1; }

# --- knobs (env-overridable) ---
POLL_INTERVAL_MS="${POLL_INTERVAL_MS:-250}"
IDENTITY_MODE="${IDENTITY_MODE:-on}"        # G1.RQ5 factor: on|off (the DEPLOYMENT differs, not the driver)
CATALOG_SIZE="${CATALOG_SIZE:-1}"           # G1.RQ6: # provider assets to seed (catalog-sweep only)
WARMUP_DURATION="${WARMUP_DURATION:-60s}"
WARMUP_RATE="${WARMUP_RATE:-2}"
PROM_URL="${PROM_URL:-$(jq -r '.prometheus.baseUrl // "http://localhost:9090"' "$CONFIG_PATH")}"
PROM_RATE_WINDOW="${PROM_RATE_WINDOW:-1m}"
CANONICAL_DIR="${CANONICAL_DIR:-}"          # set to the canonical k6-scripts to enforce parity
SKIP_WARMUP="${SKIP_WARMUP:-0}"

TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
RESULT_DIR="$ROOT/results/${CONNECTOR}/${SCENARIO}/${TS}"
mkdir -p "$RESULT_DIR"
echo ">>> $CONNECTOR / $SCENARIO  ->  $RESULT_DIR"

# --- 1. parity check (guards the per-repo duplication risk) ---
if [ -n "$CANONICAL_DIR" ]; then
  "$ROOT/tools/verify-parity.sh" "$CANONICAL_DIR" || { echo "ERROR: parity check failed"; exit 2; }
fi

# --- 2. health gate (read-only) ---
CONSUMER_MGMT="$(jq -r '.consumerManagementUrl' "$CONFIG_PATH")"
echo -n "Health: consumer mgmt + prometheus "
deadline=$(( $(date +%s) + 90 ))
until [ "$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$CONSUMER_MGMT" || echo 000)" != "000" ] \
   && curl -sf -m 3 "$PROM_URL/-/ready" >/dev/null 2>&1; do
  [ "$(date +%s)" -ge "$deadline" ] && { echo "- TIMEOUT (is the stack up? is Prometheus at $PROM_URL?)"; exit 3; }
  echo -n "."; sleep 2
done
echo " OK"

# --- 3. warmup (DISCARDED: JVM JIT + cold caches; not in the measured window) ---
if [ "$SKIP_WARMUP" != "1" ]; then
  echo "Warmup ${WARMUP_DURATION} @ ${WARMUP_RATE}/s (discarded)"
  WARMUP_DIR="$(mktemp -d)"
  k6 run --quiet \
    -e CONNECTOR="$CONNECTOR" -e SCENARIO=warmup -e RATE="$WARMUP_RATE" -e DURATION="$WARMUP_DURATION" \
    -e POLL_INTERVAL_MS="$POLL_INTERVAL_MS" -e IDENTITY_MODE="$IDENTITY_MODE" -e RESULT_DIR="$WARMUP_DIR" \
    --tag phase=warmup \
    "$ROOT/scenarios/steady.js" >/dev/null 2>&1 || echo "  (warmup non-zero exit ignored)"
  rm -rf "$WARMUP_DIR"
fi

# --- 4. measured run ---
START_EPOCH="$(date -u +%s)"
RW_ARGS=()
if [ -n "${K6_PROMETHEUS_RW_SERVER_URL:-}" ]; then
  RW_ARGS=(--out experimental-prometheus-rw)   # needs Prometheus --web.enable-remote-write-receiver
  echo "k6 -> Prometheus remote-write: ${K6_PROMETHEUS_RW_SERVER_URL}"
fi
set +e
k6 run \
  -e CONNECTOR="$CONNECTOR" -e SCENARIO="$SCENARIO" -e RESULT_DIR="$RESULT_DIR" -e POLL_INTERVAL_MS="$POLL_INTERVAL_MS" \
  -e IDENTITY_MODE="$IDENTITY_MODE" -e CATALOG_SIZE="$CATALOG_SIZE" \
  --tag connector="$CONNECTOR" --tag scenario="$SCENARIO" --tag run_id="$TS" --tag identity_mode="$IDENTITY_MODE" \
  "${RW_ARGS[@]}" \
  "$SCRIPT" 2>&1 | tee "$RESULT_DIR/run.log"
K6_EXIT="${PIPESTATUS[0]}"
set -e
sleep 15  # post-roll so the final 5s scrape lands inside the window
END_EPOCH="$(date -u +%s)"

# --- 5. Prometheus snapshot (server-side metrics, time-aligned to the run) ---
"$ROOT/orchestration/snapshot-prom.sh" "$START_EPOCH" "$END_EPOCH" "$RESULT_DIR" "$CONFIG_PATH" "$PROM_URL" "$PROM_RATE_WINDOW" \
  || echo "  (Prometheus snapshot failed — server CSVs may be empty)"

# --- 6. meta.json (params + provenance) ---
jq -n \
  --arg connector "$CONNECTOR" --arg scenario "$SCENARIO" --arg ts "$TS" \
  --arg poll "$POLL_INTERVAL_MS" --arg start "$START_EPOCH" --arg end "$END_EPOCH" \
  --arg idmode "$IDENTITY_MODE" --arg catsize "$CATALOG_SIZE" \
  --arg promwin "$PROM_RATE_WINDOW" --arg promurl "$PROM_URL" \
  --arg k6ver "$(k6 version 2>/dev/null | head -1)" --arg k6exit "$K6_EXIT" \
  --arg gitsha "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo n/a)" \
  --arg rw "${K6_PROMETHEUS_RW_SERVER_URL:-none}" \
  '{connector:$connector, scenario:$scenario, run_id:$ts,
    poll_interval_ms:($poll|tonumber), identity_mode:$idmode, catalog_size:($catsize|tonumber),
    start_epoch:($start|tonumber), end_epoch:($end|tonumber),
    prometheus:{url:$promurl, rate_window:$promwin, remote_write:$rw},
    k6:{version:$k6ver, exit_code:($k6exit|tonumber)}, git_sha:$gitsha,
    env:{RATE:(env.RATE//null), DURATION:(env.DURATION//null), MAX_VUS:(env.MAX_VUS//null), PAYLOAD_SIZE:(env.PAYLOAD_SIZE//null)}}' \
  > "$RESULT_DIR/meta.json"

echo ">>> done: $RESULT_DIR  (k6 exit $K6_EXIT)"
exit "$K6_EXIT"
