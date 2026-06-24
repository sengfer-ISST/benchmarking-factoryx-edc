# Monitoring stack — configuration walkthrough

This document explains *how* the monitoring stack is wired together: which
files configure which container, how data flows from the host all the way to
a Grafana panel, and why each piece is shaped the way it is. Intended as a
teaching reference for the thesis write-up.

The runtime topology:

```
   ┌──── host kernel ────┐     EDC runtimes (OTel java-agent)
   │                     │       consumer/provider × CP/DP
   ▼                     │              │ OTLP/gRPC (:4317)
node-exporter (:9100)    │              ▼
        │                │       otel-collector (:8889 Prometheus, → Tempo traces)
        │   HTTP /metrics│              │  metrics              │ traces
        └────────┬───────┴──────────────┘                      ▼
                 │  (scraped every 5s)                       Tempo (:3200)
                 ▼                                              │
           Prometheus (:9090) ── TSDB (volume: prometheus-data) │
                 │                                              │
                 │  PromQL over HTTP                            │
                 ▼                                              │
            Grafana (:3000) ──── dashboards in FX MVD folder ◀──┘
```

Everything below is referenced from `docker-compose.monitoring.yaml` and the
files under `monitoring/`.

---

## 1. The monitoring services

### 1.1 node-exporter — host-level metrics

```yaml
node-exporter:
  image: prom/node-exporter:v1.8.2
  command:
    - --path.procfs=/host/proc
    - --path.sysfs=/host/sys
    - --path.rootfs=/rootfs
    - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|...)
    - --collector.filesystem.fs-types-exclude=^(autofs|...|tracefs)$$
  pid: host
  volumes:
    - /proc:/host/proc:ro
    - /sys:/host/sys:ro
    - /:/rootfs:ro
  ports:
    - "9100:9100"
```

node-exporter reports the *host* — CPU saturation, swap, free memory, disk
queue depth, NIC throughput. Without it, you can't tell whether a slow
benchmark run was the connector or the laptop hitting swap.

Why the unusual mounts:

- `/proc:/host/proc:ro` and `/sys:/host/sys:ro` — the container has its own
  `/proc`, but we want the *host's*. The two `--path.*` flags re-point the
  exporter at the host versions.
- `/:/rootfs:ro` — needed for filesystem stats on host mounts.
- `pid: host` — share the host's PID namespace so process-level collectors
  see real PIDs, not the container's.

The two `--collector.filesystem.*-exclude` flags strip out pseudo-filesystems
and Docker's overlay layers. Without them, every container's overlayfs shows
up as its own "Filesystem" entry and the dashboards become unreadable. The
`$$` in the regex is YAML escaping — Compose interprets `$VAR`, so a literal
`$` must be doubled.

### 1.2 Prometheus — time-series database + scraper

```yaml
prometheus:
  image: prom/prometheus:v2.54.1
  command:
    - --config.file=/etc/prometheus/prometheus.yml
    - --storage.tsdb.path=/prometheus
    - --storage.tsdb.retention.time=7d
    - --web.enable-lifecycle
  volumes:
    - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    - prometheus-data:/prometheus
  ports:
    - "9090:9090"
```

Two volume mounts with very different purposes:

- `./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro` — a
  **bind mount**. The file on your laptop is mounted read-only into the
  container at the exact path Prometheus reads. Edit the file → restart
  Prometheus → new scrape config takes effect. Read-only so a misbehaving
  Prometheus can't mutate the source of truth.
- `prometheus-data:/prometheus` — a **named volume** (declared at the bottom
  of the compose file). This is where the TSDB lives. Survives `up`/`down`
  cycles; wiped only on `down -v`. Retention is capped at 7 days
  (`--storage.tsdb.retention.time=7d`) — long enough to compare runs across
  a working week, short enough to not eat the disk.

`--web.enable-lifecycle` lets you reload config with `curl -X POST
http://localhost:9090/-/reload` instead of restarting the container.

The actual scrape config (`monitoring/prometheus.yml`):

```yaml
global:
  scrape_interval: 5s        # how often Prometheus pulls /metrics
  evaluation_interval: 15s   # how often recording/alerting rules run

scrape_configs:
  - job_name: node-exporter
    static_configs:
      - targets: ['node-exporter:9100']
  - job_name: otel-collector
    static_configs:
      - targets: ['otel-collector:8889']
```

Two things worth understanding:

1. **`node-exporter:9100` is a DNS name, not a hardcoded IP.** Compose creates a
   DNS entry per service on `fx-test-network`, so Prometheus resolves
   `node-exporter` → the container's network-internal IP. This is why all
   monitoring services *and* the EDC services must share the same network.
2. **5 s scrape interval** matches the granularity we need to see negotiation
   and transfer spikes during Bruno/k6 runs. Lower would be wasteful;
   higher would smear short events.

### 1.3 Grafana — visualization

```yaml
grafana:
  image: grafana/grafana:11.2.0
  environment:
    - GF_SECURITY_ADMIN_USER=admin
    - GF_SECURITY_ADMIN_PASSWORD=admin
    - GF_AUTH_DISABLE_LOGIN_FORM=false
    - GF_USERS_ALLOW_SIGN_UP=false
  volumes:
    - ./monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
    - ./monitoring/grafana/dashboards:/etc/grafana/dashboards:ro
    - grafana-data:/var/lib/grafana
  ports:
    - "3000:3000"
```

Three volume mounts, two of them critical for *provisioning* — the
mechanism that lets us boot a fully configured Grafana without clicking
through the UI.

| Mount                                                       | Purpose                                                   |
|-------------------------------------------------------------|-----------------------------------------------------------|
| `./monitoring/grafana/provisioning → /etc/grafana/...`      | Datasource + dashboard *provider* configs (read on boot). |
| `./monitoring/grafana/dashboards → /etc/grafana/dashboards` | The dashboard JSON files themselves.                      |
| `grafana-data:/var/lib/grafana`                             | Persistent state: sessions, starred items, alert rules.   |

The first mount is what makes the stack reproducible: Grafana reads its
provisioning files at every startup, so a fresh `down -v && up -d` lands you
on a working dashboard instead of a blank Grafana.

---

## 2. How provisioning actually works

Grafana looks at `/etc/grafana/provisioning/{datasources,dashboards,...}` on
boot and applies whatever YAML it finds. Both files we provide are version 1
of the schema (`apiVersion: 1`).

### 2.1 Datasource — `provisioning/datasources/datasources.yaml`

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      timeInterval: 5s
```

- `url: http://prometheus:9090` — same DNS-on-`fx-test-network` trick as
  Prometheus's scrape config. Grafana doesn't go through the host; the
  request stays inside the Docker network.
- `access: proxy` — the Grafana server makes the request, not the browser.
  This is what lets the URL be a Docker-internal hostname.
- `uid: prometheus` — a stable identifier so dashboard JSON can hard-reference
  the datasource. Without a fixed uid, Grafana would generate a random one
  per boot and dashboards would break.
- `jsonData.timeInterval: 5s` — must match `prometheus.yml`'s
  `scrape_interval`. Mismatch causes Grafana to interpolate at the wrong
  resolution and you get suspicious flat lines on tight ranges.

### 2.2 Dashboards — `provisioning/dashboards/dashboards.yaml`

```yaml
apiVersion: 1
providers:
  - name: fx-mvd
    folder: FX MVD
    type: file
    allowUiUpdates: true
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/dashboards
```

This is a **file provider**: Grafana scans a directory for `*.json` and
imports each as a dashboard. The directory is the *second* bind mount
(`./monitoring/grafana/dashboards`).

Two flags worth knowing:

- `allowUiUpdates: true` — UI edits are kept in the database; the file isn't
  re-applied until it actually changes on disk. This means you can poke at a
  panel during exploration without losing it on restart.
- `updateIntervalSeconds: 30` — how often Grafana re-checks the directory.
  Drop a new JSON in there and within 30 s it appears in the FX MVD folder.

The dashboards are `edc-api-red.json` (custom — RED + JVM, see §6) and
`node-exporter.json` (community Grafana.com ID 1860), with the datasource UID
set to `prometheus` to match what we provisioned.

---

## 3. The shared network

Every container — EDC services *and* monitoring services — joins
`fx-test-network`:

```yaml
networks:
  fx-test-network:
    name: fx-test-network
    driver: bridge
```

Two reasons this matters:

1. **Service discovery.** Inside the network, `prometheus`, `node-exporter`,
   `otel-collector`, `consumer-controlplane`, etc. all resolve as DNS names.
   That's how `prometheus.yml` can write `targets: ['node-exporter:9100']` and
   how datasources.yaml can write `http://prometheus:9090`.
2. **OTel signal flow.** The EDC runtimes push OTLP to `otel-collector:4317`,
   the collector exports traces to `tempo:4317`, and Prometheus scrapes
   `otel-collector:8889` — all by name, only because they share this network.

The `name: fx-test-network` line forces Compose to use that exact network
name regardless of the project name (otherwise Compose prefixes it with the
working directory).

---

## 4. Volumes recap — bind vs. named

The compose file uses both kinds. The distinction is worth internalizing:

| Kind        | Source                            | Used for                                 | Survives `down -v`? |
|-------------|-----------------------------------|------------------------------------------|---------------------|
| Bind mount  | A path on your laptop             | Config files (read-only into container)  | N/A — file is yours |
| Named volume| Docker-managed (`prometheus-data`)| TSDB data, Grafana DB                    | No — wiped by `-v`  |

Rule of thumb in this repo: **configuration is bind-mounted, state is a
named volume.** That way you can edit YAML and restart, and you can wipe
state with `down -v` without touching your config.

---

## 5. Lifecycle

```bash
# bring up the full stack (EDC + monitoring)
docker compose -f docker-compose.monitoring.yaml up -d

# reload Prometheus config without restart
curl -X POST http://localhost:9090/-/reload

# tail Prometheus / Grafana logs
docker compose -f docker-compose.monitoring.yaml logs -f prometheus grafana

# tear down but keep TSDB and Grafana state
docker compose -f docker-compose.monitoring.yaml down

# nuke everything including volumes
docker compose -f docker-compose.monitoring.yaml down -v
```

Endpoints:

| Service       | URL                                       |
|---------------|-------------------------------------------|
| node-exporter | http://localhost:9100                     |
| otel-collector| http://localhost:8889/metrics             |
| Prometheus    | http://localhost:9090                     |
| Tempo         | http://localhost:3200                     |
| Grafana       | http://localhost:3000 (admin / admin)     |

Verify the chain end-to-end:

1. `curl localhost:9100/metrics | head` — node-exporter is producing metrics.
2. Visit `localhost:9090/targets` — Prometheus shows both jobs as UP.
3. Visit `localhost:3000` → Dashboards → FX MVD — both dashboards render
   without "No data."

If any step fails, the break is at the layer above the last one that worked.
(For the Stage 2 / OTel chain, see §6.4.)

---

## 6. Stage 2 — application telemetry (OTel agent → collector → Prometheus/Tempo)

Stage 1 (above) stops at *resource* metrics. Stage 2 adds *application* metrics
(per-API latency/throughput, JVM) and distributed traces, by turning on the
OpenTelemetry java-agent already present in the EDC images. Updated topology:

```
  EDC runtime JVMs (otel javaagent)
   consumer/provider × CP/DP
        │ OTLP/gRPC :4317  (push)
        ▼
   otel-collector ──(:8889 Prometheus exporter, pulled)──► Prometheus ─┐
        │                                                              ├─► Grafana
        └──(OTLP/gRPC)──► Tempo (:3200, queried) ──────────────────────┘
```

### 6.1 Why the agent needs `JAVA_TOOL_OPTIONS`

The image ENTRYPOINT includes `-javaagent:/app/opentelemetry-javaagent.jar`, but
the overlay sets its own `entrypoint:` (`java -jar edc-runtime.jar …`) which
*replaces* the ENTRYPOINT entirely — dropping the `-javaagent` flag. So just
mounting `opentelemetry.properties` does nothing. The agent is re-attached via
`JAVA_TOOL_OPTIONS` (a JVM env var the runtime always honors, no matter the
command line):

```yaml
- JAVA_TOOL_OPTIONS=… -javaagent:/app/opentelemetry-javaagent.jar -Dotel.javaagent.configuration-file=/app/opentelemetry.properties
- OTEL_SERVICE_NAME=consumer-controlplane            # per-runtime identity
- OTEL_RESOURCE_ATTRIBUTES=service.namespace=fx-mvd,service.instance.id=consumer-controlplane
```

`opentelemetry.properties` (in `additional_config/`, bind-mounted to
`/app/opentelemetry.properties`) sets the exporters, the collector endpoint
(`http://otel-collector:4317`, DNS over `fx-test-network`), and a 5 s metric
export interval to match Prometheus's scrape cadence.

### 6.2 Collector — `monitoring/otel-collector-config.yaml`

- **otlp receiver** on `0.0.0.0:4317` — accepts agent pushes.
- **prometheus exporter** on `0.0.0.0:8889` with
  `resource_to_telemetry_conversion.enabled: true` — promotes OTel resource
  attributes (`service.name`, `service.instance.id`) to Prometheus labels
  (`service_name`, `service_instance_id`) so metrics break down per runtime.
  Prometheus scrapes this endpoint (job `otel-collector` in `prometheus.yml`).
- **otlp/tempo exporter** to `tempo:4317` (TLS off; internal network) on the
  traces pipeline.
- `memory_limiter` + `batch` processors keep the collector bounded under a k6
  burst.

### 6.3 Tempo — `monitoring/tempo.yaml`

Single-binary, local-disk trace store. OTLP ingest on `4317` (internal only —
the collector already publishes host `4317`), API on `3200` (Grafana queries
this), gRPC moved to `9097` to avoid clashing with EDC ports. Traces persist in
the `tempo-data` named volume, retained 168 h to match Prometheus.

The Tempo datasource (in `datasources.yaml`) sets `tracesToMetrics` +
`serviceMap` back to the Prometheus uid, so you can jump from a slow span to the
matching latency/throughput graph.

### 6.4 Verify the Stage 2 chain

1. `docker logs consumer-controlplane 2>&1 | grep VersionLogger` — agent loaded.
2. `curl localhost:8889/metrics | grep http_server_request_duration_seconds` —
   collector re-exporting EDC metrics (after some traffic).
3. `localhost:9090/targets` — `otel-collector` job UP.
4. `localhost:3000` → Dashboards → FX MVD → **EDC API & Runtime (OTel)** renders.
5. `localhost:3000` → Explore → Tempo → a trace spans the EDC runtimes.

As in Stage 1, if a step fails the break is at the layer above the last one that
worked.
