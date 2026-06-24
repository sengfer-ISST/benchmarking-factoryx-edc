import { Trend, Counter, Rate } from 'k6/metrics';

// Custom metrics. The two `time_to_*` Trends are the heart of RQ4 (the async DSP
// cycle): they capture composite wall-times that NO single HTTP request does.
// The `*_polls` counters quantify the observer effect of polling.
// `true` = isTime, so values render as durations.
export const m = {
  catalog: new Trend('catalog_duration', true),
  negotiationInit: new Trend('negotiation_init_duration', true),
  timeToAgreed: new Trend('time_to_agreed', true),
  transferInit: new Trend('transfer_init_duration', true),
  timeToEdr: new Trend('time_to_edr', true),
  datapull: new Trend('datapull_duration', true),
  throughput: new Trend('data_throughput_MBps'),
  e2e: new Trend('e2e_transaction_duration', true),

  succeeded: new Counter('dsp_transactions_succeeded'),
  failed: new Counter('dsp_transactions_failed'),
  failedRate: new Rate('dsp_transaction_failed_rate'),

  negotiationPolls: new Counter('negotiation_polls'),
  edrPolls: new Counter('edr_polls'),
};

// handleSummary hook: writes the full machine-readable summary into the run
// folder (RESULT_DIR, set by run.sh) and a compact human summary to stdout.
export function buildSummary(data) {
  const dir = __ENV.RESULT_DIR || '.';
  const out = {};
  out[`${dir}/k6-summary.json`] = JSON.stringify(data, null, 2);
  out['stdout'] = renderText(data);
  return out;
}

function statLine(label, name, data, isTime) {
  const v = data.metrics[name] && data.metrics[name].values;
  if (!v) return `  ${label.padEnd(26)} (no data)`;
  const u = isTime ? ' ms' : '';
  if (v['p(95)'] !== undefined) {
    return `  ${label.padEnd(26)} p50=${num(v.med)}${u}  p95=${num(v['p(95)'])}${u}  p99=${num(v['p(99)'])}${u}  max=${num(v.max)}${u}  n=${v.count}`;
  }
  if (v.rate !== undefined && v.passes !== undefined) {
    return `  ${label.padEnd(26)} rate=${(v.rate * 100).toFixed(2)}%  (pass=${v.passes} fail=${v.fails})`;
  }
  if (v.count !== undefined) {
    return `  ${label.padEnd(26)} count=${v.count}${v.rate !== undefined ? `  rate=${v.rate.toFixed(3)}/s` : ''}`;
  }
  return `  ${label.padEnd(26)} ${JSON.stringify(v)}`;
}

function num(x) { return (x === undefined || x === null) ? '-' : Number(x).toFixed(1); }

function renderText(data) {
  const L = [];
  L.push('');
  L.push('================ DSP benchmark summary ================');
  L.push('-- per-phase latency --');
  L.push(statLine('catalog', 'catalog_duration', data, true));
  L.push(statLine('negotiation init (POST)', 'negotiation_init_duration', data, true));
  L.push(statLine('time-to-AGREED (async)', 'time_to_agreed', data, true));
  L.push(statLine('transfer init (POST)', 'transfer_init_duration', data, true));
  L.push(statLine('time-to-EDR (async)', 'time_to_edr', data, true));
  L.push(statLine('data pull', 'datapull_duration', data, true));
  L.push('-- end-to-end + throughput --');
  L.push(statLine('e2e transaction', 'e2e_transaction_duration', data, true));
  L.push(statLine('data throughput (MB/s)', 'data_throughput_MBps', data, false));
  L.push('-- outcomes --');
  L.push(statLine('transactions succeeded', 'dsp_transactions_succeeded', data, false));
  L.push(statLine('transactions failed', 'dsp_transactions_failed', data, false));
  L.push(statLine('failed rate', 'dsp_transaction_failed_rate', data, false));
  L.push('-- observer effect (poll load) --');
  L.push(statLine('negotiation polls', 'negotiation_polls', data, false));
  L.push(statLine('edr polls', 'edr_polls', data, false));
  L.push('=======================================================');
  L.push(`(full summary -> ${__ENV.RESULT_DIR || '.'}/k6-summary.json; POLL_INTERVAL_MS=${__ENV.POLL_INTERVAL_MS || 250}; IDENTITY_MODE=${__ENV.IDENTITY_MODE || 'on'})`);
  L.push('');
  return L.join('\n');
}
