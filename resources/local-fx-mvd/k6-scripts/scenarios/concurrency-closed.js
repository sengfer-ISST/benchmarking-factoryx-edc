// (c-companion) CONCURRENCY SWEEP — closed model (ramping VUs). Maps directly
// onto RQ2's "increasing concurrency" wording: N simultaneous in-flight DSP
// cycles. Report ALONGSIDE the open-model saturation result and be explicit
// which is which. Note: closed model suffers coordinated omission (a slow
// transaction delays the next request), so treat its tail latency as optimistic.
//
// The ladder is UNIFORM across connectors (unlike saturation's): this scenario
// compares how each connector responds to the same concurrency, so the rungs are
// a controlled variable. Override VU_STAGES only to re-scale the whole campaign,
// never for one connector.
//
// Rungs sized by Little's law rather than round numbers: at ~4.5 s per
// transaction, N concurrent users offer roughly N/4.5 tx/s, so 50 VUs already
// offers ~11 tx/s. The first campaign ramped 10->50->100->200, i.e. up to ~44
// tx/s against a connector that sustained ~5 — three of five rungs measured
// nothing but queueing.
import { baseOptions } from '../lib/options.js';
import { seedProvider } from '../lib/seed.js';
import { runTransaction } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

const STAGE = __ENV.STAGE_DURATION || '2m';
const VU_STAGES = String(__ENV.VU_STAGES || '5,10,20,50')
  .split(',').map((s) => Number(s.trim())).filter((n) => n > 0);

const stages = VU_STAGES.map((v) => ({ target: v, duration: STAGE }));
stages.push({ target: VU_STAGES[VU_STAGES.length - 1], duration: STAGE }); // hold at top

export const options = Object.assign({}, baseOptions, {
  scenarios: {
    concurrency: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: stages,
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
