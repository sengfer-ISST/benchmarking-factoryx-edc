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
//
// LOWERED 2/s -> 1/s after the first measured campaign, because 2/s still broke the
// rule above. The saturation ladders put the slowest arm, Factory-X identity-ON, at
// a knee between 1.5 and 2.5 tx/s, and BaSyx identity-ON missed the 30 s deadline on
// 7-10% of transactions at 2/s — so two of the six arms were being measured at or
// past saturation. Their latency percentiles were then censored (a timed-out
// transaction contributes the deadline, not its real duration), which makes them
// lower bounds rather than measurements, and RQ1 was comparing two connectors in
// steady state against one in overload. At 1/s every arm delivers its offered rate.
// Capacity questions belong to saturation-open, not here.
import { baseOptions } from '../lib/options.js';
import { seedProvider } from '../lib/seed.js';
import { runTransaction } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

export const options = Object.assign({}, baseOptions, {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 1),            // full DSP transactions / sec
      timeUnit: '1s',
      duration: __ENV.DURATION || '5m',
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
