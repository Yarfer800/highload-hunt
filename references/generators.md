# Load generators

Pick by protocol and by the question. Never by what happens to be installed.

| Tool | Protocol | Model | Strength | Weakness |
|------|----------|-------|----------|----------|
| k6 | HTTP, WS, gRPC | Open + closed | Scriptable, thresholds, good summaries | JS runtime overhead at very high rps |
| locust | HTTP, custom | Closed (open via `--processes` + custom) | Python, realistic journeys | Heavy per-user cost |
| autocannon | HTTP/1.1 | Closed, pipelined | Fast local single-endpoint check | No scenarios, no assertions |
| wrk / wrk2 | HTTP | Closed / rate-corrected | Cheap, honest latency | No scripting, wrk2 needs patching |
| vegeta | HTTP | Open (constant rate) | Simple rate model, easy reports | Single request template |
| artillery | HTTP, WS, Playwright | Both | YAML scenarios, browser journeys | Memory heavy at scale |
| ghz | gRPC | Both | Real gRPC load, proto-aware | gRPC only |

Default for a new project: **k6** for HTTP throughput SLOs, **locust** when the scenario needs Python state or a real user journey, **autocannon** for a 30-second sanity check before writing anything.

## k6

`templates/k6-load.js` is the starting point. Key decisions:

- `executor: 'constant-arrival-rate'` for open model. Set `rate` and `preAllocatedVUs` high enough that `dropped_iterations` stays 0. If dropped iterations > 0, the generator is the bottleneck.
- Thresholds are the SLO. Make CI fail on them, do not read them by eye:

```js
thresholds: {
  http_req_failed: ['rate<0.005'],
  http_req_duration: ['p(95)<200', 'p(99)<500'],
}
```

- Export a machine-readable summary and keep it:

```bash
k6 run --summary-export=results/k6-100pct.json templates/k6-load.js
bash scripts/slo-gate.sh --file results/k6-100pct.json --p95 200 --p99 500 --err 0.5 --rps 300
```

- Tag scenarios so the report can separate warmup from steady state: `tags: { phase: 'steady' }`, then filter in the summary.
- Check the summary for `dropped_iterations` and `http_req_blocked` before believing latency numbers.

## locust

`templates/locustfile.py`. Use when the scenario is a journey: login, browse, add to cart, checkout.

```bash
locust -f tests/perf/locustfile.py --headless -u 300 -r 30 -t 4m \
  --host http://localhost:8080 --csv results/locust-100pct --only-summary
```

- `wait_time = between(1, 3)` gives realistic think time. Without it you measure a tight loop.
- Weights on tasks encode the real mix.
- Assert on `fail_ratio` in a `@events.quitting` hook so the exit code fails CI.
- `-u` is concurrent users, a closed model. For an open model, use `constant_pacing` or a custom `LoadTestShape`.

## autocannon

```bash
npx autocannon -c 100 -d 30 -R 300 -j http://localhost:8080/api/items > results/autocannon.json
```

`-R` fixes the rate. Without it autocannon floods as fast as it can, which is a breakpoint test, not an SLO test. Use it for the 30-second smoke check, not for the report.

## vegeta

```bash
echo "GET http://localhost:8080/api/items" | vegeta attack -rate=300 -duration=180s > results/vegeta.bin
vegeta report -type=json results/vegeta.bin > results/vegeta.json
```

Open model by default. Good for constant-rate soak. Add `-max-workers` high enough or you throttle yourself.

## wrk / wrk2

```bash
wrk -t4 -c100 -d30s --latency http://localhost:8080/api/items
wrk2 -t4 -c100 -R300 -d180s --latency http://localhost:8080/api/items
```

`wrk2` corrects coordinated omission; plain `wrk` does not. Use wrk2 when you need honest tail latency with few samples.

## WebSocket and streaming

- k6: `ws` API, track message round-trip, assert on connect failures and message latency separately.
- Test reconnect storms explicitly: kill the server mid-run and verify backoff with jitter; synchronized reconnects are a classic production outage.
- Streaming: measure time-to-first-byte and time-to-last-byte separately. A fast TTFB with a slow stream is a different defect.

## gRPC

```bash
ghz --insecure --proto api.proto --call api.Items.Get \
  -d '{"id":"1"}' -c 100 -z 180s --format json --output results/ghz.json \
  localhost:50051
```

Check status code distribution, not only latency.

## Queue and worker load

HTTP generators are useless for workers. Generate directly:

- Publish N messages at a controlled rate with a small script against the real broker.
- Measure: enqueue-to-dequeue lag, processing time, dead letters, consumer concurrency, and whether the queue drains after the load stops.
- A queue that never drains is the finding, even if latency per message looks fine.

## Generator hygiene

1. Assert the generator is not the bottleneck: generator CPU < 70%, `dropped_iterations == 0`, no local ephemeral port exhaustion (`ss -s` TIME_WAIT growth).
2. Use keepalive and a client pool sized above target concurrency.
3. Seed random data deterministically; record the seed in the report.
4. Do not run the generator on the same cores as the service unless you state it.
5. Save raw result files. Screenshots of a terminal are not data.
