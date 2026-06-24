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
    'dsp_transactions_failed': ['count==0'],         // every transaction must complete
    'e2e_transaction_duration': ['p(95)<10000'],     // generous single-user bound
  },
});

export function setup() { return seedProvider(); }
export default function () { runTransaction(); }
export const handleSummary = buildSummary;
