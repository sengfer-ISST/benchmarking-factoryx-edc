#!/usr/bin/env bash
# Generate fixed-size payload files for the data-plane sweep, then serve them.
# IMPORTANT: the data source must be reachable FROM THE PROVIDER DATA-PLANE
# CONTAINER (which fetches the asset baseUrl on pull), not just from the k6 host.
# On Docker Desktop use http://host.docker.internal:8888; on Linux bridge use the
# gateway IP (e.g. 172.17.0.1) or run the server on a container in the stack net.
#
#   gen-payloads.sh [out-dir]
set -euo pipefail
OUT="${1:-./payloads}"
mkdir -p "$OUT"

# name -> bytes
sizes="1KB:1024 100KB:102400 1MB:1048576 10MB:10485760 100MB:104857600"
for pair in $sizes; do
  name="${pair%%:*}"; bytes="${pair##*:}"
  head -c "$bytes" /dev/urandom > "$OUT/$name.bin"
  echo "  $OUT/$name.bin ($bytes bytes)"
done

cat <<EOF

Payloads written to: $OUT
Serve them:           (cd "$OUT" && python3 -m http.server 8888)

Then in config/<connector>.json set:
  "payload": { "urlTemplate": "http://host.docker.internal:8888/{size}.bin" }

And run, once per size (the orchestrator can loop this):
  PAYLOAD_SIZE=1MB  PAYLOAD_BYTES=1048576   ./orchestration/run.sh <connector> payload-sweep
  PAYLOAD_SIZE=100MB PAYLOAD_BYTES=104857600 ./orchestration/run.sh <connector> payload-sweep
EOF
