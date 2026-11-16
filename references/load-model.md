# Load model and SLO

A load test is a measurement instrument. Define the signal before you point it at the service.

## Open vs closed model

| Model | What it simulates | Tool form | Use when |
|-------|-------------------|-----------|----------|
| Open (arrival rate) | Independent traffic, queueing allowed | `constant-arrival-rate`, `vegeta -rate`, `wrk2 -R` | Public API, SLO work, most production traffic |
| Closed (user count) | Fixed users, each waits for a response | `vus` with think time, locust `-u` | Session flows, browser journeys, capacity of a fixed client pool |

Closed models hide saturation: when the server slows, clients slow too, so offered load drops and the system looks stable. Always run at least one open-model ramp.

Little's law: `concurrency = rps x latency`. 300 rps at 200 ms needs 60 concurrent requests. If the tool reports a much lower achieved rate at the target concurrency, you are queueing, not serving.

## Picking the target rate

1. Ask for production peak rps and concurrency. Scale to the test environment by a documented factor, never silently.
2. No production data? Use the last known safe rate x 1.5 as the target and say it is an assumption.
3. Never set the target equal to a single benchmark you just observed; that is a tautology.

## Required realism

- **Dataset**: production-like volume and cardinality. 10k rows will not expose a missing index that 10M rows will. If you must shrink, keep filter selectivity and document the factor.
- **Data spread**: vary ids, filters, and users. Hammering one row measures a cache hit, not a query.
- **Mix**: match the real read/write ratio. All-read tests hide write contention and lock waits.
- **Payloads**: real sizes. A 20-byte JSON response hides serialization cost.
- **Warmup**: JIT, caches, pools, and connection setup distort the first 30-60 s. Exclude warmup from percentiles.
- **Steady state**: 180 s minimum for a verdict. Soak is 30+ min and answers a different question: leaks and degradation.

## SLO definition

Minimum viable SLO block:

```
latency   p95 <= X ms, p99 <= Y ms (server-side)
errors    <= Z% total, 5xx == 0
rate      >= N rps sustained for the steady window
resources CPU < 80%, RSS flat within 5%, pool < 80%
correct   payload shape and content assertions pass
```

Bad SLOs to reject:

- Average latency. One slow request disappears in the mean.
- "As fast as possible". Not falsifiable.
- Throughput without latency. A server returning 503 fast is not fast.
- Percentiles with no sample count.
- Latency without a rate. Latency at 1 rps is not a load result.

## Ladder

```
10%  x 60 s    -> wiring and data errors surface here
50%  x 120 s   -> first deviation, pool behavior
100% x 180 s   -> SLO run, 3 repeats
150% x 120 s   -> knee, failure mode
+25% steps     -> breakpoint until errors > 5% or p95 doubles
```

Knee = the rate where p95 grows superlinearly. Record the knee rate, not just the pass/fail. A service that passes at 300 rps with a knee at 310 rps is fragile even though it passed.

## Statistics that survive review

- Sample count: p95 needs >= 200 samples, p99 needs >= 2000. With 300 rps for 180 s you have 54,000 requests; that is enough. State `samples` in the report.
- Percentiles are not averages; never average two runs' percentiles. Report per-run values and the median of runs.
- Report spread: min/median/max p95 across the 3 runs. A 40% spread means the environment is noisy; fix the environment before trusting 5% improvements.
- 3 runs at the target, not 3 runs of different scenarios.
- Avoid coordinated omission: with closed models, latency is measured from the client's send, so time spent waiting for a free client is lost. Use an open model or a tool that corrects for it.
- Do not compare a single-run before to a single-run after. Use medians of 3 or accept that you measured noise.

## Environment controls

Before a verdict run:

- No other builds, test suites, or containers competing for CPU.
- Fixed CPU and memory limits for the service under test; record them.
- Disable hot reload, watch mode, source maps, and verbose logging, or document that they are on.
- Same host, same dataset, same seeds for every comparison run.
- Generator and server on separate cores. If co-located, confirm the generator is not the bottleneck (`top` on the generator process).

## Common measurement traps

| Trap | Effect | Guard |
|------|--------|-------|
| Generator saturated | Numbers describe the client | Check generator CPU, scale generators |
| Cold cache vs warm cache mixed | Non-comparable runs | Explicit warmup, fix cache policy per run |
| Connection pool of the client too small | Fake latency | Generator keepalive and pool sized above target concurrency |
| Same id every request | Cache hit, no query | Randomize from a seeded dataset |
| Dev server with tracing on | 2-10x slower | Measure the production build |
| Localhost only | Missing network cost | Note it, and test through the real proxy at least once |
| Rate limiter on | Silent 429s counted as success by some tools | Assert on 5xx and status distribution |
