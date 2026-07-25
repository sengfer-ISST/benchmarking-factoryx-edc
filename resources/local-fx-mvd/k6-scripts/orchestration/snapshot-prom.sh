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
             | (($s.metric.service_name // $s.metric.instance // "all")) as $lbl
             | $s.values[]? | [$lbl, .[0], .[1]] | @csv' >> "$f" 2>/dev/null || true
  echo "  $name.csv ($(($(wc -l < "$f") - 1)) rows)"
}

echo "Prometheus snapshot [$START..$END] svc=($SVC) win=$W -> $RESULT_DIR"

# --- per-service JVM (the resource view for the EDC runtimes) ---
q jvm-heap     "sum by (service_name) (jvm_memory_used_bytes{service_name=~\"$SVC\", jvm_memory_type=\"heap\"})"
q jvm-gc-rate  "sum by (service_name) (rate(jvm_gc_duration_seconds_sum{service_name=~\"$SVC\"}[$W]))"
q jvm-threads  "sum by (service_name) (jvm_thread_count{service_name=~\"$SVC\"})"

# --- per-service RED (server-side, cross-validates k6 client latency) ---
q http-throughput "sum by (service_name) (rate(http_server_request_duration_seconds_count{service_name=~\"$SVC\"}[$W]))"
q http-p95        "histogram_quantile(0.95, sum by (le, service_name) (rate(http_server_request_duration_seconds_bucket{service_name=~\"$SVC\"}[$W])))"
q http-errors     "sum by (service_name) (rate(http_server_request_duration_seconds_count{service_name=~\"$SVC\", http_response_status_code=~\"4..|5..\"}[$W]))"

# --- host ceiling (node-exporter) — tells you if the knee is the host, not the connector ---
q host-cpu-busy   "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[$W])))"
q host-mem-used   "(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1024 / 1024"
