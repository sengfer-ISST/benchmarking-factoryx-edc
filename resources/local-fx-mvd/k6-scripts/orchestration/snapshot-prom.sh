#!/usr/bin/env bash
# Snapshot server-side metrics from Prometheus over the run window into CSVs,
# time-aligned with the k6 run. Reuses the SAME PromQL as the Grafana
# edc-api-red dashboard so the CSVs equal what you see in Grafana. Read-only.
#
#   snapshot-prom.sh <start_epoch> <end_epoch> <result_dir> <config_path> [prom_url] [rate_window]
#
# Per-service CPU is NOT available (no cAdvisor) — the per-service resource view
# is JVM heap/GC/threads; node-exporter gives the host ceiling. (Matches the
# monitoring README's resource model.)
set -euo pipefail

START="${1:?start epoch}"; END="${2:?end epoch}"; RESULT_DIR="${3:?result dir}"
CONFIG_PATH="${4:?config path}"
PROM_URL="${5:-$(jq -r '.prometheus.baseUrl // "http://localhost:9090"' "$CONFIG_PATH")}"
W="${6:-1m}"   # rate() window — query_range can't use $__rate_interval

# SUT service_name regex, e.g. provider-controlplane|provider-dataplane|...
SVC="$(jq -r '.services.sut | join("|")' "$CONFIG_PATH")"

# query_range -> CSV(series,timestamp,value). Header always written; rows appended.
q() {
  # NB: two `local` statements — in one statement bash expands ALL args before
  # any assignment, so $name would still be unset (set -u aborts).
  local name="$1" expr="$2"
  local f="$RESULT_DIR/$name.csv"
  echo "series,timestamp,value" > "$f"
  curl -sG "$PROM_URL/api/v1/query_range" \
    --data-urlencode "query=$expr" \
    --data-urlencode "start=$START" --data-urlencode "end=$END" --data-urlencode "step=5" \
    | jq -r '.data.result[]? as $s
             # Label = service_name, or "service/status" when the query also groups by
             # status code. Queries that group only by service keep their old label, so
             # CSVs stay comparable with the runs already archived.
             | ([$s.metric.service_name, $s.metric.http_response_status_code]
                | map(select(. != null)) | join("/")) as $joined
             | (if $joined == "" then ($s.metric.instance // "all") else $joined end) as $lbl
             | $s.values[]? | [$lbl, .[0], .[1]] | @csv' >> "$f" 2>/dev/null || true
  echo "  $name.csv ($(($(wc -l < "$f") - 1)) rows)"
}

rows() { echo $(( $(wc -l < "$RESULT_DIR/$1.csv" 2>/dev/null || echo 1) - 1 )); }

echo "Prometheus snapshot [$START..$END] svc=($SVC) win=$W -> $RESULT_DIR"

# --- per-service JVM (the resource view for the EDC runtimes) ---
q jvm-heap     "sum by (service_name) (jvm_memory_used_bytes{service_name=~\"$SVC\", jvm_memory_type=\"heap\"})"
q jvm-gc-rate  "sum by (service_name) (rate(jvm_gc_duration_seconds_sum{service_name=~\"$SVC\"}[$W]))"
q jvm-threads  "sum by (service_name) (jvm_thread_count{service_name=~\"$SVC\"})"

# --- per-service RED (server-side, cross-validates k6 client latency) ---
q http-throughput "sum by (service_name) (rate(http_server_request_duration_seconds_count{service_name=~\"$SVC\"}[$W]))"
q http-p95        "histogram_quantile(0.95, sum by (le, service_name) (rate(http_server_request_duration_seconds_bucket{service_name=~\"$SVC\"}[$W])))"
q http-errors     "sum by (service_name) (rate(http_server_request_duration_seconds_count{service_name=~\"$SVC\", http_response_status_code=~\"4..|5..\"}[$W]))"
# 4xx and 5xx are NOT the same finding and must never share a series. Most 4xx here
# are the harness's own EDR/negotiation poll loop reading 404 until the resource
# exists — expected, and present even at 1 tx/s. A 5xx is the connector failing.
# Reporting "errors/s" without the split overstates connector faults by ~100x.
q http-errors-5xx "sum by (service_name) (rate(http_server_request_duration_seconds_count{service_name=~\"$SVC\", http_response_status_code=~\"5..\"}[$W]))"
# Full breakdown (service/code), so a 4xx spike can be attributed to a specific code
# rather than assumed to be the poll loop.
q http-status     "sum by (service_name, http_response_status_code) (rate(http_server_request_duration_seconds_count{service_name=~\"$SVC\", http_response_status_code=~\"4..|5..\"}[$W]))"

# --- host ceiling (node-exporter) — tells you if the knee is the host, not the connector ---
q host-cpu-busy   "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[$W])))"
q host-mem-used   "(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1024 / 1024"

# --- 5xx verdict ------------------------------------------------------------
# An empty http-errors-5xx.csv is ambiguous on its own: it means either "the
# connector returned no 5xx" or "the status-code label was never scraped". Only the
# first is a thesis claim. Cross-check against http-status: if THAT has rows, the
# label pipeline demonstrably works, so an empty 5xx file is a real zero. Written to
# the run folder so the claim survives without re-querying a torn-down Prometheus.
S5="$(rows http-errors-5xx)"; SA="$(rows http-status)"
if [ "$S5" -gt 0 ]; then
  VERDICT="5xx PRESENT ($S5 samples) — connector-side faults, see http-errors-5xx.csv"
elif [ "$SA" -gt 0 ]; then
  VERDICT="no 5xx in window (confirmed: http-status has $SA samples, so the status label IS scraped)"
else
  VERDICT="INCONCLUSIVE — no 4xx or 5xx samples at all; status-code label may be missing, do NOT claim zero 5xx"
fi
echo "$VERDICT" > "$RESULT_DIR/http-5xx-verdict.txt"
echo "  5xx: $VERDICT"
