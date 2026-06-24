// (c) SCALABILITY SATURATION — HEADLINE RQ2 result. Open model (ramping arrival
// rate). Sweep offered transactions/sec upward in stages to find the KNEE: where
// latency tails blow up, errors appear, or throughput stops tracking offered
// rate. Open model avoids coordinated omission, so the tail is honest.
//
// Thresholds are ABORT-ONLY (not pass/fail gates) so the sweep runs to the end
// while you hunt the knee — read the result from the latency-vs-rate curve, not
// from a green/red check. Watch node-exporter: on a small host the knee may be
// the HOST ceiling, not the connector (see plan "Threats").
import { baseOptions } from '../lib/options.js';
import { seedProvider } from '../lib/seed.js';
import { runTransaction } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

const STAGE = __ENV.STAGE_DURATION || '2m';

export const options = Object.assign({}, baseOptions, {
  scenarios: {
    saturation: {
      executor: 'ramping-arrival-rate',
      startRate: Number(__ENV.START_RATE || 1),
      timeUnit: '1s',
      preAllocatedVUs: Number(__ENV.PREALLOCATED_VUS || 100),
      maxVUs: Number(__ENV.MAX_VUS || 800),
      stages: [
        { target: 2, duration: STAGE },
        { target: 5, duration: STAGE },
        { target: 10, duration: STAGE },
        { target: 20, duration: STAGE },
        { target: 40, duration: STAGE },
        { target: 40, duration: STAGE }, // hold at top to observe the steady tail
      ],
      tags: { scenario: 'saturation' },
    },
  },
  thresholds: {
    // Abort only if the system is clearly collapsing, after a grace period.
    'dsp_transaction_failed_rate': [{ threshold: 'rate<0.5', abortOnFail: true, delayAbortEval: '1m' }],
  },
});

export function setup() { return seedProvider(); }
export default function () { runTransaction(); }
export const handleSummary = buildSummary;
