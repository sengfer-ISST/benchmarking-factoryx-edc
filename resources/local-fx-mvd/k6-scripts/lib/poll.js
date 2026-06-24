import { sleep } from 'k6';

// The central async abstraction. EDC negotiation and transfer are asynchronous
// state machines: you POST, get a non-terminal state, then poll a GET until
// terminal. This isolates that logic so both reuse identical, audited code.
//
// Fixed interval (no backoff) on purpose — it keeps the time-to-state
// quantization uniform and analyzable (methodology §A4). Records wall-time into
// `trend` and counts every poll into `counter` so the polling observer effect is
// measured, not hidden. Returns on the FIRST `isDone`, so a near-synchronous
// provider (basyx) is handled correctly — only the interpretation differs.
export function pollUntil(opts) {
  const { pollFn, isDone, isFailed, intervalMs, timeoutMs, trend, counter, tags } = opts;
  const t0 = Date.now();
  for (;;) {
    const res = pollFn();
    if (counter) counter.add(1, tags);

    let body = null;
    try { body = res.json(); } catch (e) { body = null; } // 404/empty while not ready

    const elapsed = Date.now() - t0;
    if (body && isDone(body, res)) {
      if (trend) trend.add(elapsed, tags);
      return { ok: true, body, res, elapsedMs: elapsed };
    }
    if (body && isFailed && isFailed(body, res)) {
      return { ok: false, reason: 'failed', body, res, elapsedMs: elapsed };
    }
    if (elapsed >= timeoutMs) {
      return { ok: false, reason: 'timeout', body, res, elapsedMs: elapsed };
    }
    sleep(intervalMs / 1000); // k6 sleep is in seconds
  }
}
