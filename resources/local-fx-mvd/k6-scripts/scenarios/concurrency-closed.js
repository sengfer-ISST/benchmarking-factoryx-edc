// (c-companion) CONCURRENCY SWEEP — closed model (ramping VUs). Maps directly
// onto RQ2's "increasing concurrency" wording: N simultaneous in-flight DSP
// cycles. Report ALONGSIDE the open-model saturation result and be explicit
// which is which. Note: closed model suffers coordinated omission (a slow
// transaction delays the next request), so treat its tail latency as optimistic.
import { baseOptions } from '../lib/options.js';
import { seedProvider } from '../lib/seed.js';
import { runTransaction } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

const STAGE = __ENV.STAGE_DURATION || '2m';

export const options = Object.assign({}, baseOptions, {
  scenarios: {
    concurrency: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { target: 10, duration: STAGE },
        { target: 50, duration: STAGE },
        { target: 100, duration: STAGE },
        { target: Number(__ENV.MAX_VUS || 200), duration: STAGE },
        { target: Number(__ENV.MAX_VUS || 200), duration: STAGE }, // hold at top
      ],
      gracefulStop: '30s',
      tags: { scenario: 'concurrency' },
    },
  },
  thresholds: {
    'dsp_transaction_failed_rate': [{ threshold: 'rate<0.5', abortOnFail: true, delayAbortEval: '1m' }],
  },
});

export function setup() { return seedProvider(); }
export default function () { runTransaction(); }
export const handleSummary = buildSummary;
