// DATA-PLANE THROUGHPUT vs PAYLOAD SIZE (RQ1, data plane). Isolates the data
// plane from the control-plane handshake: setup() establishes ONE EDR for a
// size-specific asset, then every iteration just pulls — so data_throughput_MBps
// reflects the data plane, not the negotiation cycle.
//
// Run once PER SIZE (the orchestrator loops PAYLOAD_SIZE over {1KB..100MB}).
// Requires a sized data source reachable FROM THE PROVIDER DATA-PLANE CONTAINER
// (see tools/gen-payloads.sh) and config.payload.urlTemplate set, OR pass
// PAYLOAD_URL directly. PAYLOAD_BYTES must equal the served size (bodies are
// discarded here, so throughput is computed from this hint).
import { baseOptions } from '../lib/options.js';
import { CONFIG } from '../lib/config.js';
import { seedProvider, seedAsset } from '../lib/seed.js';
import { establishEdr, pullData } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

const SIZE = __ENV.PAYLOAD_SIZE || '1MB';
const SIZE_BYTES = Number(__ENV.PAYLOAD_BYTES || 0);
const PAYLOAD_URL =
  __ENV.PAYLOAD_URL ||
  (CONFIG.payload && CONFIG.payload.urlTemplate ? CONFIG.payload.urlTemplate.replace('{size}', SIZE) : null);

export const options = Object.assign({}, baseOptions, {
  // 100 MB bodies × VUs would exhaust memory: discard and size from PAYLOAD_BYTES.
  discardResponseBodies: true,
  scenarios: {
    pull: {
      executor: 'constant-vus',
      vus: Number(__ENV.VUS || 4),
      duration: __ENV.DURATION || '2m',
      tags: { scenario: 'payload-sweep', payload: SIZE },
    },
  },
  thresholds: { 'dsp_transaction_failed_rate': ['rate<0.05'] },
});

export function setup() {
  seedProvider();
  // Register (or reuse) a per-size asset pointing at the sized source.
  const assetId = `payload-${SIZE}`;
  if (PAYLOAD_URL && CONFIG.providerManagementUrl) {
    seedAsset(assetId, PAYLOAD_URL, 'application/octet-stream', assetId);
  }
  const target = CONFIG.providerManagementUrl ? assetId : undefined; // basyx: pre-seeded asset
  const edr = establishEdr(target);
  if (!edr) {
    throw new Error(`payload-sweep setup failed: no EDR for ${assetId}. Is PAYLOAD_URL reachable from the provider data plane, and the asset present?`);
  }
  return { edr, sizeBytes: SIZE_BYTES };
}

export default function (data) {
  pullData(data.edr, data.sizeBytes);
}

export const handleSummary = buildSummary;
