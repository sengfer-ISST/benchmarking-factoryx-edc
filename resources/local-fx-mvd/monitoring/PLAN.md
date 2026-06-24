# Monitoring Plan — `local-fx-mvd`

Staged roadmap for adding a monitoring stack to the local Factory-X MVD
(`resources/local-fx-mvd/docker-compose.yaml`). This file is the living source of
truth for *what we plan to do and why*; `README.md` (added from Stage 1.1) will
describe *how the final thing works* with measured numbers for the thesis.

## Context

The MVD brings up 8 services (issuer, 2× idhubs, 2× controlplanes, 2× dataplanes,
shared Postgres, shared Vault) on the `fx-test-network` bridge. It is driven end-
to-end by a Bruno collection and will later be the target of k6 benchmark runs
for the Master's thesis *"Benchmarking & Performance Analysis of Data Space
Connectors"*. The goal of the monitoring stack is to capture resource usage and
(later) JVM + distributed-trace data during those runs, in a way that stays
out of the default `docker compose up` path.

### Guiding principles

- **Overlay, not edits.** Monitoring lives in a separate compose file
  (`docker-compose.monitoring.yaml`). The base MVD file is untouched so users who
  don't want monitoring are unaffected.
- **Stage by stage.** Small, individually verifiable increments, each committed
  on its own. No bulk drops.
- **Thesis-ready documentation.** Every increment updates `README.md` with
  rationale, components, and measured numbers — so the work doubles as thesis
  material.

## Progress checklist

- [x] **Stage 0** — commit this plan doc (no code)
- [x] **Stage 1.1** — node-exporter + Prometheus (minimum viable host metrics)
- [x] **Stage 1.2** — Grafana with provisioned Prometheus datasource
- [x] **Stage 1.3** — provision the Node Exporter Full dashboard *(overhead numbers in README §7 still to fill from a measurement run)*
- [x] **Stage 2** — OpenTelemetry Collector + JVM/HTTP metrics + Tempo traces, wired via the OTel java-agent in the EDC images
  - [x] **Stage 2.1** — activate the OTel agent on the 4 EDC runtimes
  - [x] **Stage 2.2** — OTel Collector → Prometheus (per-endpoint HTTP latency/throughput + JVM)
  - [x] **Stage 2.3** — Tempo + provisioned Tempo datasource (distributed traces)
  - [x] **Stage 2.4** — `EDC API & Runtime (OTel)` RED+JVM dashboard + docs *(overhead delta in README §7 still to fill from a measurement run)*

## Stage 1 — host metrics + Grafana (no EDC changes)

Each sub-stage leaves the repo in a working, committable state. Only move to the
next sub-stage after the current one has been run end-to-end and its row in
the progress checklist is ticked.

### Stage 1.1 — node-exporter + Prometheus

Minimum viable metrics stack. Two services, scraped every 5 s.

- `node-exporter` (`prom/node-exporter:v1.8.2`) on `:9100` — host-level CPU /
  memory / disk / network / filesystem. Read-only mounts of `/proc`, `/sys`, `/`;
  `pid: host`. Needed because a host-side bottleneck (swap, IO pressure) can skew
  EDC numbers and must be visible in the data.
- `prometheus` (`prom/prometheus:v2.54.1`) on `:9090` — config at
  `monitoring/prometheus.yml`, scrape target `node-exporter:9100`.
- Create `monitoring/README.md` skeleton (sections listed below) with Stage 1.1
  content filled in.

**Verify:** Prometheus `/targets` shows `node-exporter` as `up`;
`node_memory_MemAvailable_bytes` returns a value.

### Stage 1.2 — Grafana with provisioned datasource

- `grafana` (`grafana/grafana:11.2.0`) on `:3000`, admin/admin.
- Prometheus datasource provisioned from
  `monitoring/grafana/provisioning/datasources/datasources.yaml`.
- `monitoring/README.md` updated with URL, login, and a short note on how
  provisioning works.

**Verify:** Grafana → Explore → Prometheus, run
`node_memory_MemAvailable_bytes`, see a value.

### Stage 1.3 — provisioned dashboard + overhead measurement

- Dashboard provisioning config at
  `monitoring/grafana/provisioning/dashboards/dashboards.yaml`.
- Node Exporter Full (Grafana.com ID **1860**) imported.
- `monitoring/README.md` completed: dashboard URL, per-panel notes for
  benchmark interpretation, screenshot placeholders, and a filled-in overhead
  table (host CPU/mem with monitoring off vs on during an idle Bruno run).

**Verify:** the dashboard is visible under Grafana → Dashboards; run the Bruno
`identities` folder + a transaction and confirm the host metrics respond.

## Stage 2 — JVM + traces from EDC runtimes (DONE)

This is what answers the thesis question host metrics cannot: **per-API latency,
throughput, and per-request behavior per container.** node-exporter reads
`/proc` and `/sys` — it only sees host resource consumption, never an HTTP
request. Application-level instrumentation is required, and the EDC images are
pre-wired for it.

As-built:

- **OTel java-agent activated** on the 4 EDC runtimes. The agent jar is already
  in the image, but a critical gotcha: the overlay's `entrypoint:` override
  (`java -jar edc-runtime.jar`) *drops* the Dockerfile's `-javaagent` flag, so
  mounting the properties file alone leaves the agent inert. Fix: inject the
  agent via `JAVA_TOOL_OPTIONS` (auto-applied by the JVM regardless of
  entrypoint) plus `-Dotel.javaagent.configuration-file=/app/opentelemetry.properties`.
  Per-runtime identity via `OTEL_SERVICE_NAME` / `OTEL_RESOURCE_ATTRIBUTES`.
- **`otel-collector`** (`otel/opentelemetry-collector-contrib:0.108.0`) — OTLP
  receiver on 4317; Prometheus exporter on 8889 (scraped by our Prometheus);
  OTLP exporter to Tempo for traces. Config: `monitoring/otel-collector-config.yaml`.
- **`tempo`** (`grafana/tempo:2.6.0`) — local-disk trace store, OTLP ingest on
  4317, API on 3200. Config: `monitoring/tempo.yaml`.
- **Tempo datasource** provisioned alongside Prometheus, with traces→metrics +
  service-map correlation back to Prometheus.
- **Dashboard** `EDC API & Runtime (OTel)` (`grafana/dashboards/edc-api-red.json`)
  — RED panels (request rate, error rate, p50/p95/p99 per route per runtime) +
  JVM panels (heap, GC pause rate, threads). Built from the *actual* agent
  metric names (agent v2.20.0), not assumed ones — see below.

Confirmed metric/label names (agent 2.20.0, OTel semconv):
`http_server_request_duration_seconds{_bucket,_count,_sum}` with labels
`service_name`, `http_route`, `http_request_method`, `http_response_status_code`;
JVM as `jvm_memory_used_bytes{jvm_memory_type="heap"}`,
`jvm_gc_duration_seconds_sum`, `jvm_thread_count`. The custom JVM panels replace
the originally-planned Micrometer dashboard 4701 (4701 uses Micrometer label
names, which don't match the OTel `jvm_*` names the agent emits).

## Out of scope (for now)

- **Logs pipeline (Loki/Promtail).** `docker logs` is enough until the thesis
  explicitly needs correlated search.
- **Postgres exporter / Vault telemetry.** Add only if Postgres becomes a
  suspected bottleneck under k6 load.
- **Alertmanager.** Not relevant for a benchmark rig.
- **k6 → Prometheus remote-write.** Trivial to wire later (k6 has an
  `experimental-prometheus-rw` output); defer until benchmark runs start.

## Target file layout (end of Stage 1)

```
resources/local-fx-mvd/
  docker-compose.yaml                     # unchanged
  docker-compose.monitoring.yaml          # overlay
  monitoring/
    PLAN.md                               # this file
    README.md                             # thesis-facing
    prometheus.yml                        # node-exporter + otel-collector targets
    otel-collector-config.yaml            # OTLP in → Prometheus + Tempo out
    tempo.yaml                            # trace store
    grafana/
      provisioning/
        datasources/datasources.yaml      # Prometheus + Tempo datasources
        dashboards/dashboards.yaml        # provisioning config (points to ../dashboards)
      dashboards/                         # dashboard JSON payloads
        edc-api-red.json                  # custom: RED + JVM (OTel)
        node-exporter.json                # ID 1860
```

The main `resources/local-fx-mvd/README.md` gets a one-paragraph **Monitoring**
pointer (added in Stage 1.1) linking to `monitoring/README.md`.

## Decision log

| Date       | Decision                                                                                 | Rationale                                                                                        |
|------------|------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| 2026-04-23 | Use an overlay compose file (`docker-compose.monitoring.yaml`) instead of editing the base | Keeps the default `docker compose up` path untouched for anyone who doesn't need monitoring      |
| 2026-04-23 | Start with node-exporter + Prometheus + Grafana, defer OTel/JVM/traces to Stage 2 | Host metrics give immediate benchmarking value without touching EDC images             |
| 2026-04-23 | Stage-by-stage increments, each independently committed                                  | User preference; also makes regressions easy to isolate and each step easy to write up in thesis |
| 2026-04-23 | node-exporter runs with `pid: host` and read-only mounts of `/proc`, `/sys`, `/`            | Standard setup to expose complete host metrics; keeps container unprivileged beyond `pid: host`  |
| 2026-04-23 | Exclude overlay / pseudo filesystems from node-exporter's filesystem collector             | Otherwise Docker overlay mounts flood the "Filesystem" panels and drown out useful host disks    |
| 2026-04-23 | Grafana admin credentials hardcoded to `admin` / `admin`; reproducible Bruno/k6 setup      | Local-only benchmark rig, never exposed outside the laptop — reproducibility > secrecy here      |
| 2026-04-23 | Prometheus URL in the datasource uses the compose service name `http://prometheus:9090`     | Resolves over `fx-test-network`; avoids hardcoding `host.docker.internal` or a host IP           |
| 2026-04-23 | Ship the Node Exporter Full dashboard (Grafana.com 1860) as-is, no tailoring               | Well-understood by thesis readers; EDC-specific panels live in the custom OTel dashboard          |
| 2026-04-23 | Pin datasource uid `prometheus` so provisioned dashboard JSON can hard-reference it         | Provisioned dashboards don't run the `__inputs` import dialog, so the uid must be baked in        |
| 2026-04-23 | `allowUiUpdates: true` on the dashboard provider                                           | Lets UI edits stick for exploratory work; reverted only by editing the JSON file on disk         |
| 2026-05-22 | Inject the OTel agent via `JAVA_TOOL_OPTIONS`, not by relying on the image ENTRYPOINT       | The overlay's `entrypoint:` override drops the Dockerfile's `-javaagent` flag, so the agent stayed inert; `JAVA_TOOL_OPTIONS` is honored regardless of entrypoint |
| 2026-05-22 | One OTel collector as the single OTLP sink; Prometheus *pulls* from it (`:8889`)            | Keeps the existing pull-based Prometheus model; agents push to the collector, nothing scrapes the JVMs directly |
| 2026-05-22 | `resource_to_telemetry_conversion: enabled` on the Prometheus exporter                      | Promotes OTel resource attrs (`service_name`, `service_instance_id`) to Prometheus labels so metrics break down per EDC runtime |
| 2026-05-22 | Tempo OTLP gRPC kept internal; only its API (`:3200`) reused, collector exports to `tempo:4317` | Collector already owns host `4317`; publishing Tempo's would collide. Internal DNS avoids it |
| 2026-05-22 | Custom `edc-api-red.json` (RED + JVM) instead of Micrometer dashboard 4701                  | The agent emits OTel-named `jvm_*` / `http_server_request_duration_seconds`; 4701 expects Micrometer label names and would show "No data" |

New rows appended here when later stages make tool/version choices.

## Changelog

| Stage | Commit | Summary |
|-------|--------|---------|
| 0     | _pending_ | Add this plan doc; no code changes |
| 1.1   | _pending_ | Add `docker-compose.monitoring.yaml` with node-exporter + Prometheus, `monitoring/prometheus.yml`, `monitoring/README.md`, pointer in main README |
| 1.2   | _pending_ | Add Grafana service + provisioned Prometheus datasource (`monitoring/grafana/provisioning/datasources/datasources.yaml`); update monitoring README |
| 1.3   | _pending_ | Provision the Node Exporter Full (1860) dashboard into an "FX MVD" folder; bind-mount `monitoring/grafana/dashboards/`; expand monitoring README §6 (dashboards) and §7 (overhead table placeholders) |
| 2     | _pending_ | Activate OTel agent on the 4 EDC runtimes via `JAVA_TOOL_OPTIONS` + mounted `opentelemetry.properties`; add `otel-collector` (→ Prometheus `:8889`) and `tempo`; provision Tempo datasource; add `edc-api-red.json` (RED + JVM) dashboard; update PLAN/CONFIG/README. Verified live: per-route p95 latency, per-runtime throughput, traces ingested into Tempo |
