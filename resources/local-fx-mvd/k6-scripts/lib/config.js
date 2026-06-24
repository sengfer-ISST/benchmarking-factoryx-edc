// Loads the per-connector config — the ONLY thing that differs between the three
// repos (see README "anti-drift rule"). Everything else in lib/ + scenarios/ is
// byte-identical so the load driver itself can't become a confound.
//
// open() is allowed only in k6 init context, which is exactly where module
// top-level code runs, so this evaluates once per VU init.
//
// Path note: `../config/<name>.json` resolves to <root>/config either way k6
// resolves it, because lib/ and scenarios/ both sit one level under the root.

const connector = __ENV.CONNECTOR;
if (!connector) {
  throw new Error('CONNECTOR env var is required, e.g.  k6 run -e CONNECTOR=factoryx scenarios/smoke.js');
}

const configPath = __ENV.CONNECTOR_CONFIG || `../config/${connector}.json`;
export const CONFIG = JSON.parse(open(configPath));

// Poll cadence is a CONTROLLED VARIABLE (methodology §A4): fixed per run,
// recorded in meta.json, reported next to every async latency. Smaller =
// less time-to-state quantization bias but more control-plane poll load.
export const POLL_INTERVAL_MS = Number(__ENV.POLL_INTERVAL_MS || 250);
export const POLL_TIMEOUT_MS = Number(__ENV.POLL_TIMEOUT_MS || 30000);

export const SCENARIO = __ENV.SCENARIO || 'adhoc';

// Identity-validation mode — a CONTROLLED FACTOR for G1.RQ5 (identity/trust
// overhead). The SAME driver runs against an identity-OFF vs identity-ON
// deployment of the connector (ISST EDC iam-mock vs DCP runtime; basyx
// validationservice mock vs mvd); only the deployment differs, never this code,
// so it stays a tag + meta.json field and lib/ remains byte-identical & fair.
// "off" = trust-validation disabled, NOT zero auth code.
export const IDENTITY_MODE = __ENV.IDENTITY_MODE || 'on';

// Stamped on every custom-metric sample so JSON + Prometheus-RW series are
// filterable. Keep cardinality LOW — never put per-transaction ids in here.
export const commonTags = { connector: CONFIG.name, scenario: SCENARIO, identity_mode: IDENTITY_MODE };

// Fail fast with a clear message rather than mid-run. providerManagementUrl is
// intentionally NOT required (null for basyx, which has no Management API).
['name', 'consumerManagementUrl', 'providerDspAddress', 'providerId', 'protocol'].forEach((k) => {
  if (CONFIG[k] === undefined || CONFIG[k] === null) {
    throw new Error(`config/${connector}.json is missing required field "${k}"`);
  }
});

// The asset to negotiate/transfer. catalog.assetIdSelector wins; falls back to
// the seeded asset id (EDC providers).
export const ASSET_SELECTOR =
  (CONFIG.catalog && CONFIG.catalog.assetIdSelector) || (CONFIG.seed && CONFIG.seed.assetId) || null;
