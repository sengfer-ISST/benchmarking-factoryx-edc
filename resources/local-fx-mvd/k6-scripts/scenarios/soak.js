// (optional) SOAK / ENDURANCE — open model, sustained moderate load over a long
// window. Purpose: catch memory leaks and GC degradation over time (RQ3 stability)
// — watch jvm_memory_used_bytes drift and jvm_gc_duration in the Prometheus
// snapshot / Grafana. Default 30m; override DURATION/RATE as needed. Thirty
// minutes is long enough to show that nothing is growing fast enough to exhaust
// the heap on that timescale, but it cannot rule out a slow leak — say only that.
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
      // Halved with the steady rate (2 -> 1), keeping the "soak below steady" rule
      // stated above: a soak at the operating point measures a queue forming, not a
      // runtime ageing.
      //
      // EXPRESSED AS 1 PER 2s, NOT 0.5 PER 1s. k6's `rate` is an int64, so a
      // fractional value is rejected while PARSING the options — before the script
      // runs, so there is no summary and no result folder worth keeping:
      //   json: cannot unmarshal number 0.5 into Go struct field ... of type int64
      // Every soak run of the 2026-08-11 campaign died on exactly that. Keep RATE
      // integral and change TIME_UNIT to go below 1/s.
      rate: Number(__ENV.RATE || 1),
      timeUnit: __ENV.TIME_UNIT || '2s',
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
