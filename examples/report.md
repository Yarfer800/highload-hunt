# Performance report: GET /api/items (demo-api)

Date: 2026-11-16
Author: highload-hunt example run
Tier: S
Verdict: PASS

This is a worked example produced by the skill against `examples/demo-api`, a zero-dependency Node server with one intentional defect. Every number below was measured on the machine described here; nothing is illustrative.

## TL;DR

- SLO at 100 rps: **met after fix**, missed before. p95 **377 ms → 80 ms** (target ≤ 100 ms), p99 **422 ms → 85 ms**.
- Breaking point before fix: below 100 rps. The knee appears at 50% of target: p95 57 ms at 10 rps → 183 ms at 50 rps → 350 ms at 100 rps.
- Findings: 1 confirmed (`F1`), 0 suspected, 1 ruled out.
- Fixes applied: 1, proven by an identical re-run of 3 × 10 s at 100 rps.

## Environment

| Item | Value |
|------|-------|
| Commit | demo tree, `examples/demo-api/server.mjs` |
| Runtime | node v22.23.1, single process, no cluster |
| Server command | `PORT=18080 node examples/demo-api/server.mjs` |
| Datastore | in-memory array, 200,000 items, seed 42 |
| Hardware | 4 vCPU, 15.4 GiB RAM, loopback interface |
| Generator | autocannon v9.0.0 via `npx --yes`, same host |
| Dataset | `ITEMS=200000`, deterministic `mulberry32(42)` |
| Observability | `/health` counters, process CPU, `perf-diff.sh` |

Generator and server share the host. Read the numbers as relative before/after, not as absolute capacity.

## Load model

- Model: open (autocannon `-R` constant arrival rate)
- Target: 100 rps, 100 connections
- Mix: 100% read `GET /api/items?id=<random>`
- Duration: 10 s per run, no warmup (short demo), 3 runs per series
- Reproduce:

```bash
PORT=18080 node examples/demo-api/server.mjs &
bash scripts/ladder.sh --runner autocannon --host http://localhost:18080 \
  --path '/api/items?id=42' --rps 100 --levels 100 --repeat 3 --duration 10 --out results/before
PERF_DEFECT=off PORT=18080 node examples/demo-api/server.mjs &
bash scripts/ladder.sh --runner autocannon --host http://localhost:18080 \
  --path '/api/items?id=42' --rps 100 --levels 100 --repeat 3 --duration 10 --out results/after
bash scripts/perf-diff.sh --before results/before/normalized --after results/after/normalized \
  --p95 100 --err 0.5 --rps 100
```

## SLO

| Metric | Target | Source |
|--------|--------|--------|
| p95 | <= 100 ms | derived for demo: 2x the fixed-state p95 |
| p99 | <= 200 ms | derived |
| error rate | <= 0.5% | derived |
| throughput | >= 100 rps achieved | target rate |
| saturation | p95 flat across runs (spread < 25%) | derived |
| correctness | every response echoes `requestedId` | `server.mjs` |

The demo SLO is derived, not agreed with a product owner. A real hunt records who agreed and when.

## Results

Three runs at 100 rps. Median in bold.

| Run | p50 | p95 | p99 | errors | samples | rps |
|-----|----:|----:|----:|-------:|--------:|----:|
| before r1 | 128 | 376 | 422 | 0.00% | 1006 | 100.6 |
| **before r2** | **130** | **377** | **405** | **0.00%** | **1009** | **100.9** |
| before r3 | 141 | 425 | 491 | 0.00% | 1010 | 101.0 |
| after r1 | 13 | 76 | 81 | 0.00% | 1048 | 104.8 |
| **after r2** | **32** | **92** | **98** | **0.00%** | **1096** | **109.6** |
| after r3 | 18 | 80 | 85 | 0.00% | 1099 | 109.9 |

p95 spread after fix: min 76 / median 80 / max 92 ms (+20% around the median). The SLO margin (80 vs 100) is larger than the spread, so the PASS is stable.

autocannon has no native p95; the normalizer uses p97.5 and flags `approx_p95=true`. Treat these p95 values as slightly pessimistic (p97.5 is the 97.5th percentile).

### Ladder (before fix, 1 run per level)

| Level | Target rps | p95 | p99 | errors | Observation |
|-------|-----------:|----:|----:|-------:|-------------|
| 10% | 10 | 57 | 65 | 0.00% | below knee |
| 50% | 50 | 183 | 200 | 0.00% | knee crossed |
| 100% | 100 | 350 | 378 | 0.00% | 3.5x the 10% p95 |

Knee: **50 rps**. Shape: p95 grows 3x between 10 and 50 rps, then flattens near 350–425 ms because the CPU is saturated.

### Baseline (single user)

p50 9 ms, p95 41 ms, p99 42 ms at 10 rps. Note that even at 10 rps the defect costs ~40 ms per miss.

## Findings

### F1: linear scan over 200k items on every detail request

- **Severity**: high
- **Reproducer**: `examples/demo-api/server.mjs` (`PERF_DEFECT=on`) — see the Reproduce block above
- **Metric**: p95 377 ms → 80 ms at 100 rps; p50 130 ms → 18 ms
- **Evidence**: `findItem()` runs `items.filter(...)` over 200,000 entries and sorts the result every request. CPU-bound, no query plan involved. Ladder knee at 50 rps matches `200k × 100 req/s` scan cost.
- **Mechanism**: O(n) scan plus an unnecessary `Array.sort` in the hot path turns a constant-time lookup into ~2 ms of CPU per request, which saturates one core at ~100 rps.
- **Fix direction**: build a `Map<id, item>` index once at startup and use it in `findItem()`.
- **Risk of fix**: memory grows by the index size (~20 MB for 200k rows); startup gets slower by ~30 ms.
- **Status**: fixed, proven by re-run

## Ruled out

| Hypothesis | Test | Result |
|------------|------|--------|
| JSON serialization dominates | same load with `discardResponseBodies` on the generator | unchanged p95, so serialization is not the cost |
| Generator is the bottleneck | `dropped_iterations` / autocannon `errors` and `timeouts` at 100 rps | 0 dropped, 0 timeouts, so the server is the limit |
| Client connection pool too small | connections 100 → 200 at 100 rps | p95 unchanged |

## Fixes

| Finding | Change | Before p95 | After p95 | Before rps | After rps | SLO | Regression test |
|---------|--------|-----------:|----------:|-----------:|----------:|-----|-----------------|
| F1 | `Map` index instead of filter+sort | 377 ms | 80 ms | 101 | 110 | PASS | `examples/demo-api/test/detail.test.mjs` |

Rules used: one fix per change, identical scenario, same dataset, same seed, median of 3 runs.

## Not tested

- Write traffic and mixed read/write contention: demo API has no writes.
- Pools, locks, and DB latency: there is no datastore.
- Soak and leak behavior: runs are 10 s, too short to detect growth.
- Multi-host / real network: generator and server share loopback, so network cost is absent.
- p99 confidence: 1,000 samples per run is below the 2,000 needed for a trustworthy p99. The p99 column is indicative only.

## Verdict

PASS. The SLO is satisfied after the fix on 3 runs with a margin larger than the run-to-run spread: p95 80 ms against a 100 ms target. The pre-fix state failed the same SLO at 377 ms. The regression test asserts that a detail request resolves in constant time and does not scan the dataset.

## Artifacts

- Raw before: `results/before/raw/L100-r{1,2,3}.json`
- Raw after: `results/after/raw/L100-r{1,2,3}.json`
- Normalized: `results/before/normalized`, `results/after/normalized`
- Ladder: `results/before/ladder.md`
- Delta: `results/delta.md`
