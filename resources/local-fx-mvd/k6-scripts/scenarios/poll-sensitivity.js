// POLL-INTERVAL SENSITIVITY — the observer-effect control.
//
// WHY THIS EXISTS. The harness observes the asynchronous DSP state machines by
// polling the consumer control plane at a fixed interval, and that polling is not
// free: in the first measured campaign the connectors served ~68 req/s at an
// offered load of 2 tx/s, of which ~42 req/s were the harness's own status polls.
// Roughly 60% of the request load on the system under test was the measurement.
//
// That raises a question the results cannot answer on their own: is a measured
// latency or a measured saturation point a property of the connector, or partly a
// property of how hard the harness interrogates it? This scenario answers it by
// experiment rather than by argument. It is `steady` under a different name, run
// at two poll intervals. Everything else — rate, duration, flow, metrics — is
// identical, so the poll interval is the only variable.
//
// HOW TO READ THE RESULT. Compare three numbers across the two runs:
//   1. e2e_transaction_duration median   — the reported latency
//   2. consumer control plane req/s      — where the poll load lands
//   3. provider control plane req/s      — where the protocol work happens
// The expected outcome is that (2) falls roughly in proportion to the interval
// while (1) and (3) stay put. That result licenses every latency figure in the
// study: it shows the polling loads a component that carries none of the headline
// results. If instead (1) moves, the observer effect is real and must be reported
// as a correction, not a footnote.
//
// It is a SEPARATE scenario rather than `steady` with an override on purpose: runs
// land in their own results directory, so they can never be averaged into the
// operating-point figures by an analysis that groups on scenario name.
//
//   POLL_INTERVAL_MS=250  ./orchestration/run.sh <connector> poll-sensitivity
//   POLL_INTERVAL_MS=1000 ./orchestration/run.sh <connector> poll-sensitivity
import { baseOptions } from '../lib/options.js';
import { seedProvider } from '../lib/seed.js';
import { runTransaction } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

export const options = Object.assign({}, baseOptions, {
  scenarios: {
    pollSensitivity: {
      // Deliberately the same executor and defaults as steady.js. If steady's
      // load ever changes, change it here too or the comparison stops being one.
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 1),
      timeUnit: '1s',
      duration: __ENV.DURATION || '5m',
      preAllocatedVUs: Number(__ENV.PREALLOCATED_VUS || 50),
      maxVUs: Number(__ENV.MAX_VUS || 200),
      tags: { scenario: 'poll-sensitivity' },
    },
  },
  thresholds: {
    // No gate on failure rate. A long poll interval legitimately pushes more
    // transactions past the deadline — that is part of what is being measured, and
    // failing the run would discard the very observation the scenario exists for.
    // The dropped-iteration check stays: it still means k6 failed to offer the load.
    'dropped_iterations': ['count<1'],
  },
});

export function setup() { return seedProvider(); }
export default function () { runTransaction(); }
export const handleSummary = buildSummary;
