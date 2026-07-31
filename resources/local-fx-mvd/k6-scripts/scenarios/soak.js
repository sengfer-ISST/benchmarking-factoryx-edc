// (optional) SOAK / ENDURANCE — open model, sustained moderate load over a long
// window. Purpose: catch memory leaks and GC degradation over time (RQ3 stability)
// — watch jvm_memory_used_bytes drift and jvm_gc_duration in the Prometheus
// snapshot / Grafana. Default 1h; override DURATION/RATE as needed.
//
// RATE must be BELOW the steady rate, and identical across connectors for the
// same reason (see steady.js). A soak above the knee measures how a queue grows,
// not how a runtime ages: the first Factory-X soak ran at 3/s and spent the hour
// degrading (failures 0->11%, data-plane work 6.3->2.9 req/s), which says nothing
// about leaks. If failure rate climbs monotonically, the rate was too high — rerun
// lower before drawing any endurance conclusion.
import { baseOptions } from '../lib/options.js';
import { seedProvider } from '../lib/seed.js';
import { runTransaction } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

export const options = Object.assign({}, baseOptions, {
  scenarios: {
    soak: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 1),
      timeUnit: '1s',
      duration: __ENV.DURATION || '30m',
      preAllocatedVUs: Number(__ENV.PREALLOCATED_VUS || 50),
      maxVUs: Number(__ENV.MAX_VUS || 200),
      tags: { scenario: 'soak' },
    },
  },
  thresholds: {
    'dsp_transaction_failed_rate': ['rate<0.02'],
    'e2e_transaction_duration': ['p(95)<20000'],
    'dropped_iterations': ['count<1'],   // validity gate — see steady.js
  },
});

export function setup() { return seedProvider(); }
export default function () { runTransaction(); }
export const handleSummary = buildSummary;
