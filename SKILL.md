---
name: highload-hunt
description: Run a disciplined high-load hunt — write explicit load and E2E tests inside the repo, find the breaking point, prove every performance defect with metrics (p95/p99, RPS, error rate, saturation), and fix it only after the report is approved. Use when asked to load-test, stress-test, benchmark, simulate highload, find bottlenecks, or explain why a service slows down, hangs, or times out under traffic.
metadata:
  origin: community
---

# Highload Hunt

Turn "it feels slow under load" into measured defects, reproducible tests, and proven fixes.

This skill is a protocol, not advice. Follow the phases in order. Do not skip gates.

## Operating contract

- Default deliverable is a **report plus committed tests**. Not a code rewrite.
- Change production code only after the user approves the report (Gate G4).
- Every defect claim needs a reproducer and a number. No number, no finding.
- Every fix claim needs a before/after run of the **same** scenario, same seed, same dataset.
- Tests stay in the repo under `tests/perf/`. Throwaway scripts in `/tmp` do not count.
- If the service cannot be started or measured, say so and stop. Do not invent results.

## Hard gates

| Gate | Rule | Check before moving on |
|------|------|------------------------|
| G1 | No verdicts without baseline + load + repeat runs | Three result files exist |
| G2 | Load tests live in the repo | `git status` shows `tests/perf/**` |
| G3 | Every finding has a reproducer, metric, and mechanism | Finding row in report has all three |
| G4 | Report first, code second | User replied explicitly to the report |
| G5 | A fix is proven by an identical re-run | Same params, same seed, delta table filled |
| G6 | Forbidden shortcuts (see below) | None present in the test code |
| G7 | Exit is SLO met or accepted risk, never "looks fine" | Report has a verdict line with numbers |
| G8 | Regression test added for every fixed defect | Test fails on the old code or asserts the new bound |

Forbidden shortcuts (G6). If you catch yourself doing one, stop and redo the run:

- `sleep()` as a substitute for real arrival-rate control.
- Mocked database, mocked cache, or mocked network in a load test.
- Fewer than 200 samples for a p95 claim, fewer than 2000 for p99.
- Runs shorter than 60 s of steady state, or no warmup phase.
- One run presented as the truth. Report median and spread of at least 3 runs.
- Changing SLO thresholds mid-hunt so a run passes.
- Comparing runs with different datasets, seeds, or hardware.
- In-process synthetic loops presented as proof of HTTP throughput.
- Measuring only warm cache when the SLO is about cold behavior.
- Load testing a dev server with hot reload and debug logging without saying so.

## Tiers

Pick the smallest tier that answers the question. Gates still apply.

| Tier | Scope | Time box | Phases |
|------|-------|----------|--------|
| S | One endpoint, one handler, one query | 30-60 min | 0, 1, 2, 3 (two levels), 4-5, 6 |
| M | One service, realistic read/write mix | 2-4 h | All phases |
| L | Multi-service journey, release gate | 1-2 days | All phases, plus soak and spike |

## Phase 0 — Preflight

Detect the project before touching anything.

```bash
bash scripts/perf-doctor.sh .
```

Read [references/stack-detection.md](references/stack-detection.md) for the detection table and for monorepo entry-point rules.

Confirm and write down in the report header:

1. Stack and runtime versions.
2. Exact command that starts the service, and the port.
3. Datastore and how to reset or seed it.
4. Existing test runner and how to run one test.
5. Available load generators (k6, locust, autocannon, wrk, vegeta).
6. CI system, so the regression test can run there later.
7. Observability: logs, metrics endpoint, tracing, DB query stats.

If any of these is missing and blocks measurement, report the blocker instead of guessing.

## Phase 1 — Define SLO and load model

Write these down before generating load. See [references/load-model.md](references/load-model.md).

```markdown
### Load model
- Target rate: 300 req/s (or: 500 concurrent users, think time 1-2 s)
- Mix: 70% read / 25% write / 5% search
- Dataset: 1M rows, 50k users, 30 days of history
- Duration: 60 s warmup + 180 s steady + 60 s cooldown
- Model: open (arrival rate) / closed (user count)

### SLO
- Latency: p95 <= 200 ms, p99 <= 500 ms
- Errors: <= 0.5% of requests, HTTP 5xx must be 0
- Throughput: >= 300 req/s sustained, no drop over steady window
- Saturation: CPU < 80%, memory flat, DB pool < 80% utilized
- Correctness: response payload matches expected shape and counts
```

If the user has no SLO, derive one from current p95 at 10% load and state the assumption explicitly.

## Phase 2 — Baseline and functional correctness

1. Run the functional E2E test that exercises the same endpoint or journey. It must pass **before** load. A load test on a broken endpoint measures nothing.
2. Measure the single-user latency: 1 VU or 1 req/s for 60 s. This is the floor.
3. Record the numbers. Every later claim compares against this.

## Phase 3 — Load ladder

Ramp, do not jump to the target.

1. 10% of target, 60 s. Fix outright errors here before continuing.
2. 50%, 120 s. Watch for the first latency deviation.
3. 100%, 180 s steady. This is the SLO run, repeat 3 times.
4. 150%, 120 s. Find the knee and the failure mode: latency wall, pool exhaustion, OOM, timeouts, restart.
5. Optional breakpoint: keep stepping 25% until error rate exceeds 5% or latency doubles. Record the breaking point; it is often the most actionable number in the report.

Record `rps`, `p50`, `p95`, `p99`, `max`, `error_rate`, plus resource series. Build the curve; the knee is where p95 stops being flat.

Validate the generator itself first: if the generator saturates its own CPU, the numbers describe the laptop, not the service. Say which one you measured.

Use the generator chosen in [references/generators.md](references/generators.md). For internal layers (BFS, pool, queue, cache) use [references/in-process-load.md](references/in-process-load.md).

## Phase 4 — Observe

Do not diagnose from latency alone. Collect:

- Application: request timings, GC pauses, event loop lag, thread pool or pool queue depth.
- Database: `pg_stat_statements` or slow query log, `EXPLAIN (ANALYZE, BUFFERS)`, active connections, lock waits.
- System: CPU per core, RSS over time, open sockets, `ss -s`, disk iostat, cgroup throttle counters.
- Profiles: one CPU profile and, if memory grows, one heap profile under load.

Commands per runtime: [references/profiling.md](references/profiling.md).

## Phase 5 — Diagnose

Match symptoms to mechanisms using [references/defect-catalog.md](references/defect-catalog.md).

A finding is valid only with all four:

1. **Reproducer** — file path and exact command.
2. **Metric** — the number that moves, with run id.
3. **Mechanism** — the concrete code path, query plan, or lock that explains it.
4. **Fix direction** — one sentence, not an implementation.

Rank findings: `impact = latency or error budget consumed x frequency x blast radius`. A defect that only appears at 150% load is still a finding if 150% is reachable in production.

## Phase 6 — Report and user gate

Write `PERF-REPORT.md` from [references/report-template.md](references/report-template.md). Include:

- Environment and exact commands to reproduce.
- Metrics table per run, with spread.
- Defects ranked, each with reproducer, metric, mechanism, fix direction.
- What was not tested and why.
- Verdict: SLO met / SLO missed / blocked.

Then stop and ask. Do not edit production code in this phase. The default answer is "report only"; proceed to fixes only on explicit approval.

## Phase 7 — Fix and prove

One defect per change. For each approved fix:

1. Write the failing perf test first, tagged narrowly, asserting the old bad bound.
2. Apply the smallest fix.
3. Re-run the **identical** scenario: same generator file, same rate, same duration, same seed, same dataset.
4. Add the delta row: before, after, change, and the SLO status.
5. Keep the regression test. It must fail on the pre-fix code path, or assert a bound the old code violated.

If the fix does not move the number, revert it and say so. A clean revert is a valid result.

## Phase 8 — Lock it in

- Tests committed under `tests/perf/`, with a short README of how to run each.
- CI job: smoke load on PR (Tier S, 10% rate), full ladder on schedule or release.
- Flake policy: 3 consecutive runs, compare medians, tolerate 10% variance unless the SLO margin is under 10%, then tighten the test or the SLO.
- Artifacts: store result JSON next to the report, keep the last N runs.

## Metric contract

Use these names everywhere: report, test assertions, CI output.

| Metric | Meaning | Notes |
|--------|---------|-------|
| `rps` | Achieved requests per second | Must be checked against target, not assumed |
| `p50`, `p95`, `p99`, `max` | Server-side or client-side latency | State which side |
| `error_rate` | Failed / total requests | Split 4xx from 5xx; 4xx during load often means bad test data |
| `saturation` | CPU, memory, pool, queue depth | The leading indicator before latency breaks |
| `samples` | Count used for percentiles | p99 needs >= 2000 |
| `correct` | Functional assertions passed | Load with wrong answers is not success |

## Exit criteria

The hunt ends in exactly one state:

- **PASS**: SLO met on 3 runs, tests committed, report written.
- **FAIL**: defects listed with reproducers, report written, fixes awaiting approval.
- **BLOCKED**: measurement impossible; state the missing piece and what was ruled out.

Never end with "should be fine" or "likely faster now".

## Reference index

- [references/stack-detection.md](references/stack-detection.md) — detect stack, entry point, runner, profiler.
- [references/load-model.md](references/load-model.md) — SLO math, open vs closed model, ladder, statistics.
- [references/generators.md](references/generators.md) — k6, locust, autocannon, wrk, vegeta, gRPC and WS.
- [references/in-process-load.md](references/in-process-load.md) — concurrency tests for JS, Python, Go, JVM.
- [references/e2e-test-anatomy.md](references/e2e-test-anatomy.md) — how to write the explicit perf E2E test.
- [references/defect-catalog.md](references/defect-catalog.md) — symptom to mechanism to fix.
- [references/profiling.md](references/profiling.md) — profilers, DB stats, system counters.
- [references/report-template.md](references/report-template.md) — report skeleton.
