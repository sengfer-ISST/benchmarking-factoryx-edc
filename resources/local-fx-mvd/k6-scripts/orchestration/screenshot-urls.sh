#!/usr/bin/env bash
# Print Grafana deep-link URLs for the EXACT measured window of each run, so you
# can screenshot the right time range AFTER an unattended (possibly shuffled,
# overnight) matrix run. Grafana renders historical data from Prometheus, whose
# retention is ~7 days — so capture within a week of the runs.
#
# Read-only: it only reads results/**/meta.json (start_epoch/end_epoch, written by
# run.sh for the measured window only — warmup already excluded). Nothing is fetched.
#
#   screenshot-urls.sh [connector] [scenario]
#     connector : filter to one connector (matches meta.json .connector) — default: all
#     scenario  : filter to one scenario  (matches meta.json .scenario)  — default: all
#
# Env overrides:
#   GRAFANA_URL  base Grafana URL     (default http://localhost:3000)
#   DASH         dashboard uid        (default edc-api-red; node-exporter = rYdddlPWk)
#   SERVICES     space-separated service_name values to pin the $service template var
#                (default: unset -> the dashboard's saved default, which is "All")
#   THEME        light|dark           (default light, for print figures)
#
# Examples:
#   ./orchestration/screenshot-urls.sh                       # every run, RED dashboard
#   ./orchestration/screenshot-urls.sh factoryx saturation-open
#   DASH=rYdddlPWk ./orchestration/screenshot-urls.sh factoryx soak     # node-exporter (host CPU/mem)
#   SERVICES="provider-controlplane consumer-controlplane" ./orchestration/screenshot-urls.sh factoryx steady
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # this k6-scripts/
RESULTS="$ROOT/results"

CONNECTOR="${1:-}"; SCENARIO="${2:-}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
DASH="${DASH:-edc-api-red}"
THEME="${THEME:-light}"

[ -d "$RESULTS" ] || { echo "no results/ under $ROOT — run something first" >&2; exit 1; }

# Build the &var-service=... suffix from SERVICES (empty -> omit -> dashboard default = All).
svc_qs=""
for s in ${SERVICES:-}; do svc_qs+="&var-service=${s}"; done

echo "# Grafana window links  (dash=$DASH  theme=$THEME  services=${SERVICES:-All})"
echo "# open each -> screenshot -> save master-thesis/figures/grafana/<connector>-<arm>-<scenario>-*.png"

found=0
while IFS= read -r m; do
  # One jq read; TSV so empty fields survive. exit_code kept for info (saturation aborts by design).
  IFS=$'\t' read -r conn scen rid idm start end k6exit < <(
    jq -r '[.connector, .scenario, .run_id, .identity_mode,
            (.start_epoch|tostring), (.end_epoch|tostring),
            (.k6.exit_code // "?" | tostring)] | @tsv' "$m"
  )
  # Apply filters against the authoritative meta.json fields (not the path).
  [ -n "$CONNECTOR" ] && [ "$conn" != "$CONNECTOR" ] && continue
  [ -n "$SCENARIO" ]  && [ "$scen" != "$SCENARIO" ]  && continue
  # Guard against a truncated/failed meta.json.
  [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || { echo "  skip (no epochs): $m" >&2; continue; }

  from=$(( start * 1000 )); to=$(( end * 1000 ))   # Grafana from/to are in ms
  found=1
  printf '%-10s %-20s id=%-3s exit=%-2s  %s/d/%s/?from=%s&to=%s&theme=%s&kiosk%s\n' \
    "$conn" "$scen" "$idm" "$k6exit" "$GRAFANA_URL" "$DASH" "$from" "$to" "$THEME" "$svc_qs"
done < <(find "$RESULTS" -type f -name meta.json | sort)

[ "$found" -eq 1 ] || {
  echo "no meta.json matched (connector='${CONNECTOR:-*}' scenario='${SCENARIO:-*}') under $RESULTS" >&2
  exit 1
}
