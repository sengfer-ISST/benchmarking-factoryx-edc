#!/usr/bin/env bash
# Sized data source for the data-plane sweep (payload-sweep).
#
# WHY THIS EXISTS: payload-sweep varies ONE factor — the number of bytes on the
# wire — and the provider DATA PLANE fetches the asset's baseUrl itself when the
# consumer pulls. So the sizes must be served somewhere the data-plane CONTAINER
# can reach, not just the k6 host:
#   FX / BaSyx (bridge):      http://host.docker.internal:8888/{size}.bin
#                             (compose maps host.docker.internal -> host-gateway)
#   DST (network_mode: host): http://localhost:8888/{size}.bin
# Without it the sweep silently pulls the default asset at every size and every
# "sweep" point is identical.
#
#   gen-payloads.sh [out-dir]          generate the files
#   gen-payloads.sh serve [out-dir]    generate if missing, then serve (survives logout)
#   gen-payloads.sh stop  [out-dir]    stop the server started by `serve`
#
# ONCE PER CAMPAIGN, not per arm: the server is a host process, so cleanup.sh (which
# only tears down containers) does not touch it, and one instance serves every arm of
# every connector. Keep the files OUTSIDE the repos — 111 MB of random data checked
# into three repos is pointless duplication:
#   PAYLOAD_DIR=~/Thesis/EDC/payloads ./tools/gen-payloads.sh serve
set -euo pipefail

CMD=""
case "${1:-}" in
  serve|stop) CMD="$1"; shift ;;
esac
OUT="${1:-${PAYLOAD_DIR:-./payloads}}"
PORT="${PAYLOAD_PORT:-8888}"
PIDFILE="$OUT/.server.pid"

# PID of whatever actually holds the port (ss, then lsof, then fuser — one of the
# three exists on any of these hosts).
port_owner() {
  ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1 && return 0
  lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1 && return 0
  fuser "$PORT"/tcp 2>/dev/null | tr -d ' ' | head -1
}

stop_server() {
  local pid="" owner=""
  [ -f "$PIDFILE" ] && pid="$(cat "$PIDFILE" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null && echo "stopped payload server (pid $pid)"
  rm -f "$PIDFILE" 2>/dev/null || true
  sleep 1
  # Belt and braces: the recorded pid can name a wrapper that already exited while
  # the real server kept the port (this bit us once). Never leave a stray server
  # bound on the benchmark host — the next campaign would silently measure it.
  owner="$(port_owner)"
  if [ -n "$owner" ]; then
    kill "$owner" 2>/dev/null && echo "stopped stray listener on :$PORT (pid $owner)"
    sleep 1
  fi
  [ -z "$(port_owner)" ] && echo ":$PORT is free" || echo "WARNING: :$PORT still in use" >&2
}
[ "$CMD" = "stop" ] && { stop_server; exit 0; }

mkdir -p "$OUT"

# name -> bytes. Regenerated only when absent or the wrong size, so `serve` is cheap
# to re-run and a half-written 100 MB file from an interrupted run gets replaced.
sizes="1KB:1024 100KB:102400 1MB:1048576 10MB:10485760 100MB:104857600"
for pair in $sizes; do
  name="${pair%%:*}"; bytes="${pair##*:}"
  f="$OUT/$name.bin"
  if [ -f "$f" ] && [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" = "$bytes" ]; then
    echo "  $f ($bytes bytes, already present)"
  else
    head -c "$bytes" /dev/urandom > "$f"
    echo "  $f ($bytes bytes)"
  fi
done

if [ "$CMD" != "serve" ]; then
  cat <<EOF

Payloads written to: $OUT
Serve them (survives an SSH logout — a plain backgrounded server does NOT, and the
sweep would start failing part-way through an overnight campaign):
  $0 serve $OUT

Then in config/<connector>.json (already set for factoryx and dst):
  "payload": { "urlTemplate": "http://host.docker.internal:$PORT/{size}.bin" }

And run, once per size (PAYLOAD_BYTES is derived from the label if omitted):
  PAYLOAD_SIZE=1MB   ./orchestration/run.sh <connector> payload-sweep
  PAYLOAD_SIZE=100MB ./orchestration/run.sh <connector> payload-sweep
EOF
  exit 0
fi

# --- serve ---
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "payload server already running (pid $(cat "$PIDFILE")) on :$PORT"
  exit 0
fi
# Fail loudly on a port clash rather than leaving the sweep pointed at someone
# else's server and silently measuring the wrong bytes.
if command -v curl >/dev/null && curl -s -o /dev/null -m 2 "http://localhost:$PORT/" 2>/dev/null; then
  echo "ERROR: something is already listening on :$PORT and it is not ours." >&2
  echo "       Free the port, or set PAYLOAD_PORT and match urlTemplate in config/." >&2
  exit 1
fi
# nohup: immune to the SIGHUP sent when the launching SSH session ends, so an
# overnight campaign does not lose its data source half way through.
# </dev/null matters as much: a detached server that keeps the session's stdin open
# holds the terminal and blocks logout (and hangs any script that waits on it).
# NB: cd directly, NOT in a `( ... && ... )` subshell — with a compound command bash
# forks twice and $! names the wrapper, not python, so the recorded pid was one less
# than the real server and `stop` left it running.
cd "$OUT" || { echo "ERROR: cannot enter $OUT" >&2; exit 1; }
nohup python3 -m http.server "$PORT" </dev/null >"server.log" 2>&1 &
SRV=$!
sleep 1
# Trust the process that actually holds the port over $!.
OWNER="$(port_owner)"
[ -n "$OWNER" ] && SRV="$OWNER"
if [ -n "$SRV" ] && kill -0 "$SRV" 2>/dev/null; then
  echo "$SRV" > "$PIDFILE"
  echo "payload server on :$PORT serving $OUT (pid $SRV, log $OUT/server.log)"
  echo "stop with: $0 stop $OUT"
else
  echo "ERROR: server failed to start — see $OUT/server.log" >&2
  exit 1
fi
