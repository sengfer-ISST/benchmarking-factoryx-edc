import http from 'k6/http';
import { postJson } from './http.js';
import { CONFIG, ASSET_SELECTOR } from './config.js';

// Idempotent for re-runs: EDC returns 409 if the entity already exists.
const ok = (r) => r.status === 200 || r.status === 201 || r.status === 409;

// Provider seeding, run once in each scenario's setup(). Two styles, chosen by
// config (seed.style) so lib/ stays generic — connector specifics live in config:
//   - default (EDC): register policy + asset + contract-def via the Management API.
//   - "basyx-shell": BaSyx has no Management API, so seed one AAS shell in the AAS
//     repo instead (Keycloak grant -> POST /shells); see seedShell().
export function seedProvider() {
  if (!CONFIG.seed || !CONFIG.seed.enabled) {
    return { seeded: false, reason: 'provider has no Management API (pre-seeded)' };
  }
  if (CONFIG.seed.style === 'basyx-shell') {
    return seedShell();
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

// Register one regular AAS shell so a consumer-PULL has a GET-readable DataAsset.
// WHY: the BaSyx catalog otherwise exposes only the write-forward *ApiAsset proxies
// (which 404 on a GET pull), and its Mongo has no persistent volume, so a fresh stack
// starts empty. Mirrors the OFF-arm seeder / fx-bruno AAS provider flow: Keycloak
// password grant -> POST /shells. The shell id IS the driver's target (ASSET_SELECTOR),
// so we seed exactly what negotiation/transfer will request. Idempotent: 201/409 pass.
export function seedShell() {
  const s = CONFIG.seed;
  const tokenRes = http.post(s.keycloakTokenUrl, {
    client_id: s.keycloakClientId,
    grant_type: 'password',
    username: s.keycloakUsername,
    password: s.keycloakPassword,
  });
  if (tokenRes.status !== 200) {
    return { seeded: false, reason: 'keycloak token failed', status: tokenRes.status };
  }
  const shellId = ASSET_SELECTOR; // single source of truth = catalog.assetIdSelector
  const shell = {
    modelType: 'AssetAdministrationShell',
    assetInformation: { assetKind: 'Instance', assetType: s.assetType || 'Car', globalAssetId: s.globalAssetId },
    id: shellId,
    idShort: s.idShort || 'Car',
  };
  const r = http.post(s.shellsUrl, JSON.stringify(shell), {
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${tokenRes.json('access_token')}` },
  });
  const okStatus = r.status === 201 || r.status === 409 || r.status === 200 || r.status === 204;
  return { seeded: okStatus, style: 'basyx-shell', status: r.status, shellId };
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
  // BaSyx (no Management API) can't multiply assets via API; the single seeded shell
  // is the whole catalog, so the catalog-size sweep degenerates to one shell here.
  if (CONFIG.seed.style === 'basyx-shell') {
    return Object.assign({ requested: n }, seedShell());
  }
  seedProvider(); // policy + (empty-selector) contract def + baseline asset
  const s = CONFIG.seed;
  let ok = 0;
  for (let i = 1; i <= n; i++) {
    if (seedAsset(`catalog-${i}`, s.assetBaseUrl, s.assetContentType, `catalog asset ${i}`)) ok++;
  }
  return { seeded: true, requested: n, ok };
}
