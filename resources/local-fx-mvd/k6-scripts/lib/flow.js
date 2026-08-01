import { group } from 'k6';
import { CONFIG, POLL_INTERVAL_MS, POLL_TIMEOUT_MS, commonTags, ASSET_SELECTOR } from './config.js';
import { postJson, getJson, pickDataset, offerIdFromDataset, extractEdr, responseBytes } from './http.js';
import { pollUntil } from './poll.js';
import { checkStatus, checkField } from './checks.js';
import { m } from './metrics.js';

// One transaction = one full DSP cycle through the CONSUMER Management API. The
// consumer is a standard EDC in all three connectors, so this driver is uniform;
// only config (URLs/DIDs/auth/seeding) differs. Request shapes mirror the proven
// Bruno collection exactly.

const tag = (phase) => Object.assign({}, commonTags, { phase });

// 1. Catalog request -> offer id for the chosen asset.
export function requestCatalog(assetId) {
  const aid = assetId || ASSET_SELECTOR;
  const body = {
    '@context': { '@vocab': 'https://w3id.org/edc/v0.0.1/ns/' },
    counterPartyAddress: CONFIG.providerDspAddress,
    counterPartyId: CONFIG.providerId,
    protocol: CONFIG.protocol,
    // EDC applies a DEFAULT PAGE LIMIT (50) when no querySpec is sent. The catalog
    // sweep leaves up to 1000 assets on the provider, so without this the target
    // asset silently falls off the first page — which is exactly how the 2026-07-31
    // payload-sweep ended up measuring the wrong asset at all five sizes. The limit
    // must exceed the largest catalog size the sweep seeds.
    querySpec: { offset: 0, limit: Number((CONFIG.catalog && CONFIG.catalog.pageLimit) || 2000) },
  };
  const res = postJson(`${CONFIG.consumerManagementUrl}/v3/catalog/request`, body, 'catalog');
  m.catalog.add(res.timings.duration, tag('catalog'));
  if (!checkStatus(res, 'catalog')) return null;
  const ds = pickDataset(res.json(), aid);
  // A miss here means the asset is genuinely absent from the catalog (not seeded, or
  // still beyond the page limit) — fail rather than negotiate for something else.
  if (!checkField({ ds }, 'ds', 'catalog')) return null;
  const offerId = offerIdFromDataset(ds);
  if (!checkField({ offerId }, 'offerId', 'catalog')) return null;
  return { offerId, assetId: (ds && ds['@id']) || aid };
}

// 2. Initiate contract negotiation -> negotiation id (async state machine).
export function negotiate(offerId, assetId) {
  const body = {
    '@context': { '@vocab': 'https://w3id.org/edc/v0.0.1/ns/', odrl: 'http://www.w3.org/ns/odrl/2/' },
    '@type': 'ContractRequest',
    counterPartyAddress: CONFIG.providerDspAddress,
    connectorId: CONFIG.providerId,
    protocol: CONFIG.protocol,
    policy: {
      '@context': 'http://www.w3.org/ns/odrl.jsonld',
      '@id': offerId,
      '@type': 'Offer',
      assigner: CONFIG.providerId,
      assignee: CONFIG.consumerId,
      target: assetId,
    },
  };
  const res = postJson(`${CONFIG.consumerManagementUrl}/v3/contractnegotiations`, body, 'negotiation');
  m.negotiationInit.add(res.timings.duration, tag('negotiation'));
  if (!checkStatus(res, 'negotiation')) return null;
  return res.json()['@id'];
}

// 3. Poll until the negotiation is FINALIZED (not merely AGREED). The
//    contractAgreementId is populated at AGREED, but the DSP state machine still
//    runs AGREED -> VERIFIED -> FINALIZED, and a provider rejects a transfer against
//    an agreement that isn't FINALIZED on its side ("Agreement record is not in
//    FINALIZED state" -> 400 -> fatal, no EDR). The consumer reaching FINALIZED
//    implies the provider finalized first, so it's the correct pre-transfer gate.
//    All three connectors use a standard EDC consumer, so state=="FINALIZED" is
//    uniform. Failure is still any *TERMINATED* state.
export function awaitAgreement(negotiationId) {
  const url = `${CONFIG.consumerManagementUrl}/v3/contractnegotiations/${negotiationId}`;
  const r = pollUntil({
    pollFn: () => getJson(url, 'negotiation-poll'),
    isDone: (b) => String(b['state'] || '').toUpperCase().indexOf('FINALIZED') >= 0
                   && b['contractAgreementId'] != null,
    isFailed: (b) => String(b['state'] || '').toUpperCase().indexOf('TERMINAT') >= 0,
    intervalMs: POLL_INTERVAL_MS,
    timeoutMs: POLL_TIMEOUT_MS,
    trend: m.timeToAgreed,
    counter: m.negotiationPolls,
    tags: tag('negotiation'),
  });
  if (r.ok) return r.body['contractAgreementId'];
  // The negotiation poll DOES expose state, so the reason is already in hand:
  // a provider rejection (TERMINATED) and a capacity timeout are different
  // findings and must not be aggregated into one failure count.
  lastFailureDetail = r.reason === 'failed'
    ? `terminated_${String((r.body && r.body['state']) || 'UNKNOWN').toUpperCase()}`
    : `timeout_in_${String((r.body && r.body['state']) || 'UNKNOWN').toUpperCase()}`;
  return null;
}

// 4. Initiate transfer process -> transfer id (async).
export function initTransfer(contractId) {
  const body = {
    '@context': { edc: 'https://w3id.org/edc/v0.0.1/ns/' },
    '@type': 'TransferRequestDto',
    protocol: CONFIG.protocol,
    contractId: contractId,
    counterPartyAddress: CONFIG.providerDspAddress,
    connectorId: CONFIG.providerId,
    transferType: CONFIG.transferType || 'HttpData-PULL',
  };
  const res = postJson(`${CONFIG.consumerManagementUrl}/v3/transferprocesses`, body, 'transfer');
  m.transferInit.add(res.timings.duration, tag('transfer'));
  if (!checkStatus(res, 'transfer')) return null;
  return res.json()['@id'];
}

// 5. Poll until the EDR (token + endpoint) is available. The endpoint 404s until
//    the transfer is STARTED — treat non-ready as "not done yet", not failure.
export function awaitEdr(transferId) {
  const url = `${CONFIG.consumerManagementUrl}/v3/edrs/${transferId}/dataaddress`;
  const r = pollUntil({
    pollFn: () => getJson(url, 'edr-poll'),
    isDone: (b) => extractEdr(b).authorization !== null,
    isFailed: null,
    intervalMs: POLL_INTERVAL_MS,
    timeoutMs: POLL_TIMEOUT_MS,
    trend: m.timeToEdr,
    counter: m.edrPolls,
    tags: tag('transfer'),
  });
  if (r.ok) return extractEdr(r.body);
  // The EDR endpoint 404s both while the transfer is still starting AND after it
  // has TERMINATED, so a timeout alone cannot distinguish "slow" from "broken" —
  // every failure looked like a 30 s timeout in the first campaign. One extra GET
  // per FAILED transaction (never on the success path, so the observer effect is
  // untouched at low failure rates) recovers the real terminal state.
  lastFailureDetail = diagnoseTransfer(transferId);
  return null;
}

// Why the last phase failed. Set by the two async waits, read by runTransaction
// so the failure counter carries a reason, not just a phase.
let lastFailureDetail = 'unknown';

// One-shot terminal-state probe. Deliberately NOT part of the poll loop.
export function diagnoseTransfer(transferId) {
  const res = getJson(`${CONFIG.consumerManagementUrl}/v3/transferprocesses/${transferId}`, 'transfer-diagnose');
  let body = null;
  try { body = res.json(); } catch (e) { body = null; }
  if (!body) return `http_${res.status}`;
  const state = String(body['state'] || body['edc:state'] || 'UNKNOWN').toUpperCase();
  // TERMINATED/ERROR are real rejections; anything still in-flight at timeout is
  // a capacity symptom (the state machine never got to this transfer in time).
  return state.indexOf('TERMINAT') >= 0 || state.indexOf('ERROR') >= 0 ? `terminated_${state}` : `timeout_in_${state}`;
}

// 6. Pull the data. The EDR token is sent RAW as Authorization (NOT "Bearer ..."),
//    matching the working Bruno flow. URL is the host-reachable public data-plane
//    URL from config (the EDR's own `endpoint` is a docker-internal host that
//    won't resolve from the k6 host) unless edr.useEdrEndpoint is set.
export function pullData(edr, sizeHintBytes, opts) {
  const url = (CONFIG.edr && CONFIG.edr.useEdrEndpoint && edr.endpoint) ? edr.endpoint : (CONFIG.dataPlanePublicUrl || edr.endpoint);
  const res = getJson(url, 'datapull', { Authorization: edr.authorization }, opts);
  m.datapull.add(res.timings.duration, tag('datapull'));
  const okStatus = checkStatus(res, 'datapull');
  if (!okStatus) return null;
  const bytes = responseBytes(res, sizeHintBytes);
  if (res.timings.duration > 0 && bytes > 0) {
    m.throughput.add((bytes / 1e6) / (res.timings.duration / 1000), tag('datapull')); // MB/s
    m.payloadBytes.add(bytes, tag('datapull'));
  }
  return res;
}

// Catalog -> negotiation -> transfer -> EDR (no pull). Used by payload-sweep to
// establish a reusable EDR once in setup() and isolate the data plane.
export function establishEdr(assetId) {
  const cat = requestCatalog(assetId);
  if (!cat) return null;
  const negId = negotiate(cat.offerId, cat.assetId);
  if (!negId) return null;
  const agreementId = awaitAgreement(negId);
  if (!agreementId) return null;
  const transferId = initTransfer(agreementId);
  if (!transferId) return null;
  return awaitEdr(transferId);
}

// Catalog-only probe for the catalog-size sweep (G1.RQ6): issues ONE catalog
// request (recording catalog_duration) and nothing else, isolating control-plane
// catalog cost from the negotiation/transfer cycle as catalog size grows. Counts
// success/failure like a single-phase transaction so the failed-rate threshold
// still guards the run.
export function catalogProbe(assetId) {
  const cat = requestCatalog(assetId);
  if (cat) {
    m.succeeded.add(1, commonTags);
    m.failedRate.add(false, commonTags);
  } else {
    const ft = Object.assign({}, commonTags, { failed_phase: 'catalog' });
    m.failed.add(1, ft);
    m.failedRate.add(true, ft);
  }
  return !!cat;
}

// The full transaction (one VU iteration). Short-circuits on the first failed
// phase, tags WHERE it died (failed_phase) for the discussion chapter, and on
// success records the composite end-to-end wall time.
export function runTransaction(assetId) {
  let okAll = false;
  let failedPhase = 'none';
  lastFailureDetail = 'unknown';
  const t0 = Date.now();

  group('dsp_transaction', () => {
    const cat = requestCatalog(assetId);
    if (!cat) { failedPhase = 'catalog'; return; }
    const negId = negotiate(cat.offerId, cat.assetId);
    if (!negId) { failedPhase = 'negotiation_init'; return; }
    const agreementId = awaitAgreement(negId);
    if (!agreementId) { failedPhase = 'negotiation'; return; }
    const transferId = initTransfer(agreementId);
    if (!transferId) { failedPhase = 'transfer_init'; return; }
    const edr = awaitEdr(transferId);
    if (!edr) { failedPhase = 'transfer'; return; }
    const pulled = pullData(edr);
    if (!pulled) { failedPhase = 'datapull'; return; }
    okAll = true;
  });

  if (okAll) {
    m.e2e.add(Date.now() - t0, commonTags);
    m.succeeded.add(1, commonTags);
    m.failedRate.add(false, commonTags);
  } else {
    // failed_reason stays LOW cardinality (a fixed set of state names), per the
    // tag-cardinality rule in config.js — never a transfer id.
    const detail = (failedPhase === 'negotiation' || failedPhase === 'transfer') ? lastFailureDetail : 'phase_error';
    const ft = Object.assign({}, commonTags, { failed_phase: failedPhase, failed_reason: detail });
    m.failed.add(1, ft);
    m.failedRate.add(true, ft);
    m.failureReason.add(1, ft);
    if (detail.indexOf('terminated') === 0) m.failedTerminated.add(1, ft);
    else if (detail.indexOf('timeout') === 0) m.failedTimeout.add(1, ft);
    else m.failedPhaseError.add(1, ft);   // synchronous phase: the HTTP call failed
  }
  return okAll;
}
