# In-process load

Some defects never show up at the HTTP layer: pool exhaustion, lock convoy, cache stampede, goroutine leak, event loop blocking. Test the layer directly, in the same process, with real concurrency.

## When it is valid

| Use in-process when | Use HTTP load when |
|---------------------|--------------------|
| Testing one query or repository method | Testing endpoint latency |
| Testing pool limits and queueing | Testing middleware, serialization, compression |
| Testing cache stampede and stampede protection | Testing connection reuse and TLS |
| Testing a consumer or worker loop | Testing the full journey |
| Testing for leaks under churn | Testing rate limits and gateways |

Never present an in-process loop as proof of HTTP throughput. State the layer in the report.

## Node / TypeScript

```ts
import { describe, it, expect } from 'vitest'

const N = 200
const CONCURRENCY = 50

describe('perf: repository under concurrency', () => {
  it('keeps p95 under 50ms with 50 concurrent callers', async () => {
    const latencies: number[] = []
    const errors: unknown[] = []
    let cursor = 0

    async function worker() {
      while (cursor < N) {
        const id = ++cursor
        const started = performance.now()
        try {
          await repo.findWithItems(id)
        } catch (e) {
          errors.push(e)
        } finally {
          latencies.push(performance.now() - started)
        }
      }
    }

    await Promise.all(Array.from({ length: CONCURRENCY }, worker))

    latencies.sort((a, b) => a - b)
    const p95 = latencies[Math.floor(latencies.length * 0.95)]
    expect(errors).toHaveLength(0)
    expect(p95).toBeLessThan(50)
  })
})
```

Rules:

- Use `Promise.all` for genuine parallelism, not `for await` over an array of independent calls (that is a serial loop and hides the defect).
- `Promise.all` over 500 calls is also a trap: it is not 500 concurrent users, it is one tick with 500 pending promises. Batch with a worker pool as above.
- Watch the event loop: `perf_hooks.monitorEventLoopDelay()` during the test. Lag above 50 ms means a sync call is blocking; that is a finding even if latency passes.
- Measure RSS before and after; a 100 MB growth over 10k iterations is a leak.
- For `worker_threads` or `piscina`, test with the real pool size, not an unbounded `cpus()`.

## Python

```python
import asyncio, time, statistics
import pytest

pytestmark = pytest.mark.perf

@pytest.mark.asyncio
async def test_repository_concurrency(repo):
    sem = asyncio.Semaphore(50)
    latencies = []
    errors = []

    async def one(i):
        async with sem:
            t0 = time.perf_counter()
            try:
                await repo.find_with_items(i)
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)
            finally:
                latencies.append(time.perf_counter() - t0)

    await asyncio.gather(*(one(i) for i in range(200)))

    latencies.sort()
    p95 = latencies[int(len(latencies) * 0.95)]
    assert not errors
    assert p95 < 0.05
```

Rules:

- `asyncio.gather` with no semaphore creates unbounded concurrency and exhausts the pool; you will find the pool bug but you cannot attribute latency. Use a semaphore matching the pool size to test the pool, and a higher one to test the limit.
- For sync libraries (Django ORM, `requests`, `boto3`), use `ThreadPoolExecutor` in the test, and check that the app does not call them from the event loop.
- Detect blocking calls in async code with `asyncio` debug mode: `PYTHONASYNCIODEBUG=1` plus slow-callback warnings in the log.
- GIL: CPU-bound Python does not scale with threads. A test that shows 4 threads giving 1x throughput is correct behavior, not a defect, unless the code claims parallelism.
- Check `psutil.Process().memory_info().rss` before and after; `tracemalloc` for the allocation site on growth.

## Go

```go
func TestLoadRepository(t *testing.T) {
	if testing.Short() {
		t.Skip("perf test")
	}
	const workers, perWorker = 50, 20
	var wg sync.WaitGroup
	lat := make([]time.Duration, 0, workers*perWorker)
	mu := sync.Mutex{}

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < perWorker; i++ {
				start := time.Now()
				if err := repo.FindWithItems(context.Background(), w*perWorker+i); err != nil {
					t.Errorf("query: %v", err)
				}
				mu.Lock()
				lat = append(lat, time.Since(start))
				mu.Unlock()
			}
		}(w)
	}
	wg.Wait()

	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	p95 := lat[int(float64(len(lat))*0.95)]
	if p95 > 50*time.Millisecond {
		t.Fatalf("p95 %v exceeds 50ms (n=%d)", p95, len(lat))
	}
}
```

Rules:

- `go test -race` once with reduced concurrency. Races are the worst highload defect and are invisible without the flag.
- Goroutine leak check: `runtime.NumGoroutine()` before and after, and `goleak` in TestMain.
- `b.RunParallel` for benchmarks; `b.ReportAllocs()` to catch allocation regressions.
- `-timeout` must exceed the test duration; the default 10 m kills soak runs silently.

## JVM

- JMH for microbenchmarks, with `@Fork` and `@Warmup`; never `System.nanoTime` in a loop.
- For pool and lock tests, `ExecutorService` with a bounded pool and a `CountDownLatch`, asserting p95 via HdrHistogram.
- Virtual threads: same test, compare platform vs virtual; if virtual threads do not help, a `synchronized` block is pinning them.
- Enable GC logging under load: `-Xlog:gc*:file=gc.log`. A 2 s pause is your p99.

## Layer tests worth writing

| Test | Asserts | Typical defect found |
|------|---------|----------------------|
| Pool saturation | Queue wait bounded, no timeout errors | Pool too small, connections leaked |
| Cache stampede | One recompute per key under 50 concurrent misses | No single-flight, thundering herd |
| Idempotency under retry | One row created for N retries | Missing unique constraint |
| Lock contention | p95 stable as concurrency grows | Long transaction, lock convoy |
| Queue drain | Backlog returns to zero after load stops | Missing backpressure, prefetch too high |
| Memory churn | RSS flat over 10k iterations | Leak per request, unbounded cache |
| Reconnect storm | Backoff with jitter, no thundering herd | Fixed sleep, synchronized retry |

## Assertions

Assert a bound, not a vibe: `p95 < X`, `errors == 0`, `rss_growth < 5%`, `backlog == 0`. A test without a threshold is a benchmark and belongs in a different file. Every in-process test must be deterministic enough to run in CI; if the machine is noisy, assert on the ratio to a baseline measured in the same run, not an absolute number.
