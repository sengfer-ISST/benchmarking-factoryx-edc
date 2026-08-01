#!/usr/bin/env bash
# Full identity-ON (G1) campaign for one connector. Thin wrapper so both arms are
# driven by the SAME code path — a duplicated script is a place for the arms to drift,
# and X1 is the difference between them.
#
#   ./orchestration/benchmark-on.sh <factoryx|dst|basyx>
#
# Bring the arm up first (./install.sh on) and take it down after (./cleanup.sh on).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/benchmark-arm.sh" "${1:?usage: benchmark-on.sh <connector>}" on
