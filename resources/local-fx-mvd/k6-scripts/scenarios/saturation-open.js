// (c) SCALABILITY SATURATION — HEADLINE RQ2 result. Open model (ramping arrival
// rate). Sweep offered transactions/sec upward in stages to find the KNEE: where
// latency tails blow up, errors appear, or throughput stops tracking offered
// rate. Open model avoids coordinated omission, so the tail is honest.
//
// Thresholds are ABORT-ONLY (not pass/fail gates) so the sweep runs to the end
// while you hunt the knee — read the result from the latency-vs-rate curve, not
// from a green/red check. Watch node-exporter: on a small host the knee may be
// the HOST ceiling, not the connector (see plan "Threats").
//
// LADDER (RATES, tx/s per stage) is the ONE load parameter that may legitimately
// differ per connector: the purpose of this scenario is to locate *that*
// connector's knee, and a ladder whose top is below the knee finds nothing while
// one far above it spends the whole run in collapse. Record it in meta.json and
// report it beside every curve. Head-to-head comparison happens in `steady`, at a
// rate that IS common to all connectors — never here.
//
// Default ladder is deliberately dense at the low end: the first Factory-X
// campaign started at 2/s and stepped 2->5->10->20->40, which put stage 2 already
// at/above the knee (~3-5 tx/s) and produced six stages of collapse instead of a
// curve.
import { baseOptions } from '../lib/options.js';
import { seedProvider } from '../lib/seed.js';
import { runTransaction } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

const STAGE = __ENV.STAGE_DURATION || '90s';
const RATES = String(__ENV.RATES || '1,2,3,5,8,12')
  .split(',').map((s) => Number(s.trim())).filter((n) => n > 0);

// One stage per rung, plus a hold at the top rung to observe the steady tail.
const stages = RATES.map((r) => ({ target: r, duration: STAGE }));
stages.push({ target: RATES[RATES.length - 1], duration: STAGE });

export const options = Object.assign({}, baseOptions, {
  scenarios: {
    saturation: {
      executor: 'ramping-arrival-rate',
      startRate: Number(__ENV.START_RATE || 1),
      timeUnit: '1s',
      // The VU pool must cover rate x latency (Little's law). Past the knee a
      // transaction occupies a VU for the full POLL_TIMEOUT, so an undersized
      // pool drops iterations and you measure k6, not the SUT — check
      // `dropped_iterations` in the summary before trusting any result.
      preAllocatedVUs: Number(__ENV.PREALLOCATED_VUS || 100),
      maxVUs: Number(__ENV.MAX_VUS || 800),
      stages: stages,
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
