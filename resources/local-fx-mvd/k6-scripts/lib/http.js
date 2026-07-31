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

// `opts.discardBody` sets responseType per REQUEST rather than via the global
// `discardResponseBodies` option. The global switch nulls EVERY body in the VM —
// including the catalog response parsed in setup() — which silently turns
// `res.json()` into "the body is null" (this cost the payload-sweep 15 runs).
// Scoping it to the one request that streams 100 MB keeps the control-plane
// JSON parseable everywhere else.
export function getJson(url, phase, extraHeaders, opts) {
  const params = { headers: headers(extraHeaders), tags: { phase } };
  if (opts && opts.discardBody) params.responseType = 'none';
  return http.get(url, params);
}

// Bytes actually transferred. With a discarded body `res.body` is null, so fall
// back to Content-Length and only then to the caller's hint — a throughput
// figure computed from a hint that was never set would be a silent zero.
export function responseBytes(res, hintBytes) {
  if (res && res.body && res.body.length) return res.body.length;
  const cl = res && res.headers && (res.headers['Content-Length'] || res.headers['content-length']);
  if (cl && Number(cl) > 0) return Number(cl);
  return hintBytes || 0;
}

// ---- JSON-LD parse helpers (tolerant of single-object-vs-array & prefixes) ----

export function asArray(x) {
  if (x === undefined || x === null) return [];
  return Array.isArray(x) ? x : [x];
}

// Catalog `dcat:dataset` is a single object when one asset is offered and an array
// when several are. Pick by asset @id.
//
// NO SILENT FALLBACK when a specific asset was asked for. The old behaviour —
// "not found, use datasets[0]" — meant the driver benchmarked whatever happened to
// be first: the 2026-07-31 payload-sweep pulled the same 5,645-byte default asset at
// every size because ~1000 leftover catalog-sweep assets pushed `payload-1KB` off
// the first catalog page. Every run looked healthy and the sweep varied nothing.
// Returning null here turns that into a visible failure instead.
export function pickDataset(catalogBody, assetId) {
  const datasets = asArray(catalogBody['dcat:dataset'] || catalogBody['dataset']);
  if (datasets.length === 0) return null;
  if (!assetId) return datasets[0];
  return datasets.find((d) => d && d['@id'] === assetId) || null;
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
