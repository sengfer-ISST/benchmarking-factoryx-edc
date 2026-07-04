// identity-setup.js — one-shot DCP identity bootstrap for the IDENTITY=ON arm.
//
// WHY THIS EXISTS: the "ON" deployment (docker-compose.monitoring.yaml, brought up
// by `./install.sh` / `./install.sh on`) starts the MVD/DCP identity stack
// (issuer-service + consumer/provider Identity Hubs + vault) but ships them EMPTY.
// Before any catalog/negotiation/transfer can succeed the dataspace must be
// provisioned: register the trusted issuer, announce the two members as holders,
// define the MembershipCredential, create each participant's identity, request
// their credentials, and store their STS client secrets in the vault. Skipping
// this is exactly why the k6 smoke fails with HTTP 502 "Failed to fetch client
// secret from the vault with alias: consumersecret".
//
// That provisioning is exactly the bruno/fx-local-test/identities Bruno collection
// (Prepare Issuer -> Prepare Consumer ID -> Prepare Provider ID). Bruno is a
// desktop GUI — fine on a laptop, absent on the benchmark server (WinSCP-only). This
// script is a faithful headless port of that collection in k6 (the Bruno pre/post
// scripts are already JavaScript, so the base64/JSON token handling maps 1:1) and
// needs nothing beyond the k6 you already run the scenarios with. Run it ONCE right
// after `./install.sh on`, before the k6 scenarios:
//
//   k6 run identity-setup.js                       # from k6-scripts/, services on the docker host
//   k6 run -e IDHOST=10.0.0.5 identity-setup.js    # driving from another host (remote server)
//
// Idempotency: participant creation returns 409 if it already exists. A 409 on the
// issuer means "already provisioned on a previous run" — the script reports it and
// stops, since the one-time secrets are not returned again. To re-provision cleanly:
// ./cleanup.sh on && ./install.sh on  (so the Identity Hub DBs come up empty), then
// re-run this.

import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { b64decode } from 'k6/encoding';

// Single VU, single pass — this is provisioning, not load.
export const options = { vus: 1, iterations: 1 };

// ── Fixed dataspace identifiers (must match the DIDs baked into the compose) ──────
const ADMIN_KEY   = __ENV.ADMIN_KEY   || 'YWRtaW4.adminKey';        // idhub super-admin key
const VAULT_TOKEN = __ENV.VAULT_TOKEN || 'vaultsecret0123456789';   // dev vault root token

const ISSUER_DID   = 'did:web:local-issuer-service:fx-issuer';
const CONSUMER_DID = 'did:web:consumer-idhub:user:consumer';
const PROVIDER_DID = 'did:web:provider-idhub:user:provider';

// participantContextId path segment = base64url(DID) — exactly as the Bruno URLs use.
const ISSUER_CTX   = 'ZGlkOndlYjpsb2NhbC1pc3N1ZXItc2VydmljZTpmeC1pc3N1ZXI=';
const CONSUMER_CTX = 'ZGlkOndlYjpjb25zdW1lci1pZGh1Yjp1c2VyOmNvbnN1bWVy';
const PROVIDER_CTX = 'ZGlkOndlYjpwcm92aWRlci1pZGh1Yjp1c2VyOnByb3ZpZGVy';

// ── Service endpoints (published to the docker host; override IDHOST if remote) ───
const H = __ENV.IDHOST || 'localhost';
const ISSUER_ID_API      = `http://${H}:10100/api/identity`;
const ISSUER_ISS_API     = `http://${H}:10200/api/issuer`;
const CONSUMER_ID_API    = `http://${H}:20100/api/identity`;
const CONSUMER_STS_API   = `http://${H}:20500/api/sts`;
const CONSUMER_CREDS_API = `http://${H}:20600/api/credentials`;
const PROVIDER_ID_API    = `http://${H}:21100/api/identity`;
const PROVIDER_STS_API   = `http://${H}:21500/api/sts`;
const VAULT_URL          = `http://${H}:8200`;

const JSON_HDR = { 'Content-Type': 'application/json' };
const authJson = (key) => ({ headers: Object.assign({ 'x-api-key': key }, JSON_HDR) });

// step(): log + gate. Any status outside `ok` aborts the run (non-zero exit), so this
// doubles as a prerequisite gate the way a failing Bruno assertion would.
function step(name, res, ok) {
  const pass = ok.includes(res.status);
  console.log(`[${pass ? 'OK ' : 'ERR'}] ${name} -> HTTP ${res.status}`);
  if (!pass) {
    console.error(`  body: ${res.body}`);
    fail(`identity-setup step "${name}" failed (HTTP ${res.status})`);
  }
  return res;
}

// Retry the very first call — the Identity Hubs may still be booting right after
// `docker compose up`. Retries only on connection error (status 0) or 5xx.
function withRetry(fn, attempts = 30, delaySec = 2) {
  for (let i = 1; i <= attempts; i++) {
    const res = fn();
    if (res.status > 0 && res.status < 500) return res;
    console.log(`  ...waiting for identity services (attempt ${i}/${attempts}, status ${res.status})`);
    sleep(delaySec);
  }
  fail('identity services did not become ready in time');
  return null;
}

// Identity Hub participant body shared by consumer & provider (differs only in DID/host).
// serviceEndpoint uses the INTERNAL docker hostname (how the DID resolves on the network).
function participantBody(did, ctx, hubHost) {
  return {
    roles: [],
    serviceEndpoints: [{
      id: 'ConsumerCredentialService-ID', type: 'CredentialService',
      serviceEndpoint: `http://${hubHost}:13131/api/credentials/v1/participants/${ctx}`,
    }],
    active: true,
    participantId: did, participantContextId: did, did: did,
    key: {
      keyId: `${did}#key-1`, privateKeyAlias: `${did}-alias`,
      keyGeneratorParams: { algorithm: 'EdDSA', curve: 'Ed25519' },
    },
  };
}

export default function () {
  console.log(`\n=== DCP identity bootstrap (host: ${H}) ===\n`);

  // ── 1. Prepare Issuer ───────────────────────────────────────────────────────────
  const rIssuer = withRetry(() => http.post(`${ISSUER_ID_API}/v1alpha/participants`,
    JSON.stringify({
      roles: ['admin'],
      serviceEndpoints: [{
        id: 'Issuer-IssuerService', type: 'IssuerService',
        serviceEndpoint: `http://local-issuer-service:13132/api/issuance/v1alpha/participants/${ISSUER_CTX}`,
      }],
      active: true,
      participantId: ISSUER_DID, participantContextId: ISSUER_DID, did: ISSUER_DID,
      key: {
        keyId: `${ISSUER_DID}#key-1`, privateKeyAlias: `${ISSUER_DID}-alias`,
        keyGeneratorParams: { algorithm: 'EdDSA', curve: 'Ed25519' },
      },
    }), authJson(ADMIN_KEY)));
  step('CreateIssuerParticipant', rIssuer, [200, 201, 409]);
  if (rIssuer.status === 409) {
    console.log('\nIssuer already exists → dataspace was provisioned on a previous run. Nothing to do.');
    console.log('To re-provision cleanly: ./cleanup.sh on && ./install.sh on, then re-run this.\n');
    return;
  }
  const ISSUER_APIKEY = JSON.parse(rIssuer.body).apiKey.trim();

  step('addConsumerHolder', http.post(`${ISSUER_ISS_API}/v1alpha/participants/${ISSUER_CTX}/holders`,
    JSON.stringify({ holderId: CONSUMER_DID, did: CONSUMER_DID, name: CONSUMER_DID }),
    authJson(ISSUER_APIKEY)), [200, 201, 409]);

  step('addProviderHolder', http.post(`${ISSUER_ISS_API}/v1alpha/participants/${ISSUER_CTX}/holders`,
    JSON.stringify({ holderId: PROVIDER_DID, did: PROVIDER_DID, name: PROVIDER_DID }),
    authJson(ISSUER_APIKEY)), [200, 201, 409]);

  step('createAttestation', http.post(`${ISSUER_ISS_API}/v1alpha/participants/${ISSUER_CTX}/attestations`,
    JSON.stringify({
      attestationType: 'presentation',
      configuration: { credentialType: 'MembershipCredential', outputClaim: 'isMember', required: false },
      id: 'MC-Attestation',
    }), authJson(ISSUER_APIKEY)), [200, 201, 409]);

  step('createCredentialDef', http.post(`${ISSUER_ISS_API}/v1alpha/participants/${ISSUER_CTX}/credentialdefinitions`,
    JSON.stringify({
      attestations: ['MC-Attestation'], credentialType: 'MembershipCredential', format: 'VC1_0_JWT',
      id: 'MC-Cred-Def', jsonSchema: '{}', jsonSchemaUrl: '', mappings: [], validity: 15552000,
    }), authJson(ISSUER_APIKEY)), [200, 201, 409]);

  // ── 2. Prepare Consumer identity ──────────────────────────────────────────────────
  const rCons = step('CreateConsumerParticipant',
    http.post(`${CONSUMER_ID_API}/v1alpha/participants`,
      JSON.stringify(participantBody(CONSUMER_DID, CONSUMER_CTX, 'consumer-idhub')),
      authJson(ADMIN_KEY)), [200, 201]);
  const consBody = JSON.parse(rCons.body);
  const CONSUMER_IH_APIKEY = consBody.apiKey.trim();
  const CONSUMER_STS_SECRET = consBody.clientSecret.trim();

  step('RequestConsumerCredential',
    http.post(`${CONSUMER_ID_API}/v1alpha/participants/${CONSUMER_CTX}/credentials/request`,
      JSON.stringify({ issuerDid: ISSUER_DID, credentials: [{ format: 'VC1_0_JWT', type: 'MembershipCredential', id: 'MC-Cred-Def' }] }),
      authJson(CONSUMER_IH_APIKEY)), [200, 201, 202]);

  step('Vault: store consumersecret',
    http.post(`${VAULT_URL}/v1/secret/data/consumersecret`,
      JSON.stringify({ data: { content: CONSUMER_STS_SECRET } }),
      { headers: Object.assign({ 'X-Vault-Token': VAULT_TOKEN }, JSON_HDR) }), [200, 201, 204]);

  // ── 3. Prepare Provider identity ──────────────────────────────────────────────────
  const rProv = step('CreateProviderParticipant',
    http.post(`${PROVIDER_ID_API}/v1alpha/participants`,
      JSON.stringify(participantBody(PROVIDER_DID, PROVIDER_CTX, 'provider-idhub')),
      authJson(ADMIN_KEY)), [200, 201]);
  const provBody = JSON.parse(rProv.body);
  const PROVIDER_IH_APIKEY = provBody.apiKey.trim();
  const PROVIDER_STS_SECRET = provBody.clientSecret.trim();

  step('RequestProviderCredential',
    http.post(`${PROVIDER_ID_API}/v1alpha/participants/${PROVIDER_CTX}/credentials/request`,
      JSON.stringify({ issuerDid: ISSUER_DID, credentials: [{ format: 'VC1_0_JWT', type: 'MembershipCredential', id: 'MC-Cred-Def' }] }),
      authJson(PROVIDER_IH_APIKEY)), [200, 201, 202]);

  step('Vault: store providersecret',
    http.post(`${VAULT_URL}/v1/secret/data/providersecret`,
      JSON.stringify({ data: { content: PROVIDER_STS_SECRET } }),
      { headers: Object.assign({ 'X-Vault-Token': VAULT_TOKEN }, JSON_HDR) }), [200, 201, 204]);

  // ── 4. Simulated DCP flow — end-to-end verification ───────────────────────────────
  // Credential issuance is async; give the issuer a moment before presenting it.
  sleep(3);

  // Consumer asks its own STS for a self-issued token addressed to the provider.
  const rConsTok = step('Consumer STS token',
    http.post(`${CONSUMER_STS_API}/token`, {
      grant_type: 'client_credentials', client_secret: CONSUMER_STS_SECRET,
      client_id: CONSUMER_DID, audience: PROVIDER_DID,
      bearer_access_scope: 'org.eclipse.tractusx.vc.type:MembershipCredential:read',
    }), [200]);
  // The returned JWT carries a nested internal token in its payload's `token` claim.
  const consAccess = JSON.parse(rConsTok.body).access_token.trim();
  const consInner = JSON.parse(b64decode(consAccess.split('.')[1], 'rawurl', 's')).token.trim();

  // Provider unwraps that inner token at its own STS to get an access token for the
  // consumer's credential service.
  const rProvTok = step('Provider STS token',
    http.post(`${PROVIDER_STS_API}/token`, {
      grant_type: 'client_credentials', client_secret: PROVIDER_STS_SECRET,
      client_id: PROVIDER_DID, audience: CONSUMER_DID, token: consInner,
    }), [200]);
  const provAccess = JSON.parse(rProvTok.body).access_token.trim();

  // Provider queries the consumer's credential service for the MembershipCredential VP.
  const rPres = step('Query consumer presentation',
    http.post(`${CONSUMER_CREDS_API}/v1/participants/${CONSUMER_CTX}/presentations/query`,
      JSON.stringify({
        '@context': ['https://w3id.org/tractusx-trust/v0.8', 'https://identity.foundation/presentation-exchange/submission/v1'],
        type: 'PresentationQueryMessage', presentationDefinition: null,
        scope: ['org.eclipse.tractusx.vc.type:MembershipCredential:read'],
      }),
      { headers: Object.assign({ Authorization: `Bearer ${provAccess}` }, JSON_HDR) }), [200]);

  const presentation = JSON.parse(rPres.body).presentation;
  const vpOk = check(presentation, {
    'membership VP returned as a JWT': (p) => typeof p === 'string' && p.split('.').length === 3,
  });

  console.log('\n=== identity bootstrap complete ===');
  console.log(vpOk
    ? 'Verification passed — DCP negotiation/transfer prerequisites are in place. Run the k6 scenarios now.'
    : 'WARNING: provisioning done but the membership VP check did not pass; inspect the response above.');
}
