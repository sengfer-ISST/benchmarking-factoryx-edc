# local-fx-mvd monitoring stack

Opt-in monitoring overlay for the local Factory-X MVD
(`resources/local-fx-mvd/docker-compose.yaml`). Designed to capture host
resource usage plus per-API latency/throughput, JVM internals, and distributed
traces during Bruno-driven functional runs and k6 benchmark runs for the
thesis *"Benchmarking & Performance Analysis of Data Space Connectors"*.

See [`PLAN.md`](./PLAN.md) for the staged roadmap, progress checklist, and
decision log, and [`CONFIG.md`](./CONFIG.md) for a teaching walkthrough of
how every config file (compose volumes, prometheus.yml, Grafana
provisioning) wires together.

> **Status:** Stage 1 (host metrics + Grafana) and Stage 2 (per-API metrics,
> JVM, and distributed traces from the EDC runtimes via OpenTelemetry) complete.

## 1. Context & motivation

The MVD brings up 8 containers on the `fx-test-network` bridge: an issuer
service, two identity hubs, two EDC control planes, two EDC data planes, a
shared Postgres, and a shared Vault. For the thesis we need to correlate the
Bruno / k6 request timeline with per-API latency/throughput, JVM internals, and
distributed traces — and rule out host-side bottlenecks — to reason about
connector performance.

The monitoring stack is deliberately **opt-in** (separate compose file) so the
default `docker compose up` path stays lean for users who only want to run
functional tests.

## 2. Architecture

```
                    fx-test-network (bridge)
 ┌──────────────────────────────────────────────────────────────────┐
 │  MVD services:                                                   │
 │  issuer-service, consumer-idhub, provider-idhub,                 │
 │  consumer-controlplane, provider-controlplane,                   │
 │  consumer-dataplane,  provider-dataplane,                        │
 │  shared-postgres, shared-vault                                   │
 │   the 4 EDC runtimes run the OpenTelemetry java-agent ───┐       │
 │                                                          │ OTLP  │
 │  Monitoring overlay:                                     ▼       │
 │   ┌───────────────┐         ┌────────────────┐  metrics          │
 │   │ node-exporter │ ◀─┐     │ otel-collector  │ ──────┐  traces   │
 │   └───────────────┘   │     └────────┬────────┘       │   └──► tempo
 │                       │ scrape 5 s   │ scrape 5 s      │       │   │
 │              ┌────────┴──────────────┴───┐  query  ┌───┴───┐   │   │
 │              │        prometheus         │ ◀────── │grafana│ ◀─┘   │
 │              └───────────────────────────┘         └───────┘       │
 └──────────────────────────────────────────────────────────────────┘
             ▼                                          ▼
   host /proc, /sys, / (read-only)             :3000 (Grafana, host)
```

node-exporter reads the host's `/proc` and `/sys` (host-wide metrics); the
OpenTelemetry java-agent in each EDC runtime pushes per-API metrics + JVM
metrics + traces to the collector, which Prometheus scrapes (metrics) and Tempo
stores (traces). Together they let us attribute latency to a specific
API/runtime and rule out a host-side bottleneck — critical for defensible
benchmark numbers. See §10 for the full Stage 2 walkthrough.

## 3. Components & versions

| Component     | Image                                | Role                                                 | Alternatives considered                                                                                   |
|---------------|--------------------------------------|------------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| node-exporter | `prom/node-exporter:v1.8.2`          | Host-level CPU / mem / disk / net / FS metrics       | *Telegraf* (richer but heavier); *collectd* (older ecosystem, weaker Prometheus story)                    |
| Prometheus    | `prom/prometheus:v2.54.1`            | Scrape + time-series store (7 d retention)           | *VictoriaMetrics* (lighter, same PromQL — revisit if retention grows)                                     |
| Grafana       | `grafana/grafana:11.2.0`             | Visualisation; Prometheus + Tempo datasources        | *Perses* (young); *Chronograf* (InfluxDB-centric) — Grafana is the de-facto Prometheus UI                  |
| otel-collector| `otel/opentelemetry-collector-contrib:0.108.0` | OTLP sink; re-exports metrics to Prometheus, traces to Tempo (Stage 2) | direct agent→Prometheus (no trace fan-out); agent→Tempo only (no metrics) |
| Tempo         | `grafana/tempo:2.6.0`                | Distributed-trace store, queried from Grafana (Stage 2) | *Jaeger* (separate UI); *Zipkin* (older) — Tempo integrates natively with Grafana |

Image tags are pinned so thesis measurements are reproducible.

## 4. How to run

From `resources/local-fx-mvd/`:

`docker-compose.monitoring.yaml` is a standalone superset of
`docker-compose.yaml` — it bundles the full EDC stack with the monitoring
containers, so use it *instead of* the base file (don't run both at once;
they share container names and host ports).

```bash
# bring up base MVD + monitoring
docker compose -f docker-compose.monitoring.yaml up -d

# tear down (removes volumes, including Prometheus data)
docker compose -f docker-compose.monitoring.yaml down -v
```

Endpoints:

| Service       | URL                                       |
|---------------|-------------------------------------------|
| node-exporter | http://localhost:9100                     |
| Prometheus    | http://localhost:9090                     |
| Grafana       | http://localhost:3000 (admin / admin)     |
| otel-collector| http://localhost:8889/metrics (re-exported EDC metrics) |
| Tempo         | http://localhost:3200 (trace API)         |

### Provisioning

Grafana loads its configuration from `monitoring/grafana/provisioning/`,
mounted read-only into the container at `/etc/grafana/provisioning`:

- `provisioning/datasources/datasources.yaml` — **Prometheus** datasource
  (`http://prometheus:9090`, resolved over `fx-test-network`, pinned uid
  `prometheus`, default, `timeInterval: 5s`).
- `provisioning/dashboards/dashboards.yaml` — picks up any `*.json` under
  `/etc/grafana/dashboards` (a second bind mount from
  `monitoring/grafana/dashboards`) and places them in the **FX MVD** folder.

Dashboards edited in the UI are not overwritten unless the file on disk
changes (`allowUiUpdates: true`), so exploratory tweaks stick between
`up`/`down` cycles.

Grafana's data (sessions, ad-hoc starred dashboards, alert rules) is kept in
the `grafana-data` named volume, so it survives `up`/`down` cycles. Use
`docker compose -f docker-compose.monitoring.yaml down -v` to reset.

## 5. Quick verification

```bash
# node-exporter responds on its /metrics endpoint
curl -s http://localhost:9100/metrics | head -n 3

# Prometheus targets are healthy
curl -s http://localhost:9090/api/v1/targets \
  | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
# → {"job":"node-exporter","health":"up"}
# → {"job":"otel-collector","health":"up"}

# Host-level metric is flowing
curl -s --data-urlencode 'query=node_memory_MemAvailable_bytes' \
  http://localhost:9090/api/v1/query \
  | jq '.data.result[0].value[1]'
# → a byte count string, e.g. "12345678901"

# Grafana is up and both datasources were provisioned
curl -s -u admin:admin http://localhost:3000/api/datasources \
  | jq '.[] | {name, type, url}'
# → {"name":"Prometheus","type":"prometheus","url":"http://prometheus:9090"}
# → {"name":"Tempo","type":"tempo","url":"http://tempo:3200"}
```

Then open http://localhost:3000, log in with `admin` / `admin`. The provisioned
dashboards live under **Dashboards → FX MVD**.

```bash
# Dashboards are loaded
curl -s -u admin:admin 'http://localhost:3000/api/search?folderIds=0&query=' \
  | jq '.[] | {title, folderTitle}'
# → entries with folderTitle "FX MVD"
```

## 6. Dashboards

Provisioned into the **FX MVD** folder at startup. Source JSON is checked into
`monitoring/grafana/dashboards/`.

| Dashboard                  | grafana.com ID | File                  | Data source   |
|----------------------------|----------------|-----------------------|---------------|
| EDC API & Runtime (OTel)   | custom (§10)   | `edc-api-red.json`    | Prometheus    |
| Node Exporter Full         | [1860](https://grafana.com/grafana/dashboards/1860) | `node-exporter.json` | node-exporter |

### What to look at during a DSP negotiation / transfer

Open **EDC API & Runtime (OTel)** and use the `EDC runtime` dropdown to single
out a service. The panels most relevant to the thesis:

- **p95 latency per endpoint** — which API (negotiation, transfer, DSP) is slow,
  per runtime. Compare consumer vs. provider to see handshake asymmetry.
- **Request rate per runtime / per endpoint** — throughput under Bruno or k6.
- **JVM heap / GC pause rate** — a slow upward heap drift across repeated runs
  is the classic leak pattern; GC pauses explain latency spikes.

See §10.4 for the exact PromQL behind these panels.

Node Exporter Full is the control room for host-side bottlenecks:

- **CPU Busy / Load Average** — tells you whether EDC numbers are limited by
  the laptop rather than the connectors.
- **Memory** — watch `MemAvailable` and any swap activity; a benchmark with
  swap-in/out is not a valid benchmark.
- **Disk IOPS / Latency** — relevant once Postgres gets serious load under
  k6 runs.

### Customising

`allowUiUpdates: true` means you can tweak panels in the UI without the
provisioner reverting them. If you want to check a customisation into git,
export the dashboard JSON from Grafana and overwrite the file under
`monitoring/grafana/dashboards/`.

### Ad-hoc PromQL

For questions the dashboards don't answer, use **Explore → Prometheus**:

```promql
# p95 latency per endpoint per runtime (see §10.4 for more)
histogram_quantile(0.95, sum by (le, service_name, http_route)
  (rate(http_server_request_duration_seconds_bucket[$__rate_interval])))

# throughput (req/s) per runtime
sum by (service_name) (rate(http_server_request_duration_seconds_count[$__rate_interval]))

# host CPU utilisation (%), averaged across cores
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])))

# host memory pressure (MiB available)
node_memory_MemAvailable_bytes / 1024 / 1024
```

## 7. Overhead measurements

Fill this table from a dedicated measurement run — same host, same warm-up,
each scenario sampled for ≥ 2 minutes in steady state. "Host CPU" is the
Node Exporter Full *CPU Busy* average over the window; "Host memory" is
`node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes` in MiB.

| Scenario                           | Host CPU (avg) | Host memory (MiB) | Notes           |
|------------------------------------|----------------|-------------------|-----------------|
| MVD only, idle (monitoring off)    | _TBD_          | _TBD_             | Baseline        |
| MVD + monitoring, idle             | _TBD_          | _TBD_             | Overhead = diff |
| MVD + monitoring, Bruno full run   | _TBD_          | _TBD_             | Functional load |
| MVD + monitoring, k6 (short run)   | _TBD_          | _TBD_             | Benchmark load  |

Screenshots of the EDC API & Runtime and Node Exporter dashboards for each
scenario go in `docs/thesis-screenshots/monitoring/` (created when the run is
done).

## 8. Limitations & follow-ups

- **Per-container resource breakdown is via the JVM panels + node-exporter**, not
  a container-level exporter. The OTel agent reports JVM heap/GC/threads per EDC
  runtime (§10), and node-exporter covers the host; for the EDC services that is
  the resource view. Postgres/Vault resource attribution is out of scope until a
  bottleneck warrants it.
- **No logs pipeline.** `docker logs <container>` is sufficient for now.
- **Vault is in dev mode.** Fine for functional and local-benchmark work, not a
  production-representative configuration.
- **Scrape interval = 5 s.** Lower to 1 s for high-fidelity benchmark runs, but
  expect higher host CPU and disk use from Prometheus.

## 9. References

- Prometheus — https://prometheus.io/docs/introduction/overview/
- PromQL basics — https://prometheus.io/docs/prometheus/latest/querying/basics/
- OpenTelemetry Java agent — https://opentelemetry.io/docs/zero-code/java/agent/
- OpenTelemetry Collector — https://opentelemetry.io/docs/collector/
- Grafana Tempo — https://grafana.com/docs/tempo/latest/

## 10. API latency / throughput / traces (OpenTelemetry)

node-exporter (§1–§6) only sees **host resource consumption** — it reads
`/proc` and `/sys`, never an HTTP request. To answer *"what is the latency and
throughput of each API, per container"* you need **application-level**
instrumentation. This activates the OpenTelemetry java-agent that is already
baked into the EDC runtime images and routes its signals to Grafana.

### 10.1 Data flow

```
EDC runtimes (OTel java-agent)             metrics  ┌── Prometheus (:9090) ─┐
  consumer/provider × CP/DP   ── OTLP/gRPC ─────────► otel-collector :8889 ─┘
        │                          (:4317)            │
        └──────────────────────────────── traces ─────► Tempo (:3200)
                                                          │
                                            Grafana (:3000) reads both
```

The agent **pushes** to the collector; Prometheus **pulls** the collector's
`:8889/metrics`. Traces go collector → Tempo, queried from Grafana Explore.

### 10.2 Activating the agent (the gotcha)

The image ENTRYPOINT carries `-javaagent:/app/opentelemetry-javaagent.jar`, but
the overlay overrides `entrypoint:` (`java -jar edc-runtime.jar …`), which
**drops that flag** — so mounting the properties file alone leaves the agent
inert. The fix is to inject the agent through `JAVA_TOOL_OPTIONS` (honored by the
JVM regardless of entrypoint), on each of the 4 EDC services:

```yaml
- JAVA_TOOL_OPTIONS=-agentlib:jdwp=…:5005 -javaagent:/app/opentelemetry-javaagent.jar -Dotel.javaagent.configuration-file=/app/opentelemetry.properties
- OTEL_SERVICE_NAME=consumer-controlplane
- OTEL_RESOURCE_ATTRIBUTES=service.namespace=fx-mvd,service.instance.id=consumer-controlplane
```

Agent config is `additional_config/opentelemetry.properties` (exporters, OTLP
endpoint, 5 s metric interval). Collector config: `monitoring/otel-collector-config.yaml`.
Tempo config: `monitoring/tempo.yaml`. Tempo datasource is provisioned in
`datasources.yaml` with traces→metrics correlation.

### 10.3 Dashboard

**Dashboards → FX MVD → `EDC API & Runtime (OTel)`** — RED panels (request rate,
error rate, p50/p95/p99 latency per route per runtime) + JVM panels (heap, GC
pause rate, threads). The `EDC runtime` template variable filters by
`service_name`.

### 10.4 Key metrics & example PromQL

Confirmed with agent **v2.20.0** (OTel semantic conventions):

| Metric | Meaning |
|--------|---------|
| `http_server_request_duration_seconds_{bucket,count,sum}` | server-side request latency histogram |
| labels: `service_name`, `http_route`, `http_request_method`, `http_response_status_code` | break down per runtime / endpoint / verb / status |
| `http_client_request_duration_seconds_*` | outbound HTTP (e.g. DSP calls between connectors) |
| `jvm_memory_used_bytes{jvm_memory_type="heap"}`, `jvm_gc_duration_seconds_sum`, `jvm_thread_count` | JVM health |

```promql
# p95 latency per endpoint per runtime
histogram_quantile(0.95, sum by (le, service_name, http_route)
  (rate(http_server_request_duration_seconds_bucket[$__rate_interval])))

# throughput (req/s) per runtime
sum by (service_name) (rate(http_server_request_duration_seconds_count[$__rate_interval]))

# error rate (4xx+5xx) per runtime
sum by (service_name) (rate(http_server_request_duration_seconds_count{http_response_status_code=~"4..|5.."}[$__rate_interval]))
```

### 10.5 Verification

```bash
# Agent loaded (banner in container stderr)
docker logs consumer-controlplane 2>&1 | grep VersionLogger
# → opentelemetry-javaagent - version: 2.20.0

# EDC metrics re-exported by the collector, tagged per runtime
curl -s localhost:8889/metrics | grep -E "^# HELP (http_server|jvm)"

# Prometheus scraping the collector
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="otel-collector").health'
# → "up"

# Traces in Tempo (after driving any traffic / a Bruno run)
curl -s "localhost:3200/api/search?tags=service.name%3Dconsumer-controlplane&limit=5" | jq '.traces | length'
# → non-zero
```

Then **Grafana → Explore → Tempo**, search `service.name = consumer-controlplane`,
open a trace, and follow a negotiation/transfer hop across the four EDC runtimes.
