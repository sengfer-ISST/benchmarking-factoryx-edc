#!/usr/bin/env bash
# Export Grafana panels as PNGs, one file per (connector, arm, scenario, panel).
#
# Replaces the manual screenshot chore: screenshot-urls.sh gives you links to click,
# this renders them server-side. Grafana's /render/d-solo endpoint pins the exact
# measured window from each run's meta.json (start_epoch..end_epoch — warm-up already
# stripped), so the images match the numbers in k6-summary.json by construction.
#
#   ./orchestration/export-panels.sh                    # every connector/arm/scenario
#   ./orchestration/export-panels.sh factoryx           # one connector
#   ./orchestration/export-panels.sh factoryx steady    # one connector + scenario
#
# Output: figures/<connector>_<arm>_<scenario>_<panel>.png  (drop straight into LaTeX)
#
# REQUIREMENTS
#   - grafana-image-renderer must be running (added to every compose file 2026-07-30).
#     Without it Grafana answers the /render endpoint with a plugin error; this script
#     detects that and tells you rather than writing broken PNGs.
#   - Prometheus retention is 7 days: export within a week of the run, and BEFORE
#     cleanup.sh (which does `down -v`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

CONNECTOR="${1:-}"; SCENARIO="${2:-}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GF_USER="${GF_USER:-admin}"; GF_PASS="${GF_PASS:-admin}"
OUTDIR="${OUTDIR:-$ROOT/figures}"
THEME="${THEME:-light}"           # light = print-friendly; the thesis figures want this
WIDTH="${WIDTH:-1200}"; HEIGHT="${HEIGHT:-450}"
ALL_RUNS="${ALL_RUNS:-0}"         # 0 = newest run per combination (one figure each)
PAD="${PAD:-15}"                  # seconds of context either side of the window

# --- what to export --------------------------------------------------------
# PROFILE=thesis (default): each scenario exports ONLY the panels its research
#   question needs — the §5 Scenario-to-RQ map in COMMANDS-CHEATSHEET.md. Exporting
#   all ten panels for every run produces mostly figures nobody puts in a thesis.
# PROFILE=all: every panel for every run (the old behaviour, for exploration).
# PANELS="uid:id:slug …": explicit override, wins over both.
#
# Panel reference — edc-api-red: 200 tx outcome, 201 failures by reason,
#   202 polls/tx, 203 async phase latency, 4 API latency percentiles,
#   1 request rate, 6 heap, 7 GC, 8 threads.  rYdddlPWk: 77 CPU, 78 memory.
PROFILE="${PROFILE:-thesis}"

ALL_PANELS="edc-api-red:200:tx-outcome edc-api-red:203:async-latency \
edc-api-red:202:polls-per-tx edc-api-red:4:api-latency edc-api-red:1:request-rate \
edc-api-red:6:jvm-heap edc-api-red:7:jvm-gc edc-api-red:8:jvm-threads \
rYdddlPWk:77:host-cpu rYdddlPWk:78:host-mem"

# Per-scenario sets. `smoke` is deliberately empty: it is a pass/fail gate, not a
# figure. Every panel listed here earns its place in a chapter.
panels_for() {
  case "$1" in
    smoke)              echo "" ;;                                    # gate only
    # RQ1 head-to-head + RQ4 async cycle + one resource profile at the operating point
    steady)             echo "edc-api-red:200:tx-outcome edc-api-red:203:async-latency \
edc-api-red:4:api-latency edc-api-red:6:jvm-heap" ;;
    # RQ2 open model: the knee. host-cpu proves the knee is the connector, not the box.
    saturation-open)    echo "edc-api-red:200:tx-outcome edc-api-red:4:api-latency \
edc-api-red:1:request-rate edc-api-red:202:polls-per-tx rYdddlPWk:77:host-cpu" ;;
    # RQ2 closed model, reported beside the open one
    concurrency-closed) echo "edc-api-red:200:tx-outcome edc-api-red:4:api-latency \
edc-api-red:1:request-rate" ;;
    # RQ5: catalog latency against catalog size — one panel, one figure per size
    catalog-sweep)      echo "edc-api-red:4:api-latency" ;;
    # RQ1 data plane: throughput against payload size
    payload-sweep)      echo "edc-api-red:1:request-rate edc-api-red:4:api-latency" ;;
    # RQ3 endurance: drift over the window is the whole point
    soak)               echo "edc-api-red:6:jvm-heap edc-api-red:7:jvm-gc \
edc-api-red:8:jvm-threads rYdddlPWk:78:host-mem" ;;
    *)                  echo "$ALL_PANELS" ;;
  esac
}

command -v jq   >/dev/null || { echo "ERROR: jq not installed" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not installed" >&2; exit 1; }
[ -d "$ROOT/results" ] || { echo "ERROR: no results/ under $ROOT" >&2; exit 1; }
mkdir -p "$OUTDIR"

# --- preflight: is the renderer actually there? ----------------------------
# A missing plugin still returns HTTP 500 with a text body, so probing once up front
# beats writing 60 files of error text.
# NB: no `|| echo 000` — curl -w already emits 000 on a connection failure and the
# extra echo would make it "000000", which compares unequal to "000" and hides the error.
probe="$(curl -s -u "$GF_USER:$GF_PASS" -o /tmp/.gf_probe.$$ -w '%{http_code}' \
  "$GRAFANA_URL/render/d-solo/edc-api-red/x?panelId=1&from=now-5m&to=now&width=100&height=100" 2>/dev/null || true)"
if [ -z "$probe" ] || [ "$probe" = "000" ]; then
  echo "ERROR: cannot reach Grafana at $GRAFANA_URL" >&2; rm -f /tmp/.gf_probe.$$; exit 2
fi
if [ "$probe" != "200" ] || ! head -c4 /tmp/.gf_probe.$$ 2>/dev/null | grep -q 'PNG'; then
  echo "ERROR: Grafana did not return a PNG (HTTP $probe)." >&2
  echo "       Body: $(head -c 200 /tmp/.gf_probe.$$ 2>/dev/null)" >&2
  echo "       Most likely the image renderer is not running. Check:" >&2
  echo "         docker compose -f <compose-file> ps grafana-renderer" >&2
  rm -f /tmp/.gf_probe.$$; exit 2
fi
rm -f /tmp/.gf_probe.$$
echo "renderer OK -> $OUTDIR (profile=$PROFILE theme=$THEME ${WIDTH}x${HEIGHT})"

# --- pick the runs ---------------------------------------------------------
# Newest run per (connector, arm, scenario) unless ALL_RUNS=1: for a thesis figure you
# want one representative image, not one per repetition.
mapfile -t METAS < <(find "$ROOT/results" -name meta.json | sort)
declare -A SEEN
count=0; failed=0; skipped=0

for m in "${METAS[@]}"; do
  c="$(jq -r '.connector' "$m")"; sc="$(jq -r '.scenario' "$m")"
  arm="$(jq -r '.identity_mode' "$m")"; run="$(jq -r '.run_id' "$m")"
  from="$(jq -r '.start_epoch' "$m")"; to="$(jq -r '.end_epoch' "$m")"
  cat_size="$(jq -r '.catalog_size // 1' "$m")"; pay="$(jq -r '.env.PAYLOAD_SIZE // empty' "$m")"

  [ -n "$CONNECTOR" ] && [ "$c" != "$CONNECTOR" ] && continue
  [ -n "$SCENARIO" ]  && [ "$sc" != "$SCENARIO" ]  && continue
  [ "$from" = "null" ] || [ "$to" = "null" ] && continue

  # Sweeps vary a factor per run, so the factor belongs in the key AND the filename —
  # otherwise the four catalog sizes overwrite each other.
  variant=""
  [ "$sc" = "catalog-sweep" ] && variant="-cat${cat_size}"
  [ "$sc" = "payload-sweep" ] && [ -n "$pay" ] && variant="-${pay}"

  key="${c}_${arm}_${sc}${variant}"
  if [ "$ALL_RUNS" != "1" ]; then
    [ -n "${SEEN[$key]:-}" ] && continue      # metas are sorted, so this keeps the newest
    SEEN[$key]=1
  else
    key="${key}_${run}"
  fi

  # Resolve the panel set for THIS scenario.
  if [ -n "${PANELS:-}" ];      then set_for_run="$PANELS"
  elif [ "$PROFILE" = "all" ];  then set_for_run="$ALL_PANELS"
  else                               set_for_run="$(panels_for "$sc")"
  fi
  if [ -z "$set_for_run" ]; then
    skipped=$((skipped+1)); continue          # e.g. smoke: a gate, not a figure
  fi

  fromms=$(( (from - PAD) * 1000 )); toms=$(( (to + PAD) * 1000 ))

  for spec in $set_for_run; do
    uid="${spec%%:*}"; rest="${spec#*:}"; pid="${rest%%:*}"; slug="${rest##*:}"
    out="$OUTDIR/${key}_${slug}.png"
    code="$(curl -s -u "$GF_USER:$GF_PASS" -o "$out" -w '%{http_code}' \
      "$GRAFANA_URL/render/d-solo/$uid/x?orgId=1&panelId=$pid&from=$fromms&to=$toms&width=$WIDTH&height=$HEIGHT&theme=$THEME&tz=UTC" \
      2>/dev/null || true)"
    if [ "$code" = "200" ] && head -c4 "$out" | grep -q 'PNG'; then
      count=$((count+1)); printf '  %s\n' "${out#$ROOT/}"
    else
      rm -f "$out"; failed=$((failed+1))
      echo "  FAILED (HTTP $code) $uid/$pid for $key" >&2
    fi
  done
done

echo
echo "exported $count panel(s) to $OUTDIR${failed:+, $failed failed}${skipped:+, $skipped run(s) skipped as gates}"
[ "$count" -eq 0 ] && { echo "Nothing exported — is Prometheus still holding these windows (7d retention)?" >&2; exit 1; }
cat <<EOF

Use in LaTeX:
  \\includegraphics[width=\\textwidth]{figures/factoryx_on_steady_async-latency}
Export one connector/scenario only:  $0 factoryx steady
Every repetition instead of newest:  ALL_RUNS=1 $0
Every panel for every run:           PROFILE=all $0
A specific panel set:                PANELS="edc-api-red:200:tx-outcome" $0
EOF
