// DATA-PLANE THROUGHPUT vs PAYLOAD SIZE (RQ1, data plane). Isolates the data
// plane from the control-plane handshake: setup() establishes ONE EDR for a
// size-specific asset, then every iteration just pulls — so data_throughput_MBps
// reflects the data plane, not the negotiation cycle.
//
// Run once PER SIZE (the orchestrator loops PAYLOAD_SIZE over {1KB..100MB}).
// Requires a sized data source reachable FROM THE PROVIDER DATA-PLANE CONTAINER
// (see tools/gen-payloads.sh) and config.payload.urlTemplate set, OR pass
// PAYLOAD_URL directly.
import { baseOptions } from '../lib/options.js';
import { CONFIG } from '../lib/config.js';
import { seedProvider, seedAsset } from '../lib/seed.js';
import { establishEdr, pullData } from '../lib/flow.js';
import { buildSummary } from '../lib/metrics.js';

const SIZE = __ENV.PAYLOAD_SIZE || '1MB';
const PAYLOAD_URL =
  __ENV.PAYLOAD_URL ||
  (CONFIG.payload && CONFIG.payload.urlTemplate ? CONFIG.payload.urlTemplate.replace('{size}', SIZE) : null);

// Derive the expected size from the label so a forgotten PAYLOAD_BYTES cannot
// silently produce a zero throughput series (it did: the first campaign passed
// PAYLOAD_SIZE but never PAYLOAD_BYTES). Explicit PAYLOAD_BYTES still wins, and
// the actual Content-Length wins over both at measurement time.
const UNITS = { KB: 1024, MB: 1048576, GB: 1073741824 };
function bytesFromLabel(label) {
  const m = /^(\d+(?:\.\d+)?)\s*(KB|MB|GB|B)$/i.exec(String(label).trim());
  if (!m) return 0;
  return Math.round(Number(m[1]) * (UNITS[m[2].toUpperCase()] || 1));
}
const SIZE_BYTES = Number(__ENV.PAYLOAD_BYTES || 0) || bytesFromLabel(SIZE);

// Fail at INIT, before the stack is touched, rather than 60 s into a warmup.
// Applicability is a per-connector FACT and therefore lives in config/, keeping
// this scenario byte-identical across repos (see tools/verify-parity.sh).
if (CONFIG.payload && CONFIG.payload.applicable === false) {
  throw new Error(
    `payload-sweep is not applicable to "${CONFIG.name}": ${CONFIG.payload.note || 'no separate data plane'}. ` +
    `Running it anyway would emit one identical "sweep" per size and read as real data.`);
}
if (!PAYLOAD_URL && CONFIG.providerManagementUrl) {
  throw new Error(
    `payload-sweep needs a sized source: set config.payload.urlTemplate (with {size}) or PAYLOAD_URL. ` +
    `Generate and serve one with tools/gen-payloads.sh; it must resolve FROM THE PROVIDER DATA-PLANE CONTAINER.`);
}

export const options = Object.assign({}, baseOptions, {
  // NOTE: `discardResponseBodies` is deliberately NOT set here. It is a VM-wide
  // switch that nulls every response body — including the catalog JSON parsed in
  // setup() — which aborts the scenario with "the body is null". The 100 MB
  // bodies are discarded per-request instead (see the pull below), and size comes
  // from Content-Length, so memory stays bounded without breaking the handshake.
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
  pullData(data.edr, data.sizeBytes, { discardBody: true });
}

export const handleSummary = buildSummary;
