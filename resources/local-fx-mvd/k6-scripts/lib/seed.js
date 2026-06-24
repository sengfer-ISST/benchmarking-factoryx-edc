import { postJson } from './http.js';
import { CONFIG } from './config.js';

// Idempotent for re-runs: EDC returns 409 if the entity already exists.
const ok = (r) => r.status === 200 || r.status === 201 || r.status === 409;

// Provider seeding via Management API (EDC providers only). basyx has no
// Management API (data pre-seeded in MongoDB) -> seed.enabled=false -> no-op,
// keeping the consumer-side measurement identical across connectors.
export function seedProvider() {
  if (!CONFIG.seed || !CONFIG.seed.enabled) {
    return { seeded: false, reason: 'provider has no Management API (pre-seeded)' };
  }
  const base = CONFIG.providerManagementUrl;
  const s = CONFIG.seed;

  const policy = {
    '@context': { '@vocab': 'https://w3id.org/edc/v0.0.1/ns/', odrl: 'http://www.w3.org/ns/odrl/2/' },
    '@id': s.policyId,
    policy: { '@context': 'http://www.w3.org/ns/odrl.jsonld', '@type': 'Set', permission: [], prohibition: [], obligation: [] },
  };
  const contractDef = {
    '@context': { '@vocab': 'https://w3id.org/edc/v0.0.1/ns/' },
    '@id': s.contractDefId,
    accessPolicyId: s.policyId,
    contractPolicyId: s.policyId,
    assetsSelector: [], // empty selector covers every asset, incl. payload-sweep assets
  };

  const rPolicy = postJson(`${base}/v3/policydefinitions`, policy, 'seed');
  const rAsset = seedAsset(s.assetId, s.assetBaseUrl, s.assetContentType, s.assetName);
  const rCdef = postJson(`${base}/v3/contractdefinitions`, contractDef, 'seed');

  return {
    seeded: true,
    ok: ok(rPolicy) && rAsset && ok(rCdef),
    statuses: { policy: rPolicy.status, contractDef: rCdef.status },
  };
}

// Create one HttpData asset. Reused by seedProvider and by the payload-sweep
// scenario to register a per-size asset. proxyPath=true so the data plane
// fetches `baseUrl` on pull. Returns true on success/already-exists.
export function seedAsset(assetId, baseUrl, contentType, name) {
  const asset = {
    '@context': { '@vocab': 'https://w3id.org/edc/v0.0.1/ns/' },
    '@id': assetId,
    properties: { name: name || assetId, contenttype: contentType || 'application/json' },
    dataAddress: { type: 'HttpData', name: assetId, baseUrl: baseUrl, proxyPath: 'true' },
  };
  return ok(postJson(`${CONFIG.providerManagementUrl}/v3/assets`, asset, 'seed'));
}

// Seed N provider assets for the catalog-size sweep (G1.RQ6). Reuses seedProvider
// (policy + empty-selector contract def, which offers every asset) then registers
// catalog-1..catalog-N against the default source, so the catalog grows to ~N.
// EDC providers only; basyx pre-seeds in MongoDB -> no-op.
export function seedAssets(n) {
  if (!CONFIG.seed || !CONFIG.seed.enabled) {
    return { seeded: false, reason: 'provider has no Management API (pre-seeded)' };
  }
  seedProvider(); // policy + (empty-selector) contract def + baseline asset
  const s = CONFIG.seed;
  let ok = 0;
  for (let i = 1; i <= n; i++) {
    if (seedAsset(`catalog-${i}`, s.assetBaseUrl, s.assetContentType, `catalog asset ${i}`)) ok++;
  }
  return { seeded: true, requested: n, ok };
}
