import http from 'k6/http';
import { CONFIG } from './config.js';

// Inject the connector auth header ONLY if configured. The factoryx MVD runs the
// Management API with no auth (headerName=null) — other connectors set their own
// header name/value in config, never hardcoded here.
function headers(extra) {
  const h = Object.assign({ 'Content-Type': 'application/json', Accept: 'application/json' }, extra || {});
  if (CONFIG.auth && CONFIG.auth.headerName) {
    h[CONFIG.auth.headerName] = CONFIG.auth.headerValue;
  }
  return h;
}

export function postJson(url, body, phase) {
  return http.post(url, JSON.stringify(body), { headers: headers(), tags: { phase } });
}

export function getJson(url, phase, extraHeaders) {
  return http.get(url, { headers: headers(extraHeaders), tags: { phase } });
}

// ---- JSON-LD parse helpers (tolerant of single-object-vs-array & prefixes) ----

export function asArray(x) {
  if (x === undefined || x === null) return [];
  return Array.isArray(x) ? x : [x];
}

// Catalog `dcat:dataset` is a single object when one asset is offered and an
// array when several are. Pick by asset @id, falling back to the first dataset.
export function pickDataset(catalogBody, assetId) {
  const datasets = asArray(catalogBody['dcat:dataset'] || catalogBody['dataset']);
  if (datasets.length === 0) return null;
  if (assetId) {
    const match = datasets.find((d) => d && d['@id'] === assetId);
    if (match) return match;
  }
  return datasets[0];
}

// Offer id lives at dataset.odrl:hasPolicy.@id (hasPolicy may be object or array).
export function offerIdFromDataset(ds) {
  if (!ds) return null;
  const policy = asArray(ds['odrl:hasPolicy'] || ds['hasPolicy'])[0];
  return policy ? policy['@id'] : null;
}

// The EDR dataaddress response is a flat object with `endpoint` + `authorization`
// (sometimes nested under dataAddress). Tolerate both shapes.
export function extractEdr(body) {
  if (!body) return { endpoint: null, authorization: null };
  const da = body.dataAddress || {};
  return {
    endpoint: body.endpoint || da.endpoint || null,
    authorization: body.authorization || da.authorization || null,
  };
}
