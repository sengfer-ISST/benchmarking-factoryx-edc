import { check } from 'k6';

// Centralized checks so the success/failure signal that thresholds key off stays
// consistent across phases. Every check is tagged with its phase, so you can
// threshold e.g. `checks{phase:negotiation}`.
export function checkStatus(res, phase, okCodes) {
  const codes = okCodes || [200, 201];
  return check(res, { [`${phase} status ok`]: (r) => codes.indexOf(r.status) >= 0 }, { phase });
}

export function checkField(obj, field, phase) {
  return check(obj, {
    [`${phase} has ${field}`]: (o) => o !== null && o !== undefined && o[field] !== undefined && o[field] !== null,
  }, { phase });
}
