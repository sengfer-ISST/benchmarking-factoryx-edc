#!/usr/bin/env bash
# Bring up the Factory-X EDC stack WITH monitoring on docker-compose, the same
# way benchmarking-EDC and benchmarking-dsp-native-basyx are launched, so the
# three connectors are benchmarked under one harness.
#
# Identity arm (G2 benchmark factor) is selected by the first positional arg;
# everything after it is passed through to `docker compose up`:
#   ./install.sh            # identity ON  (default) -> docker-compose.monitoring.yaml
#   ./install.sh on         # identity ON  (full DCP: issuer-service + both hubs)
#   ./install.sh off        # identity OFF (fx-mock) -> docker-compose-fxmock.monitoring.yaml
#   ./install.sh off --build  # mock arm, forcing an image rebuild
# Aliases: real|dcp|non-mock == on ; mock|no-id == off.
#
# Images are pulled NEVER (pull_policy: never) — build them first:
#   identity ON  : the standard edc-controlplane/dataplane + identityhub/issuer dev images
#   identity OFF : ./gradlew :edc-controlplane:edc-controlplane-postgresql-hashicorp-vault-fxmock:dockerize
set -euo pipefail

# Run from this script's directory so the relative compose paths resolve.
cd "$(dirname "$0")"

REAL_COMPOSE="docker-compose.monitoring.yaml"               # identity ON  (DCP)
MOCK_COMPOSE="docker-compose-fxmock.monitoring.yaml"        # identity OFF (fx-mock)

# ── Identity mode arg ───────────────────────────────────────────────────────
MODE="on"
if [[ "${1:-}" =~ ^(on|off|real|mock|dcp|non-mock|no-id)$ ]]; then
  MODE="$1"; shift
fi
case "$MODE" in
  on|real|dcp|non-mock) COMPOSE_FILE="$REAL_COMPOSE"; LABEL="ON  (real DCP identity)"; IDMODE="on";;
  off|mock|no-id)       COMPOSE_FILE="$MOCK_COMPOSE"; LABEL="OFF (fx-mock identity)"; IDMODE="off";;
esac

# A bareword first arg that isn't a known mode is almost certainly a typo
# (real compose flags start with '-'); fail loudly rather than passing it to
# `docker compose up` as a phantom service name.
if [[ -n "${1:-}" && "$1" != -* ]]; then
  echo "Unknown identity mode '$1'. Use: on|off (aliases real/dcp/non-mock, mock/no-id)." >&2
  echo "Extra compose args go AFTER the mode, e.g. ./install.sh off --build" >&2
  exit 2
fi

# ── Pre-flight: clear stale cross-stack container-name collisions ────────────
# These benchmark stacks deliberately share container_names (provider-controlplane,
# postgres, …) and run one-at-a-time on the same host. A leftover container from a
# previously-run connector (a different compose project) blocks `up` with a cryptic
# "name already in use". Remove dead leftovers automatically; refuse to disturb a
# RUNNING foreign stack (tear that one down with its own cleanup.sh first).
this_project="$(basename "$PWD")"          # compose default project = current dir
live_conflicts=()
while read -r cname; do
  [ -z "$cname" ] && continue
  info="$(docker ps -a --filter "name=^/${cname}$" \
            --format '{{.State}} {{.Label "com.docker.compose.project"}}' 2>/dev/null || true)"
  [ -z "$info" ] && continue
  cstate="${info%% *}"; cproj="${info#* }"
  [ "$cproj" = "$this_project" ] && continue   # same project → compose recreates it
  case "$cstate" in
    running|restarting|paused)
      live_conflicts+=("${cname} (project '${cproj:-none}', ${cstate})") ;;
    *)
      echo ">>> Removing stale container '${cname}' (leftover from project '${cproj:-none}', ${cstate})"
      docker rm -f "$cname" >/dev/null 2>&1 || true ;;
  esac
done < <(grep -oE 'container_name:[[:space:]]*[A-Za-z0-9_.-]+' "$COMPOSE_FILE" | awk '{print $2}')
if [ ${#live_conflicts[@]} -gt 0 ]; then
  echo "✗ Cannot start: these container names are held by a RUNNING stack:" >&2
  printf '    %s\n' "${live_conflicts[@]}" >&2
  echo "  Tear that connector down first (its ./cleanup.sh), then re-run." >&2
  exit 1
fi

echo ">>> Starting Factory-X EDC — identity ${LABEL} — ${COMPOSE_FILE} ..."
# pull_policy: never images must already exist; vault-init is a compose service,
# so vault seeding happens automatically on `up`.
docker compose -f "$COMPOSE_FILE" up -d "$@"

echo ""
echo ">>> Waiting for runtimes to settle (vault seed + schema autocreate) ..."
sleep 5
docker compose -f "$COMPOSE_FILE" ps

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
Factory-X EDC is up (docker-compose + monitoring).
  identity arm: ${LABEL}
  compose file: ${COMPOSE_FILE}

Monitoring (published to host):
  Grafana      http://localhost:3000      (admin / admin)
  Prometheus   http://localhost:9090
  Tempo        http://localhost:3200

Drive with the shared k6 harness (config/factoryx.json), matching this arm:
  k6 run -e CONNECTOR=factoryx -e IDENTITY_MODE=${IDMODE} scenarios/smoke.js

Tear down with:  ./cleanup.sh ${IDMODE}   (or ./cleanup.sh to remove both arms)
──────────────────────────────────────────────────────────────────────────────
EOF
