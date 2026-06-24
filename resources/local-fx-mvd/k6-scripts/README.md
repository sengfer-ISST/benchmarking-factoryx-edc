# k6 benchmarking harness — Factory-X EDC (canonical copy)

Drives the consumer-side DSP flow (catalog → negotiation → transfer → EDR → data
pull) under controlled load, and snapshots the already-running server-side
metrics (Prometheus/OTel) time-aligned to each run. This is the **canonical**
copy: `lib/` + `scenarios/` are byte-identical to the copies in
`benchmarking-EDC` and `benchmarking-dsp-native-basyx`; only `config/*.json`
differs (see *Anti-drift* below).

**Methodology** (why the load is shaped this way — GQM, open/closed models,
warmup, the async-polling quantization caveat, threats to validity) lives in the
plan at `~/.claude/plans/so-for-now-for-polymorphic-kahan.md` and the monitoring
README at `../monitoring/README.md`. Read those before interpreting numbers.

## Prerequisites

- `k6`, `jq`, `curl` on the host.
- The connector stack **up with monitoring**:
  `docker compose -f ../docker-compose.monitoring.yaml up -d` (brings up the EDC
  runtimes + Prometheus :9090 / Grafana :3000 / Tempo / node-exporter).
- Lengthy first boot on a small host — wait until Grafana shows metrics before
  benchmarking (7 JVMs settling).

## Run

```bash
cd k6-scripts
make smoke                 # ALWAYS run first: correctness gate + single-user baseline
make steady                # operating point (open model)
make saturation            # RQ2 headline: ramping arrival rate -> knee
make concurrency           # RQ2 companion: ramping VUs (closed model)
# or directly:
./orchestration/run.sh factoryx steady
```

`run.sh` does: health-gate → **warmup (discarded)** → measured run → Prometheus
snapshot → `meta.json`. Each run writes an immutable folder:

```
results/<connector>/<scenario>/<UTC-ts>/
  meta.json            run params + provenance (poll interval, window, git sha, k6 ver)
  k6-summary.json      full client-side metrics (handleSummary)
  run.log              k6 console output
  jvm-heap.csv  jvm-gc-rate.csv  jvm-threads.csv     per-service JVM (resource view)
  http-throughput.csv  http-p95.csv  http-errors.csv  per-service server-side RED
  host-cpu-busy.csv  host-mem-used.csv               host ceiling (node-exporter)
```

### Useful env knobs

| Var | Meaning | Default |
|-----|---------|---------|
| `POLL_INTERVAL_MS` | async poll cadence (a controlled variable — recorded in meta.json) | 250 |
| `RATE` / `DURATION` | steady/soak arrival rate & length | 5 / 10m |
| `MAX_VUS` | VU pool ceiling (raise if k6 warns "insufficient VUs") | 200/800 |
| `STAGE_DURATION` | per-stage length for saturation/concurrency | 2m |
| `SKIP_WARMUP=1` | skip the warmup (debugging only) | off |
| `PROM_URL` | Prometheus base (factoryx 9090; benchmarking-EDC 9099) | from config |
| `CANONICAL_DIR` | enforce parity vs this canonical copy before running | unset |

## Optional: unified k6 + server timeline (Prometheus remote-write)

By default the harness runs **read-only**: client metrics come from
`k6-summary.json`, server metrics from the Prometheus snapshot. To also push k6's
client metrics into the same Prometheus (one Grafana timeline for client+server):

1. Add `--web.enable-remote-write-receiver` to the `prometheus` command in
   `../docker-compose.monitoring.yaml` and restart it.
2. Run with `K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write`
   set — `run.sh` adds `--out experimental-prometheus-rw` automatically.

## Data-plane payload sweep

```bash
./tools/gen-payloads.sh ./payloads        # makes 1KB..100MB files + serve hint
(cd payloads && python3 -m http.server 8888)
# set config.payload.urlTemplate to a URL reachable FROM THE PROVIDER DATA-PLANE
# CONTAINER (e.g. http://host.docker.internal:8888/{size}.bin), then:
PAYLOAD_SIZE=10MB PAYLOAD_BYTES=10485760 ./orchestration/run.sh factoryx payload-sweep
```
`setup()` establishes one EDR for the size-specific asset, then every iteration
just pulls — isolating data-plane throughput from the control-plane handshake.

## Custom metrics (glossary)

| Metric | What |
|--------|------|
| `catalog_duration`, `negotiation_init_duration`, `transfer_init_duration`, `datapull_duration` | per-phase single-request latency (k6 native timing) |
| `time_to_agreed` | wall time POST-negotiation → AGREED (async; quantized by poll interval) |
| `time_to_edr` | wall time POST-transfer → EDR available (async; quantized) |
| `e2e_transaction_duration` | composite catalog→pull wall time |
| `data_throughput_MBps` | data-plane pull throughput (MB/s) |
| `dsp_transactions_succeeded` / `dsp_transactions_failed{failed_phase}` | outcome counters (failed tagged with where it died) |
| `dsp_transaction_failed_rate` | failure ratio (thresholds key off this) |
| `negotiation_polls` / `edr_polls` | poll counts — quantify the polling observer effect |

## Anti-drift (per-repo rule)

This `lib/` + `scenarios/` is the source of truth. When copying into the other
two repos, copy them **verbatim**; put all per-connector differences in
`config/<connector>.json`. Before a run in a non-canonical repo:

```bash
./tools/verify-parity.sh /path/to/benchmarking-factoryx-edc/resources/local-fx-mvd/k6-scripts
```

A divergent load driver silently breaks the fairness argument that the
normalized deployment was built to guarantee.

## Caveats to remember when reading results

- **Host ceiling:** on a small host the saturation knee may be the host, not the
  connector — always check `host-cpu-busy.csv` / node-exporter. Relative
  comparison across connectors stays valid (all hit the same ceiling).
- **Poll quantization:** `time_to_agreed` / `time_to_edr` are upper bounds with
  error ±`POLL_INTERVAL_MS`. Report the interval next to them.
- **One stack at a time:** never benchmark two connectors concurrently.
