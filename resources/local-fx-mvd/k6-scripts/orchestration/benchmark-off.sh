#!/usr/bin/env bash
# Full identity-OFF (G2) campaign for one connector. Same code path as benchmark-on.sh;
# only IDENTITY_MODE and (for BaSyx) SCENARIO_DIR differ, both set by benchmark-arm.sh.
#
#   ./orchestration/benchmark-off.sh <factoryx|dst|basyx>
#
# Bring the arm up first (./install.sh off) and take it down after (./cleanup.sh off).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/benchmark-arm.sh" "${1:?usage: benchmark-off.sh <connector>}" off
