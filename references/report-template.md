# Performance report template

Copy to `PERF-REPORT.md` at the repo root. Fill every section. Delete nothing; write "not measured" with a reason instead.

```markdown
# Performance report: <service / endpoint>

Date: YYYY-MM-DD
Author: <agent / human>
Tier: S | M | L
Verdict: PASS | FAIL | BLOCKED

## TL;DR

- SLO at <rate> rps: **<met | missed>**. p95 <x> ms (target <y>), p99 <x> ms (target <y>), errors <x>%.
- Breaking point: **<n> rps**, first failure mode: <latency wall | pool exhaustion | OOM | 5xx>.
- Findings: <n> confirmed, <n> suspected, <n> ruled out.
- Fixes applied: <n>, each proven by an identical re-run. | Fixes not applied: awaiting approval.

## Environment

| Item | Value |
|------|-------|
| Commit | `<sha>` |
| Runtime | node <ver> / python <ver> / go <ver> / jvm <ver> |
| Server command | `...` |
| Datastore | Postgres <ver>, pool <n>, reset via `<cmd>` |
| Hardware | <cpu model, cores, ram>, service limit <n> cpu / <n> MiB |
| Generator | k6 <ver> / locust <ver>, separate host: yes/no |
| Dataset | <rows>, seed `<n>`, reset+seed command |
| Observability | <metrics endpoint, DB stats, profiler> |

## Load model

- Model: open / closed
- Target: <n> rps or <n> users, think time <n> s
- Mix: <x>% read / <y>% write / <z>% other
- Duration: <n> s warmup + <n> s steady + <n> s cooldown
- Reproduce: `bash tests/perf/run.sh <profile>`

## SLO

| Metric | Target | Source |
|--------|--------|--------|
| p95 | <= <x> ms | <where agreed> |
| p99 | <= <x> ms | |
| error rate | <= <x>% | |
| throughput | >= <n> rps | |
| saturation | CPU < 80%, pool < 80%, RSS flat | |
| correctness | <assertions> | |

If the SLO was derived during this hunt, say so and show the derivation.

## Results

Runs at target rate, 3 repeats. Median in bold.

| Run | Rate | p50 | p95 | p99 | max | errors | samples | dropped iters | CPU | pool |
|-----|------|-----|-----|-----|-----|--------|---------|---------------|-----|------|
| r1  | | | | | | | | | | |
| r2  | | | | | | | | | | |
| r3  | | | | | | | | | | |

Spread: p95 min <x> / median <x> / max <x> ms (<x>%).

### Ladder

| Level | Rate | p95 | p99 | errors | Observation |
|-------|------|-----|-----|--------|-------------|
| 10% | | | | | |
| 50% | | | | | |
| 100% | | | | | |
| 150% | | | | | |
| breakpoint | | | | | |

Knee: **<n> rps**. Curve shape: <flat until X, then superlinear>.

### Baseline (single user)

p50 <x> ms, p95 <x> ms, p99 <x> ms at 1 rps for 60 s. Floor for all comparisons.

## Findings

Ranked by impact. One block per finding. A finding without a reproducer is not a finding.

### F1: <short title>

- **Severity**: critical | high | medium | low
- **Reproducer**: `tests/perf/<file>` — `bash tests/perf/run.sh <name>`
- **Metric**: p95 <before> ms -> <expected> ms at <rate> rps; errors <x>%
- **Evidence**: <profile path, query plan, metric screenshot path, log line>
- **Mechanism**: <one paragraph: what code path, query, or lock causes it>
- **Fix direction**: <one sentence, smallest change that removes the mechanism>
- **Risk of fix**: <what could regress>
- **Status**: proposed | approved | fixed | reverted

### F2: ...

## Ruled out

| Hypothesis | Test | Result |
|------------|------|--------|
| DB pool too small | raised pool to 50, re-ran | no change, pool wait 0 ms |
| GC pauses | GC log during 100% run | max 12 ms, not significant |

Ruling out matters: it prevents the next person from repeating the work.

## Fixes (if approved)

| Finding | Change | Before p95 | After p95 | Before rps | After rps | SLO | Regression test |
|---------|--------|-----------|-----------|------------|-----------|-----|-----------------|
| F1 | <one line> | | | | | pass/fail | `tests/perf/<file>` |

Rules used: one fix per change, identical scenario, same seed, median of 3.

## Not tested

- <scenario, reason, and what it would require>
- Shared staging, no production-like data, no write traffic, etc.

## Verdict

<One paragraph with numbers. PASS means the SLO table is satisfied on 3 runs and regression tests are committed. FAIL means findings are listed and fixes await approval. BLOCKED means measurement was impossible and states exactly what is missing.>

## Artifacts

- Raw results: `tests/perf/results/<run>.json`
- Profiles: `<path>`
- Server logs: `<path>`
- CI job: `<url or workflow file>`
```

## Report rules

1. Numbers, not adjectives. "Significantly faster" is not a result.
2. Every table row must be reproducible from the environment section.
3. Keep raw files; the report links to them.
4. State which side the latency was measured on (client or server).
5. If a run was invalid (generator saturated, bad data, restart), mark it invalid and exclude it; do not quietly delete it.
6. The verdict line is the only place that decides PASS/FAIL. Nothing else in the document may contradict it.
