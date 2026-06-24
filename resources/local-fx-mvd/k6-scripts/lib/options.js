// Options shared by every scenario. Scenarios spread this in and add their own
// `scenarios` (executor) + `thresholds`. Centralized here so the percentile set
// reported in the summary is identical across experiments.
export const baseOptions = {
  // p(99) is NOT in k6's default set; we need it for tail-latency claims.
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'],
  // Keep response bodies by default so the data pull can size the payload.
  // The payload-sweep scenario overrides this to true (100 MB bodies × VUs
  // would exhaust memory) and sizes throughput from PAYLOAD_BYTES instead.
  discardResponseBodies: false,
  // Don't let one connection-refused (stack still booting) abort the run.
  noConnectionReuse: false,
};
