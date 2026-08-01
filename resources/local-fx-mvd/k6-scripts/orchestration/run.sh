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
# SCENARIO_DIR: alternate scenario dir for drivers that REPLACE the shared harness
# (the BaSyx identity-OFF raw-DSP driver in basyx-off/ has no EDC consumer).
# Running it through here gives the OFF arm the same warmup/snapshot/meta.json
# treatment as every other arm instead of a bare `k6 run`.
SCENARIO_DIR="${SCENARIO_DIR:-scenarios}"
SCRIPT="$ROOT/${SCENARIO_DIR}/${SCENARIO}.js"
[ -f "$CONFIG_PATH" ] || { echo "ERROR: no config $CONFIG_PATH"; exit 1; }
[ -f "$SCRIPT" ]      || { echo "ERROR: no scenario $SCRIPT"; exit 1; }
command -v k6   >/dev/null || { echo "ERROR: k6 not installed (https://k6.io/docs/get-started/installation/)"; exit 1; }
command -v jq   >/dev/null || { echo "ERROR: jq not installed"; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not installed"; exit 1; }

# --- knobs (env-overridable) ---
POLL_INTERVAL_MS="${POLL_INTERVAL_MS:-250}"
POLL_TIMEOUT_MS="${POLL_TIMEOUT_MS:-30000}"   # recorded: it sets the failure definition
if [ "$SCENARIO_DIR" = "scenarios" ]; then
  IDENTITY_MODE="${IDENTITY_MODE:-on}"      # G1.RQ5 factor: on|off (the DEPLOYMENT differs, not the driver)
else
  IDENTITY_MODE="${IDENTITY_MODE:-off}"     # an alternate dir IS the OFF-arm driver; never let its samples default to on
fi
CATALOG_SIZE="${CATALOG_SIZE:-1}"           # G1.RQ6: # provider assets to seed (catalog-sweep only)
WARMUP_DURATION="${WARMUP_DURATION:-60s}"
WARMUP_RATE="${WARMUP_RATE:-2}"
PROM_URL="${PROM_URL:-$(jq -r '.prometheus.baseUrl // "http://localhost:9090"' "$CONFIG_PATH")}"
PROM_RATE_WINDOW="${PROM_RATE_WINDOW:-1m}"
CANONICAL_DIR="${CANONICAL_DIR:-}"          # set to the canonical k6-scripts to enforce parity
SKIP_WARMUP="${SKIP_WARMUP:-0}"

TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
# Arm is part of the PATH, not only meta.json. ON and OFF of the same scenario used to
# land in one folder distinguishable only by reading each meta.json — error-prone for a
# study whose headline cross-analysis (X1) is exactly the ON-vs-OFF pairing.
RESULT_DIR="$ROOT/results/${CONNECTOR}/${IDENTITY_MODE}/${SCENARIO}/${TS}"
mkdir -p "$RESULT_DIR"
echo ">>> $CONNECTOR / $SCENARIO  ->  $RESULT_DIR"

# --- 1. parity check (guards the per-repo duplication risk) ---
if [ -n "$CANONICAL_DIR" ]; then
  "$ROOT/tools/verify-parity.sh" "$CANONICAL_DIR" || { echo "ERROR: parity check failed"; exit 2; }
fi

# --- 2. health gate (read-only) ---
# Shared harness: gate on the consumer Management API. Alternate driver dirs have
# no EDC consumer -> gate on the provider DSP endpoint + callback sink (.off.*).
# "Up" = any HTTP status (4xx from an unauthenticated probe still proves a listener).
if [ "$SCENARIO_DIR" = "scenarios" ]; then
  mapfile -t HEALTH_URLS < <(jq -r '[.consumerManagementUrl] | map(select(.))[]' "$CONFIG_PATH")
else
  mapfile -t HEALTH_URLS < <(jq -r '[.off.providerDspBase, (if .off.sinkPollBase then .off.sinkPollBase + "/health" else null end)] | map(select(.))[]' "$CONFIG_PATH")
fi
[ "${#HEALTH_URLS[@]}" -gt 0 ] || { echo "ERROR: no health URLs in $CONFIG_PATH for SCENARIO_DIR=$SCENARIO_DIR"; exit 3; }
# NB: on a connection failure curl ALREADY prints 000 via -w, so a `|| echo 000`
# fallback appends a second one and yields "000\n000" — which is != "000" and made a
# dead connector look healthy. Swallow curl's exit status instead of adding output.
responding() {
  local code
  code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$1" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "000" ]
}
all_up() {
  local u; for u in "${HEALTH_URLS[@]}"; do responding "$u" || return 1; done
  curl -sf -m 3 "$PROM_URL/-/ready" >/dev/null 2>&1
}
echo -n "Health: ${HEALTH_URLS[*]} + prometheus "
deadline=$(( $(date +%s) + 90 ))
until all_up; do
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
    "$ROOT/$SCENARIO_DIR/steady.js" >/dev/null 2>&1 || echo "  (warmup non-zero exit ignored)"
  rm -rf "$WARMUP_DIR"
fi

# --- 4. measured run ---
START_EPOCH="$(date -u +%s)"

# --- 4a. k6 -> Prometheus remote write ---
# ON BY DEFAULT. Without it, transaction success/failure and the time_to_* trends
# exist ONLY in k6's end-of-run summary: no Grafana panel can show a workflow
# failure while the run is happening, and a ramp cannot be analysed per stage at
# all (the first campaign lost the saturation knee this way). Probe first so a
# Prometheus without --web.enable-remote-write-receiver degrades to a warning
# instead of failing the run.
RW_ARGS=()
K6_PROMETHEUS_RW_SERVER_URL="${K6_PROMETHEUS_RW_SERVER_URL:-${PROM_URL}/api/v1/write}"
RW_STATUS="disabled"
if [ "${K6_REMOTE_WRITE:-1}" = "1" ]; then
  # An empty POST to a live receiver is rejected as a bad protobuf (400), while a
  # Prometheus without the flag 404s. Anything but 404/000 means it is listening.
  rw_code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' -X POST "$K6_PROMETHEUS_RW_SERVER_URL" || echo 000)"
  if [ "$rw_code" != "404" ] && [ "$rw_code" != "000" ]; then
    export K6_PROMETHEUS_RW_SERVER_URL
    export K6_PROMETHEUS_RW_TREND_STATS="${K6_PROMETHEUS_RW_TREND_STATS:-p(50),p(95),p(99),max,count}"
    RW_ARGS=(--out experimental-prometheus-rw)
    RW_STATUS="$K6_PROMETHEUS_RW_SERVER_URL"
    echo "k6 -> Prometheus remote-write: $K6_PROMETHEUS_RW_SERVER_URL"
  else
    echo "WARNING: Prometheus at $K6_PROMETHEUS_RW_SERVER_URL has no remote-write receiver (HTTP $rw_code)."
    echo "         Add '--web.enable-remote-write-receiver' to the prometheus command in the compose file."
    echo "         Continuing WITHOUT k6 time series — only the end-of-run summary will exist."
    RW_STATUS="unavailable_http_${rw_code}"
  fi
fi
set +e
k6 run \
  -e CONNECTOR="$CONNECTOR" -e SCENARIO="$SCENARIO" -e RESULT_DIR="$RESULT_DIR" -e POLL_INTERVAL_MS="$POLL_INTERVAL_MS" \
  -e POLL_TIMEOUT_MS="$POLL_TIMEOUT_MS" \
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

# --- 5b. connector logs for the run window ---
# Metrics say a transaction failed; only the connector log says WHY (rejected
# policy vs. exhausted pool vs. state-machine backlog). The first campaign kept no
# logs, so a 100%-failure run could not be diagnosed after the fact. Scoped to the
# SUT services from config and to the run window, so this stays small.
LOG_DIR="$RESULT_DIR/logs"
mkdir -p "$LOG_DIR"
if command -v docker >/dev/null 2>&1; then
  while read -r svc; do
    [ -n "$svc" ] || continue
    # Container names may carry a compose project prefix; match on substring.
    cid="$(docker ps -a --filter "name=$svc" --format '{{.Names}}' | head -1)"
    [ -n "$cid" ] || continue
    docker logs --since "$START_EPOCH" --until "$END_EPOCH" "$cid" >"$LOG_DIR/$svc.log" 2>&1 || true
  done < <(jq -r '.services.sut[]?' "$CONFIG_PATH")
  echo "  logs -> $LOG_DIR ($(ls -1 "$LOG_DIR" 2>/dev/null | wc -l) files)"
  # Cheap post-run error census; a spike here localizes the failure immediately.
  grep -ciE "error|exception|timeout" "$LOG_DIR"/*.log 2>/dev/null | sed 's|.*/|    |' || true
fi

# --- 6. meta.json (params + provenance) ---
# HARNESS_HASH is the evidence behind the fairness claim: identical driver bytes
# across all three repos. Recording it per run means a reviewer can verify that a
# given result was produced by the audited driver, not by a drifted copy.
HARNESS_HASH="$(cat "$ROOT"/lib/*.js "$ROOT/$SCENARIO_DIR"/*.js 2>/dev/null | md5sum | cut -d' ' -f1)"
# Stack age: every run inherits the DB state of previous runs on the same stack.
# Without this, order effects are invisible after the fact.
PROVIDER_SVC="$(jq -r '.services.provider[0] // .services.sut[0] // empty' "$CONFIG_PATH")"
STACK_STARTED="$(docker inspect -f '{{.State.StartedAt}}' "$PROVIDER_SVC" 2>/dev/null || echo unknown)"

jq -n \
  --arg connector "$CONNECTOR" --arg scenario "$SCENARIO" --arg sdir "$SCENARIO_DIR" --arg ts "$TS" \
  --arg poll "$POLL_INTERVAL_MS" --arg polltimeout "$POLL_TIMEOUT_MS" \
  --arg start "$START_EPOCH" --arg end "$END_EPOCH" \
  --arg idmode "$IDENTITY_MODE" --arg catsize "$CATALOG_SIZE" \
  --arg promwin "$PROM_RATE_WINDOW" --arg promurl "$PROM_URL" \
  --arg k6ver "$(k6 version 2>/dev/null | head -1)" --arg k6exit "$K6_EXIT" \
  --arg gitsha "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo n/a)" \
  --arg dirty "$(git -C "$ROOT" status --porcelain 2>/dev/null | head -1 | grep -q . && echo true || echo false)" \
  --arg rw "$RW_STATUS" \
  --arg warmdur "$WARMUP_DURATION" --arg warmrate "$WARMUP_RATE" --arg skipwarm "$SKIP_WARMUP" \
  --arg harness "$HARNESS_HASH" --arg stackstart "$STACK_STARTED" \
  '{connector:$connector, scenario:$scenario, scenario_dir:$sdir, run_id:$ts,
    poll_interval_ms:($poll|tonumber), poll_timeout_ms:($polltimeout|tonumber),
    identity_mode:$idmode, catalog_size:($catsize|tonumber),
    start_epoch:($start|tonumber), end_epoch:($end|tonumber),
    warmup:{duration:$warmdur, rate:($warmrate|tonumber), skipped:($skipwarm=="1")},
    prometheus:{url:$promurl, rate_window:$promwin, remote_write:$rw},
    k6:{version:$k6ver, exit_code:($k6exit|tonumber)},
    git_sha:$gitsha, git_dirty:($dirty=="true"), harness_hash:$harness, stack_started_at:$stackstart,
    env:{RATE:(env.RATE//null), DURATION:(env.DURATION//null), MAX_VUS:(env.MAX_VUS//null),
         PREALLOCATED_VUS:(env.PREALLOCATED_VUS//null), VUS:(env.VUS//null),
         STAGE_DURATION:(env.STAGE_DURATION//null), RATES:(env.RATES//null), VU_STAGES:(env.VU_STAGES//null),
         PAYLOAD_SIZE:(env.PAYLOAD_SIZE//null), PAYLOAD_BYTES:(env.PAYLOAD_BYTES//null),
         PAYLOAD_URL:(env.PAYLOAD_URL//null)}}' \
  > "$RESULT_DIR/meta.json"

# --- 6b. settle before the next run ---
# A run that pushed the connector past its knee leaves in-flight transfers draining
# for minutes. On 2026-07-31 a concurrency run started 67 s after a saturation ramp
# ended, hit the leftover backlog, and aborted with 2/2 failures; the same run three
# minutes later was clean (1130/1130). Carry-over is an ordering confound, so wait it
# out rather than randomising over it. Only after runs that actually stressed the
# system — a clean steady run needs no gap.
SETTLE_SECONDS="${SETTLE_SECONDS:-60}"
if [ "$SETTLE_SECONDS" -gt 0 ] && [ -f "$RESULT_DIR/k6-summary.json" ]; then
  needs_settle="$(jq -r '
    ((.metrics.dsp_transactions_failed.values.count // 0) as $bad
     | (.metrics.dsp_transactions_succeeded.values.count // 0) as $ok
     | if ($ok+$bad) > 0 and ($bad / ($ok+$bad)) > 0.05 then "yes" else "no" end)' \
    "$RESULT_DIR/k6-summary.json" 2>/dev/null || echo no)"
  case "$SCENARIO" in saturation-open|concurrency-closed) needs_settle=yes ;; esac
  if [ "$needs_settle" = "yes" ]; then
    echo "Settling ${SETTLE_SECONDS}s (this run stressed the connector; the next one must not inherit its backlog)"
    sleep "$SETTLE_SECONDS"
  fi
fi

# --- 7. validity verdict (printed, and cheap to grep across a campaign) ---
# Exit 0 does NOT mean the run is usable: the ramp scenarios carry abort-only
# thresholds, so a run that failed 40% of its transactions still exits 0. These
# three numbers decide whether the data describes the connector or the queue.
if [ -f "$RESULT_DIR/k6-summary.json" ]; then
  jq -r '
    (.metrics.dsp_transactions_succeeded.values.count // 0) as $ok
    | (.metrics.dsp_transactions_failed.values.count // 0) as $bad
    | (.metrics.dropped_iterations.values.count // 0) as $drop
    | "VALIDITY  ok=\($ok)  failed=\($bad)  failed_rate=\((($bad / (if ($ok+$bad)>0 then ($ok+$bad) else 1 end)) * 100 | floor))%  dropped_iterations=\($drop)"
      + (if $drop > 0 then "  <-- OFFERED RATE NOT DELIVERED (raise MAX_VUS or lower RATE)" else "" end)
      + (if ($ok+$bad) > 0 and ($bad / ($ok+$bad)) > 0.05 then "  <-- >5% FAILURES: past the knee, not a valid operating point" else "" end)
  ' "$RESULT_DIR/k6-summary.json" | tee "$RESULT_DIR/validity.txt"
fi

echo ">>> done: $RESULT_DIR  (k6 exit $K6_EXIT)"
exit "$K6_EXIT"
