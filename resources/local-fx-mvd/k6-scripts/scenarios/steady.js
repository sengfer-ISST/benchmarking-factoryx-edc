// (b) STEADY-STATE OPERATING POINT — open model (constant arrival rate).
// Purpose: characterize each connector at a fixed, sustainable load and compare
// them head-to-head (RQ1). Pick a rate safely BELOW the saturation knee found by
// scenarios/saturation-open.js. Open model => honest latency (no coordinated
// omission). Also used (with low RATE + short DURATION) as the discarded warmup.
import { baseOptions } from '../lib/options.js';
import { seedProvider } from '../lib/seed.js';
import { runTransaction } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

export const options = Object.assign({}, baseOptions, {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 5),            // full DSP transactions / sec
      timeUnit: '1s',
      duration: __ENV.DURATION || '10m',
      // Each transaction holds a VU through both async polls (seconds), so the
      // pool must be >> rate. If k6 warns "insufficient VUs", raise MAX_VUS —
      // you're then measuring k6's pool, not the SUT.
      preAllocatedVUs: Number(__ENV.PREALLOCATED_VUS || 50),
      maxVUs: Number(__ENV.MAX_VUS || 200),
      tags: { scenario: 'steady' },
    },
  },
  thresholds: {
    'dsp_transaction_failed_rate': ['rate<0.01'],
    'time_to_agreed': ['p(95)<8000', 'p(99)<15000'],
    'time_to_edr': ['p(95)<8000'],
    'e2e_transaction_duration': ['p(95)<20000'],
  },
});

export function setup() { return seedProvider(); }
export default function () { runTransaction(); }
export const handleSummary = buildSummary;
