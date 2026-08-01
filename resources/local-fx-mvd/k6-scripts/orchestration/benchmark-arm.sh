#!/usr/bin/env bash
# Run the COMPLETE campaign for one connector arm, unattended.
#
#   ./orchestration/benchmark-on.sh  <factoryx|dst|basyx>
#   ./orchestration/benchmark-off.sh <factoryx|dst|basyx>
#
# Why this exists: running the scenarios by hand means the order, the gaps and the
# env differ subtly between connectors, and those differences land in the results as
# if they were connector properties. This script fixes the sequence so all six arms
# are driven identically — the same fairness argument as the byte-identical driver.
#
# It does NOT bring the stack up or tear it down: `install.sh` and `cleanup.sh` are
# per-connector and destructive (cleanup does `down -v`). Bring the arm up first,
# run this, then take it down. Everything in between is automatic.
#
# ORDER (learned from the 2026-07-31/08-01 campaigns — see COMMANDS-CHEATSHEET §"why
# this order"):
#   smoke -> steady x2 -> soak -> payload-sweep -> catalog-sweep -> concurrency -> saturation
#   * clean scenarios first, while nothing has disturbed the provider
#   * soak early: it needs a healthy system to say anything about drift
#   * payload BEFORE catalog: catalog-sweep leaves up to 1000 assets behind
#   * ramps last: they deliberately overload and leave transfers draining
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

CONNECTOR="${1:?usage: benchmark-arm.sh <connector> <on|off>}"
ARM="${2:?usage: benchmark-arm.sh <connector> <on|off>}"
case "$ARM" in on|off) ;; *) echo "ERROR: arm must be 'on' or 'off'" >&2; exit 1 ;; esac

CONFIG_PATH="$ROOT/config/${CONNECTOR}.json"
[ -f "$CONFIG_PATH" ] || { echo "ERROR: no config $CONFIG_PATH" >&2; exit 1; }

# --- knobs -----------------------------------------------------------------
GAP="${GAP:-120}"                 # seconds between scenarios, ON TOP of run.sh's settle
REPS_STEADY="${REPS_STEADY:-2}"   # steady carries the RQ1 comparison, so it repeats
WITH_SOAK="${WITH_SOAK:-1}"
WITH_PAYLOAD="${WITH_PAYLOAD:-1}"
WITH_EXPORT="${WITH_EXPORT:-1}"
PAYLOAD_SIZES="${PAYLOAD_SIZES:-1KB 100KB 1MB 10MB 100MB}"
# Host-neutral: the repos live under ~/Thesis/EDC on the dev laptop and ~/edc on
# edc-performance, so anchor the payload files to neither. One shared copy, outside
# every repo (they are ~111 MB and regenerable).
PAYLOAD_DIR="${PAYLOAD_DIR:-$HOME/benchmark-payloads}"
PROM_URL="${PROM_URL:-$(jq -r '.prometheus.baseUrl // "http://localhost:9090"' "$CONFIG_PATH")}"

# BaSyx identity-OFF is driven by a different directory (raw-DSP, no EDC consumer).
# Setting it here is what keeps the OFF arm from silently running the ON driver.
if [ "$CONNECTOR" = "basyx" ] && [ "$ARM" = "off" ]; then
  export SCENARIO_DIR="${SCENARIO_DIR:-basyx-off}"
fi
export IDENTITY_MODE="$ARM"

# Applicability is a per-connector FACT read from config, never hardcoded here:
# BaSyx has no provider Management API (no catalog sweep) and no separate data plane
# (no payload sweep).
HAS_MGMT="$(jq -r 'if .providerManagementUrl then "yes" else "no" end' "$CONFIG_PATH")"
PAYLOAD_OK="$(jq -r 'if .payload.applicable == false then "no" else "yes" end' "$CONFIG_PATH")"
[ "$HAS_MGMT" = "yes" ] || echo "NOTE: $CONNECTOR has no provider Management API -> skipping catalog-sweep"
[ "$PAYLOAD_OK" = "yes" ] || echo "NOTE: $CONNECTOR has no separate data plane -> skipping payload-sweep"

CAMPAIGN_LOG="$ROOT/results/${CONNECTOR}/campaign-${ARM}-$(date -u +%Y-%m-%dT%H-%M-%SZ).log"
mkdir -p "$(dirname "$CAMPAIGN_LOG")"
START_ALL="$(date +%s)"

say() { echo "$(date -u +%H:%M:%S) | $*" | tee -a "$CAMPAIGN_LOG"; }

# --- preflight -------------------------------------------------------------
# Fail in seconds rather than discovering after the first 90 s health-gate timeout.
say "=== campaign: $CONNECTOR / identity-$ARM ==="
CONSUMER_URL="$(jq -r '.consumerManagementUrl // empty' "$CONFIG_PATH")"
code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$CONSUMER_URL" 2>/dev/null || true)"
if [ -z "$code" ] || [ "$code" = "000" ]; then
  say "PREFLIGHT FAIL: consumer API not answering at $CONSUMER_URL"
  say "                bring the arm up first:  ./install.sh $ARM"
  exit 3
fi
curl -sf -m 3 "$PROM_URL/-/ready" >/dev/null 2>&1 || {
  say "PREFLIGHT FAIL: Prometheus not ready at $PROM_URL"; exit 3; }
if [ -z "${CANONICAL_DIR:-}" ]; then
  say "WARNING: CANONICAL_DIR is unset -> run.sh SKIPS the harness parity gate."
  say "         Set it so a drifted driver cannot be mistaken for a connector difference:"
  say "         export CANONICAL_DIR=<path>/benchmarking-factoryx-edc/resources/local-fx-mvd/k6-scripts"
else
  "$ROOT/tools/verify-parity.sh" "$CANONICAL_DIR" >>"$CAMPAIGN_LOG" 2>&1 \
    && say "parity OK against $CANONICAL_DIR" \
    || { say "PREFLIGHT FAIL: harness parity check failed vs $CANONICAL_DIR"; exit 3; }
fi
say "preflight OK (consumer API + Prometheus)"

# --- identity bootstrap (ON arms that ship an empty Identity Hub) -----------
# Factory-X and BaSyx boot with empty hubs; the ISST EDC ships pre-signed VCs and
# needs nothing. Running it twice is harmless (the API is idempotent for our purposes).
if [ "$ARM" = "on" ] && [ -f "$ROOT/identity-setup.js" ]; then
  say "identity bootstrap (identity-setup.js)"
  k6 run "$ROOT/identity-setup.js" >>"$CAMPAIGN_LOG" 2>&1 \
    || { say "ERROR: identity bootstrap failed — see $CAMPAIGN_LOG"; exit 4; }
fi

# --- payload source --------------------------------------------------------
if [ "$WITH_PAYLOAD" = "1" ] && [ "$PAYLOAD_OK" = "yes" ]; then
  if ! curl -s -o /dev/null -m 3 "http://localhost:${PAYLOAD_PORT:-8888}/1KB.bin" 2>/dev/null; then
    say "starting payload server ($PAYLOAD_DIR)"
    "$ROOT/tools/gen-payloads.sh" serve "$PAYLOAD_DIR" >>"$CAMPAIGN_LOG" 2>&1 \
      || { say "WARNING: payload server failed to start — skipping payload-sweep"; WITH_PAYLOAD=0; }
  else
    say "payload server already serving on :${PAYLOAD_PORT:-8888}"
  fi
fi

# --- the sequence ----------------------------------------------------------
gap() {
  [ "$GAP" -gt 0 ] || return 0
  say "  … settling ${GAP}s before the next scenario"
  sleep "$GAP"
}

# run.sh exits 99 when a threshold trips — expected for the ramps, and must NOT abort
# the campaign. Only the smoke gate is fatal.
step() {
  local label="$1"; shift
  say "--> $label"
  set +e
  "$@" >>"$CAMPAIGN_LOG" 2>&1
  local rc=$?
  set -e
  say "    done (exit $rc)"
  return 0
}

# 1. GATE — if a single uncontended transaction cannot complete, nothing below means
#    anything, so this one IS fatal.
say "--> smoke (gate)"
if ! "$HERE/run.sh" "$CONNECTOR" smoke >>"$CAMPAIGN_LOG" 2>&1; then
  say "SMOKE GATE FAILED — stopping. See $CAMPAIGN_LOG"
  exit 5
fi
say "    smoke passed"
gap

# 2. RQ1 head-to-head, on an undisturbed system
step "steady x${REPS_STEADY}" "$HERE/run-matrix.sh" "$CONNECTOR" "$REPS_STEADY" steady
gap

# 3. RQ3 endurance — needs a healthy system, so it runs before anything overloads it
if [ "$WITH_SOAK" = "1" ]; then
  step "soak (30 min)" "$HERE/run.sh" "$CONNECTOR" soak
  gap
fi

# 4. RQ1 data plane — BEFORE catalog-sweep, which leaves ~1000 assets behind
if [ "$WITH_PAYLOAD" = "1" ] && [ "$PAYLOAD_OK" = "yes" ]; then
  for sz in $PAYLOAD_SIZES; do
    step "payload-sweep $sz" env PAYLOAD_SIZE="$sz" "$HERE/run.sh" "$CONNECTOR" payload-sweep
  done
  gap
fi

# 5. RQ5 catalog scaling (EDC family only — needs a Management API to seed)
if [ "$HAS_MGMT" = "yes" ]; then
  step "catalog-sweep (1/10/100/1000)" "$HERE/run-matrix.sh" "$CONNECTOR" 1 catalog-sweep
  gap
fi

# 6. RQ2 — ramps last: they overload on purpose and leave transfers draining
step "concurrency-closed" "$HERE/run-matrix.sh" "$CONNECTOR" 1 concurrency-closed
gap
step "saturation-open" "$HERE/run-matrix.sh" "$CONNECTOR" 1 saturation-open

# --- figures ---------------------------------------------------------------
# Before teardown, and before Prometheus' 7-day retention expires.
if [ "$WITH_EXPORT" = "1" ]; then
  gap
  step "export figures" "$HERE/export-panels.sh" "$CONNECTOR"
fi

# --- report ----------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START_ALL ))
say ""
say "=== campaign done: $CONNECTOR / identity-$ARM in $((ELAPSED/60)) min ==="
say "--- validity of every run (exit code is NOT the signal) ---"
# Only this arm's runs: identity_mode is the discriminator, not the folder.
for v in $(find "$ROOT/results/$CONNECTOR" -name validity.txt 2>/dev/null | sort); do
  d="$(dirname "$v")"
  [ "$(jq -r '.identity_mode' "$d/meta.json" 2>/dev/null)" = "$ARM" ] || continue
  printf '  %-19s %s\n' "$(basename "$(dirname "$d")")" "$(cat "$v")" | tee -a "$CAMPAIGN_LOG"
done
say ""
BAD=$(grep -c "past the knee\|NOT DELIVERED" "$CAMPAIGN_LOG" 2>/dev/null || true)
say "runs flagged by the validity check: ${BAD:-0} (ramps are EXPECTED to flag — they overload by design)"
say "campaign log: $CAMPAIGN_LOG"
say ""
say "Next: take the arm down (./cleanup.sh $ARM) — it wipes Prometheus, so export first."
