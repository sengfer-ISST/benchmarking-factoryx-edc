// (b) STEADY-STATE OPERATING POINT — open model (constant arrival rate).
// Purpose: characterize each connector at a fixed, sustainable load and compare
// them head-to-head (RQ1). Open model => honest latency (no coordinated
// omission). Also used (with low RATE + short DURATION) as the discarded warmup.
//
// RATE IS A CONTROLLED VARIABLE AND MUST BE IDENTICAL ACROSS CONNECTORS.
// The comparison is "same offered load, different connector"; a per-connector
// rate would compare different experiments. Pick ONE campaign-wide rate that is
// below the SLOWEST connector's knee, using orchestration/calibrate-rate.sh on
// each connector first, then pass it explicitly:
//
//   RATE=2 ./orchestration/run.sh <connector> steady
//
// The default is intentionally conservative. The first Factory-X campaign ran the
// old default of 5/s, which sat above that connector's knee (~3-5 tx/s): all
// three repetitions returned 0-9% success and measured queueing, not steady state.
import { baseOptions } from '../lib/options.js';
import { seedProvider } from '../lib/seed.js';
import { runTransaction } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

export const options = Object.assign({}, baseOptions, {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 2),            // full DSP transactions / sec
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
    // VALIDITY GATE, not a performance gate. A dropped iteration means k6 could
    // not start a scheduled transaction because the VU pool was exhausted, so the
    // offered rate was not actually delivered and the run does not describe the
    // nominal load. Fix by raising MAX_VUS or lowering RATE — never by ignoring it.
    'dropped_iterations': ['count<1'],
  },
});

export function setup() { return seedProvider(); }
export default function () { runTransaction(); }
export const handleSummary = buildSummary;
