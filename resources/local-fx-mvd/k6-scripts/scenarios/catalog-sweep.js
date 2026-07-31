// CATALOG-REQUEST LATENCY vs CATALOG SIZE (G1.RQ6, control plane). The mirror of
// payload-sweep, but on the control plane: setup() seeds CATALOG_SIZE provider
// assets, then every iteration issues a catalog-ONLY request — so catalog_duration
// reflects how catalog cost scales with the number of offered assets, isolated
// from the negotiation/transfer cycle.
//
// Run once PER SIZE (the orchestrator loops CATALOG_SIZE over {1,10,100,1000}).
// EDC providers only (Management API + SQL persistence). basyx pre-seeds assets in
// MongoDB, so its catalog size is fixed by the deployment, not seedable here ->
// basyx is out of scope for this scenario. Tractus-X needs SQL (its in-memory mode
// caps at 50 assets per contract definition).
import { baseOptions } from '../lib/options.js';
import { CONFIG } from '../lib/config.js';
import { seedAssets } from '../lib/seed.js';
import { catalogProbe } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

const CATALOG_SIZE = Number(__ENV.CATALOG_SIZE || 1);

export const options = Object.assign({}, baseOptions, {
  scenarios: {
    catalog: {
      executor: 'constant-vus',
      vus: Number(__ENV.VUS || 4),
      duration: __ENV.DURATION || '90s',
      // catalog_size is the swept factor — tag every sample so the per-size
      // catalog_duration series are separable in the summary / Prometheus-RW.
      tags: { scenario: 'catalog-sweep', catalog_size: String(CATALOG_SIZE) },
    },
  },
  thresholds: { 'dsp_transaction_failed_rate': ['rate<0.05'] },
});

export function setup() {
  if (!CONFIG.providerManagementUrl) {
    throw new Error('catalog-sweep needs a provider Management API to seed assets; basyx (pre-seeded MongoDB) is out of scope.');
  }
  const r = seedAssets(CATALOG_SIZE);
  if (!r.seeded || r.ok < CATALOG_SIZE) {
    throw new Error(`catalog-sweep setup failed: seeded ${r.ok || 0}/${CATALOG_SIZE} assets (in-memory connectors cap at 50/contract-def — use SQL persistence)`);
  }
  return {};
}

export default function () { catalogProbe(); }

export const handleSummary = buildSummary;
