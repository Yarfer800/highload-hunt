# Anatomy of an explicit perf E2E test

A perf E2E test is a normal test that happens to generate load and assert on distributions. It runs unattended, fails the build, and leaves artifacts.

## Non-negotiables

1. One command runs it.
2. It starts or targets a real service with a real datastore.
3. It seeds deterministic data and cleans up.
4. It asserts on latency percentiles, error rate, and correctness.
5. It exits non-zero on violation.
6. It writes a machine-readable result file.
7. It is tagged so regular fast CI can skip it.

## Layout

```
tests/perf/
├── README.md                 # what each test answers, how to run
├── seed.ts | seed.py | seed.go
├── api.items.load.test.ts    # HTTP load, k6-driven or in-runner
├── db.items.concurrency.test.ts
├── journey.checkout.e2e.spec.ts
├── results/                  # gitignored
└── thresholds.ts             # SLO constants, single source of truth
```

Put thresholds in one file so the report, tests, and CI cannot drift apart.

## Skeleton

```ts
// tests/perf/api.items.load.test.ts
import { beforeAll, afterAll, describe, it, expect } from 'vitest'
import { spawn, execFileSync } from 'node:child_process'
import { SLO } from './thresholds'

let server: ReturnType<typeof spawn>

describe('perf: GET /api/items', () => {
  beforeAll(async () => {
    execFileSync('npm', ['run', 'db:reset'], { stdio: 'inherit' })
    execFileSync('npm', ['run', 'seed:perf'], { stdio: 'inherit' })  // fixed seed
    server = spawn('npm', ['run', 'start:prod'], { stdio: 'pipe', env: { ...process.env, NODE_ENV: 'production' } })
    await waitForHttp('http://localhost:8080/health', 60_000)
  }, 180_000)

  afterAll(() => { server?.kill('SIGTERM') })

  it('meets the SLO at target rate', async () => {
    execFileSync('k6', [
      'run',
      `--summary-export=${RESULT}`,
      'tests/perf/k6/items.js',
    ], {
      stdio: 'inherit',
      env: { ...process.env, BASE_URL, TARGET_RPS: String(SLO.rps), DURATION: '180s' },
    })
    const m = readSummary(RESULT)
    expect(m.p95).toBeLessThanOrEqual(SLO.p95)
    expect(m.p99).toBeLessThanOrEqual(SLO.p99)
    expect(m.errorRate).toBeLessThanOrEqual(SLO.errorRate)
    expect(m.rps).toBeGreaterThanOrEqual(SLO.rps * 0.95)
    expect(m.droppedIterations).toBe(0)      // generator was not the bottleneck
    expect(m.correctnessFailures).toBe(0)    // responses were actually right
  }, 600_000)
})
```

## Required sections in the test

| Section | Why it must exist |
|---------|-------------------|
| Setup | Reset DB and seed with a fixed seed; a dirty DB makes runs incomparable |
| Warmup | 30-60 s at low rate, excluded from percentiles; JIT and pool fill are not steady state |
| Load | Fixed generator file, rate, duration; no magic numbers inline |
| Correctness | Validate status, payload shape, and a content sample under load |
| Assertions | p95, p99, error rate, achieved rps, generator health |
| Artifacts | JSON summary, server log tail, optional profile path |
| Teardown | Kill server, drop test DB, no leaked containers |

## Test types and the question each answers

| Type | Duration | Question |
|------|----------|----------|
| Smoke load | 30-60 s at 10% | Does it work at all under concurrency? |
| SLO run | 60 s warmup + 180 s steady | Do we meet the contract? |
| Spike | 30 s at 5x, then back | Does it recover, or does a queue stay full? |
| Soak | 30-120 min at 70% | Leaks, degradation, connection churn, disk growth |
| Breakpoint | Ramp to failure | Where is the knee, and what fails first? |
| Chaos under load | Varies | Does a dependency restart trigger a retry storm? |

## Correctness under load

The most common silent failure: the load test passes because it never checked the body. Assert:

- Status distribution: 2xx share, zero 5xx, expected 4xx only from intentional invalid cases.
- Payload: required fields present, counts within expected range, no `null` explosion.
- Cross-check: for writes, count rows after the run; retries must not duplicate.
- Auth: the test uses a real token flow, not a bypass flag.

## Data discipline

- Seed with a fixed RNG seed; store it in the result file.
- Keep dataset size stable between runs; growth invalidates comparison.
- Randomize across the key space, not one hot id. Include at least one realistic worst case (largest tenant, longest list).
- Isolate from developer data: separate DB or schema per run, dropped afterwards.

## CI integration

```yaml
perf-smoke:
  if: github.event_name == 'pull_request'
  steps:
    - run: npm run db:reset && npm run seed:perf
    - run: k6 run --summary-export=results/smoke.json tests/perf/k6/items.js
      env: { TARGET_RPS: '30', DURATION: '60s' }
    - run: bash scripts/slo-gate.sh --file results/smoke.json --p95 250 --err 1 --rps 28
```

Scheduled full ladder runs on a dedicated runner, not on the shared PR pool. Record the runner class in the report; results from different hardware are not comparable.

## Flake policy

- 3 consecutive runs; compare medians.
- Accept 10% variance. If the SLO margin is thinner than the variance, either tighten the environment or widen the SLO with the user's agreement.
- Never retry until green. A flaky perf test is a finding about the measurement setup.
- If a test is nondeterministic because of shared CI, move it to a dedicated runner and say so.
