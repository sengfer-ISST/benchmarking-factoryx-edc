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
THEME="${THEME:-dark}"            # THEME=light for a print-oriented variant
WIDTH="${WIDTH:-1200}"; HEIGHT="${HEIGHT:-450}"
ALL_RUNS="${ALL_RUNS:-0}"         # 0 = one figure per combination (the first repetition)
PAD="${PAD:-15}"                  # seconds of context either side of the window

# --- what to export --------------------------------------------------------
# PROFILE=thesis (default): FOUR panels per arm. These images are not the
#   measurement — the measurement of record is the k6 summary and the Prometheus
#   snapshot CSVs, and every number in the results chapter comes from those. Their
#   job is narrower: to show that the campaign was actually executed and that the
#   system behaved as the tables claim. Anything a table or a pgfplots chart states
#   better does not earn a screenshot, which is why the sweeps export nothing: a
#   catalog or payload curve is four or five numbers, and four or five dashboard
#   images say it worse than one table row each.
#   The earlier profile exported ~30 images per arm (~180 for a campaign), of which
#   the great majority were per-size sweep panels nobody would print.
# PROFILE=all: every panel for every run — exploration and debugging, not the thesis.
# PANELS="uid:id:slug …": explicit override, wins over both.
#
# Panel reference — edc-api-red: 200 tx outcome, 201 failures by reason,
#   202 polls/tx, 203 async phase latency, 4 API latency percentiles,
#   1 request rate, 6 heap, 7 GC, 8 threads.  rYdddlPWk: 77 CPU, 78 memory.
PROFILE="${PROFILE:-thesis}"

# --- dashboard template variables ------------------------------------------
# /render/d-solo does NOT resolve a dashboard's template variables for you when the
# provisioned JSON carries no saved `current` value — and neither dashboard here does.
# The renderer then has to run each variable's own query, and node-exporter's are
# CHAINED (job -> nodename -> node), which is where headless rendering falls over.
#
# The failure is silent and total: panel 77 filters on instance="$node" with an EXACT
# match, so an unresolved variable becomes instance="" and the panel renders empty
# rather than erroring. edc-api-red's $service is a regex match, so it degrades the
# same way but only on the panels that use it (jvm-heap).
#
# Passing the values explicitly removes the renderer's guesswork entirely. Defaults
# come from monitoring/prometheus/prometheus.yml: job_name node-exporter scraping
# node-exporter:9100. Override if that scrape config ever changes.
NODE_JOB="${NODE_JOB:-node-exporter}"
NODE_INSTANCE="${NODE_INSTANCE:-node-exporter:9100}"

# `service` on edc-api-red is multi-value with allValue unset, and its panels use it as
# service_name=~"$service". A REGEX-MATCH position makes Grafana interpolate through its
# regex formatter, which ESCAPES special characters — so passing ".*" arrives as "\.\*"
# and matches nothing. (Tried on 2026-08-10: every $service panel came back empty while
# the node-exporter panels, which take literal values, rendered fine.)
#
# So pass the real service names instead. They need no escaping, and each run already
# archived them: http-p95.csv's `series` column is exactly the set of instrumented
# runtimes that reported during that window. Deriving them per run also means a
# connector with different service names needs no configuration here.
SERVICE_PARAMS=""     # rebuilt per run, just before rendering

vars_for() {
  case "$1" in
    # Fall back to the All sentinel if the CSV was missing; better than a bad regex.
    edc-api-red) printf '%s' "${SERVICE_PARAMS:-&var-service=%24__all}" ;;
    rYdddlPWk)   printf '&var-job=%s&var-node=%s' "$NODE_JOB" "$NODE_INSTANCE" ;;
  esac
}

# Build &var-service=<name> for every runtime that reported in this run's window.
service_params_from() {
  local csv="$1/http-p95.csv" out="" s
  [ -f "$csv" ] || { printf ''; return; }
  while IFS= read -r s; do
    [ -n "$s" ] && out="${out}&var-service=${s}"
  done < <(tail -n +2 "$csv" | cut -d, -f1 | tr -d '"' | sort -u)
  printf '%s' "$out"
}

ALL_PANELS="edc-api-red:200:tx-outcome edc-api-red:203:async-latency \
edc-api-red:202:polls-per-tx edc-api-red:4:api-latency edc-api-red:1:request-rate \
edc-api-red:6:jvm-heap edc-api-red:7:jvm-gc edc-api-red:8:jvm-threads \
rYdddlPWk:77:host-cpu rYdddlPWk:78:host-mem"

# Per-scenario sets, organised BY RESEARCH QUESTION. Each slug carries the RQ it
# answers, so `ls figures/` groups by thesis section and a figure can be dropped
# straight into the section that argues from it.
#
# The panel is chosen for what it SHOWS that a table cannot. A median belongs in a
# table; a curve over time — load rising, failures starting, heap climbing — is a
# picture. Where a result is a curve ACROSS runs rather than within one (the catalog
# and payload sweeps), no single panel can show it and the figure has to be a
# pgfplots chart built from the exported CSVs instead; see the notes below.
#
# ~15 images per arm. Export one connector for the thesis (§7) and keep the rest as
# evidence that the campaign ran.
panels_for() {
  case "$1" in
    # --- RQ1: latency and throughput at the operating point -----------------
    # 200 delivered tx/s over the window        -> the throughput claim
    # 203 p95 time-to-agreed / time-to-EDR / e2e -> the latency claim, and RQ4's
    #     phase split in one picture
    # 4   server-side latency percentiles        -> the connector's own view, beside
    #     the client's, which is what corroborates each number
    # 202 polls per transaction                  -> RQ4: the observer effect the
    #     latency figures have to be read net of
    steady)             echo "edc-api-red:200:rq1-tx-outcome \
edc-api-red:203:rq1-async-latency edc-api-red:4:rq1-api-latency \
edc-api-red:202:rq4-polls-per-tx" ;;

    # --- RQ2: behaviour as offered load rises (open model) ------------------
    # 200 success giving way to failure rung by rung -> the onset of failure
    # 4   latency percentiles climbing               -> the knee itself
    # 201 failures by phase and reason               -> WHERE it breaks, which is
    #     what separates a capacity limit from a rejection
    # 77  host CPU with headroom to spare            -> the control that makes the
    #     knee a property of the connector rather than of the machine
    saturation-open)    echo "edc-api-red:200:rq2-tx-outcome \
edc-api-red:4:rq2-api-latency edc-api-red:201:rq2-failures-by-reason \
rYdddlPWk:77:rq2-host-cpu" ;;

    # --- RQ2: the closed-model companion ------------------------------------
    # Reported beside the open model, never alone: agreement between the two is what
    # makes the ceiling a property of the connector rather than of one workload model.
    concurrency-closed) echo "edc-api-red:200:rq2-closed-tx-outcome \
edc-api-red:4:rq2-closed-api-latency" ;;

    # --- RQ3: resource profile and long-run drift ---------------------------
    # Whether a series is stationary or climbing is exactly what a fitted slope in a
    # table cannot show, and it is the whole question the soak exists to answer.
    soak)               echo "edc-api-red:6:rq3-jvm-heap edc-api-red:7:rq3-jvm-gc \
edc-api-red:8:rq3-jvm-threads rYdddlPWk:78:rq3-host-mem" ;;

    # --- RQ5: catalog scaling (illustration only) ---------------------------
    # The RQ5 ANSWER is latency against catalog size — a curve across four runs, which
    # no single time-series panel can show. That figure comes from rq5-catalog.csv via
    # pgfplots. This exports the per-route latency at the largest catalog only, as an
    # illustration of the catalog endpoint under the heaviest seeding.
    catalog-sweep)      echo "edc-api-red:3:rq5-catalog-latency-per-route" ;;

    # --- Observer-effect control --------------------------------------------
    # Request rate per runtime at each poll interval: the consumer control plane's
    # load should fall with the interval while the provider's does not. That contrast
    # is the evidence, and it is visible only as a picture of both series together.
    poll-sensitivity)   echo "edc-api-red:1:ctl-request-rate" ;;

    # --- No figure -----------------------------------------------------------
    #   smoke         a pass/fail gate, not a measurement
    #   payload-sweep the RQ1 data-plane answer is throughput against payload size —
    #                 again a curve across runs; pgfplots from rq1-payload.csv
    smoke|payload-sweep) echo "" ;;

    # An unrecognised scenario exports nothing rather than everything: the old
    # fallback was ALL_PANELS, so adding a scenario silently added ten images per run.
    *)                  echo "" ;;
  esac
}

# The catalog sweep runs at four sizes; only the largest is worth an illustration.
# Set to "all" to export every size.
CATALOG_FIGURE_SIZE="${CATALOG_FIGURE_SIZE:-1000}"

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
# ONE run per (connector, arm, scenario, sweep-variant) unless ALL_RUNS=1: a thesis
# figure wants one representative image, not one per repetition. The repetitions are
# still all present in results/ and all of them feed the numbers; only the picture
# comes from a single run.
#
# Which one: the FIRST repetition. Paths carry an ISO-8601 timestamp, so `sort` orders
# them chronologically ascending and the first match per key wins. (An earlier comment
# here claimed "newest" — it was wrong, and the behaviour is what shipped for the
# 2026-08 campaigns. Do NOT "fix" it to newest: Prometheus is wiped by cleanup.sh, so
# already-exported connectors cannot be re-rendered, and switching now would leave one
# connector's figures drawn from a different repetition than the others'. Consistency
# across connectors is worth more than the choice of repetition, which is arbitrary.)
mapfile -t METAS < <(find "$ROOT/results" -name meta.json | sort)
declare -A SEEN
count=0; failed=0; skipped=0; empty=0

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

  # Only one catalog size earns an illustration; the sweep's real figure is the
  # cross-run curve from rq5-catalog.csv. Without this the sweep alone contributes
  # four near-identical images per arm.
  if [ "$sc" = "catalog-sweep" ] && [ "$CATALOG_FIGURE_SIZE" != "all" ] \
     && [ "$cat_size" != "$CATALOG_FIGURE_SIZE" ]; then
    skipped=$((skipped+1)); continue
  fi

  key="${c}_${arm}_${sc}${variant}"
  if [ "$ALL_RUNS" != "1" ]; then
    [ -n "${SEEN[$key]:-}" ] && continue      # metas sort ascending, so this keeps the FIRST
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
  SERVICE_PARAMS="$(service_params_from "$(dirname "$m")")"

  for spec in $set_for_run; do
    uid="${spec%%:*}"; rest="${spec#*:}"; pid="${rest%%:*}"; slug="${rest##*:}"
    out="$OUTDIR/${key}_${slug}.png"
    code="$(curl -s -u "$GF_USER:$GF_PASS" -o "$out" -w '%{http_code}' \
      "$GRAFANA_URL/render/d-solo/$uid/x?orgId=1&panelId=$pid&from=$fromms&to=$toms&width=$WIDTH&height=$HEIGHT&theme=$THEME&tz=UTC$(vars_for "$uid")" \
      2>/dev/null || true)"
    if [ "$code" = "200" ] && head -c4 "$out" | grep -q 'PNG'; then
      # A panel with no series still renders a valid 200 PNG — just an empty grid.
      # That is the failure mode this script used to ship silently, so flag it by
      # size: an empty dark panel compresses to a few kB, a drawn one does not.
      bytes="$(wc -c < "$out")"
      if [ "$bytes" -lt "${EMPTY_PNG_BYTES:-12000}" ]; then
        echo "  WARNING: ${out##*/} is only ${bytes} B — probably an EMPTY panel." >&2
        echo "           Check: is the run window still inside Prometheus retention," >&2
        echo "           and does the panel's query return anything for it? (see §7)" >&2
        empty=$((empty+1))
      fi
      count=$((count+1)); printf '  %s\n' "${out#$ROOT/}"
    else
      rm -f "$out"; failed=$((failed+1))
      echo "  FAILED (HTTP $code) $uid/$pid for $key" >&2
    fi
  done
done

echo
echo "exported $count panel(s) to $OUTDIR${failed:+, $failed failed}${skipped:+, $skipped run(s) skipped as gates}"
[ "${empty:-0}" -gt 0 ] && echo "WARNING: $empty image(s) look empty — do NOT put those in the thesis until checked" >&2
[ "$count" -eq 0 ] && { echo "Nothing exported — is Prometheus still holding these windows (7d retention)?" >&2; exit 1; }
cat <<EOF

Use in LaTeX:
  \\includegraphics[width=\\textwidth]{figures/factoryx_on_steady_tx-outcome}
Export one connector/scenario only:   $0 factoryx steady
Every repetition, not just the first: ALL_RUNS=1 $0
Every panel for every run:            PROFILE=all $0
A specific panel set:                 PANELS="edc-api-red:200:tx-outcome" $0
A light-theme variant instead:        THEME=light $0
EOF
