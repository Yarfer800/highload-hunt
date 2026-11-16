import { check } from 'k6'
import http from 'k6/http'
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js'

// SLO-driven load test. Configure via env, never edit inline numbers.
//   BASE_URL=http://localhost:8080
//   TARGET_RPS=300
//   WARMUP=60s  DURATION=180s
//   PATH=/api/items?id=1..N
//
// Run: k6 run --summary-export=results/k6-100pct.json templates/k6-load.js

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080'
const TARGET_RPS = Number(__ENV.TARGET_RPS || 300)
const WARMUP = __ENV.WARMUP || '60s'
const DURATION = __ENV.DURATION || '180s'
const PATH = __ENV.PATH || '/api/items'
const ID_MAX = Number(__ENV.ID_MAX || 100000)

export const options = {
  // Open model: arrival rate is fixed, latency cannot hide saturation.
  scenarios: {
    warmup: {
      executor: 'constant-arrival-rate',
      exec: 'read',
      rate: Math.max(1, Math.floor(TARGET_RPS * 0.1)),
      timeUnit: '1s',
      duration: WARMUP,
      preAllocatedVUs: Math.max(10, Math.floor(TARGET_RPS * 0.1)),
      maxVUs: Math.max(50, TARGET_RPS),
      tags: { phase: 'warmup' },
    },
    steady: {
      executor: 'constant-arrival-rate',
      exec: 'read',
      startTime: WARMUP,
      rate: TARGET_RPS,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.max(20, Math.floor(TARGET_RPS * 0.5)),
      maxVUs: Math.max(100, TARGET_RPS * 3),
      tags: { phase: 'steady' },
    },
  },
  thresholds: {
    // Gate: a failed threshold makes k6 exit non-zero.
    'http_req_failed{phase:steady}': ['rate<0.005'],
    'http_req_duration{phase:steady}': ['p(95)<200', 'p(99)<500'],
    // Generator must not be the bottleneck.
    dropped_iterations: ['count==0'],
    checks: ['rate>0.99'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  discardResponseBodies: false,
  noConnectionReuse: false,
  userAgent: 'highload-hunt/1.0',
}

export function read() {
  const id = randomIntBetween(1, ID_MAX)
  const url = `${BASE_URL}${PATH}${PATH.includes('?') ? '&' : '?'}id=${id}`
  const res = http.get(url, { tags: { name: 'items_read' } })

  check(res, {
    'status is 2xx': (r) => r.status >= 200 && r.status < 300,
    'body has payload': (r) => typeof r.body === 'string' && r.body.length > 0,
    'body is not an error envelope': (r) => !/"(error|errors)"\s*:/.test(r.body || ''),
    'latency under hard cap': (r) => r.timings.duration < 5000,
  })
}

// Machine-readable artifact for scripts/slo-gate.sh and the report.
export function handleSummary(data) {
  const out = __ENV.RESULT_FILE || 'results/k6-summary.json'
  return {
    [out]: JSON.stringify(data, null, 2),
    stdout: textSummary(data),
  }
}

function textSummary(data) {
  const m = data.metrics
  const steady = m['http_req_duration{phase:steady}'] || m.http_req_duration || {}
  const failed = m['http_req_failed{phase:steady}'] || m.http_req_failed || {}
  return [
    `target_rps=${TARGET_RPS} duration=${DURATION}`,
    `p95=${fmt(steady['p(95)'])}ms p99=${fmt(steady['p(99)'])}ms`,
    `error_rate=${(((failed.rate || 0) * 100)).toFixed(3)}%`,
    `achieved_rps=${fmt(m.http_reqs && m.http_reqs.rate)}`,
    `dropped_iterations=${(m.dropped_iterations && m.dropped_iterations.count) || 0}`,
    '',
  ].join('\n')
}

function fmt(v) {
  return v === undefined ? 'n/a' : Number(v).toFixed(1)
}
