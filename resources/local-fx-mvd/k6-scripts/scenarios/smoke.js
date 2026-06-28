// (a) SMOKE / BASELINE — 1 VU, a handful of sequential iterations.
// Purpose: correctness gate (the flow reproduces the Bruno end-to-end run) and a
// single-user latency reference (service demand with no contention). Run this
// FIRST on every connector before any load scenario.
import { baseOptions } from '../lib/options.js';
import { seedProvider } from '../lib/seed.js';
import { runTransaction } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

export const options = Object.assign({}, baseOptions, {
  scenarios: {
    smoke: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: Number(__ENV.ITERATIONS || 5),
      maxDuration: '5m',
      tags: { scenario: 'smoke' },
    },
  },
  thresholds: {
    // Use the failed-RATE (sampled on every transaction: false on success), not the
    // failed COUNTER. A counter that never increments has zero samples, and k6 reports
    // a threshold on an empty metric as "crossed" — so `dsp_transactions_failed: count==0`
    // false-alarms on a perfectly clean run. rate<0.01 == "no failures" for the smoke.
    'dsp_transaction_failed_rate': ['rate<0.01'],    // every transaction must complete
    'e2e_transaction_duration': ['p(95)<10000'],     // generous single-user bound
  },
});

export function setup() { return seedProvider(); }
export default function () { runTransaction(); }
export const handleSummary = buildSummary;
