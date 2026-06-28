#!/usr/bin/env bash
# Tear down the Factory-X EDC monitoring compose stack and its volumes (postgres,
# vault, prometheus/grafana/tempo data) so the next run starts clean.
#
#   ./cleanup.sh        # tear down BOTH identity arms (idempotent; safe if one
#                       # was never up) — the default, so you never strand a stack
#   ./cleanup.sh on     # tear down only the identity-ON (DCP) arm
#   ./cleanup.sh off    # tear down only the identity-OFF (fx-mock) arm
# Aliases: real|dcp|non-mock == on ; mock|no-id == off.
set -euo pipefail

cd "$(dirname "$0")"

REAL_COMPOSE="docker-compose.monitoring.yaml"               # identity ON  (DCP)
MOCK_COMPOSE="docker-compose-fxmock.monitoring.yaml"        # identity OFF (fx-mock)

case "${1:-both}" in
  on|real|dcp|non-mock) FILES=("$REAL_COMPOSE");;
  off|mock|no-id)       FILES=("$MOCK_COMPOSE");;
  both)                 FILES=("$REAL_COMPOSE" "$MOCK_COMPOSE");;
  *) echo "Usage: $0 [on|off]   (no arg = tear down both arms)" >&2; exit 2;;
esac

for f in "${FILES[@]}"; do
  echo ">>> Stopping and removing Factory-X EDC stack + volumes (${f}) ..."
  docker compose -f "$f" down -v --remove-orphans
done

echo ">>> Done."
