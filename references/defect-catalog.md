# Defect catalog

Symptom to mechanism to fix. A finding needs all four fields from `SKILL.md` Phase 5; this file supplies the mechanism and fix direction.

## Request path and data access

| # | Symptom | Evidence | Mechanism | Fix direction |
|---|---------|----------|-----------|---------------|
| 1 | p95 grows with page size, rps flat | Query count scales with rows (`pg_stat_statements` calls per request) | N+1 queries in serialization or loop | Batch fetch, join, dataloader, `IN (...)` prefetch |
| 2 | One endpoint slow only for large tenants | `EXPLAIN` shows `Seq Scan`, high `shared read` | Missing index on the filter column | Composite index matching filter + sort, verify with `EXPLAIN (ANALYZE, BUFFERS)` |
| 3 | Slow at high offset pages | `LIMIT/OFFSET` scans N rows | Deep OFFSET pagination | Keyset pagination on indexed cursor |
| 4 | Latency climbs with dataset size, not rate | buffers read per call grows | Query reads the whole table then filters in app code | Push filtering to SQL, add index, or precompute |
| 5 | Slow lists | Response compression absent, large JSON | Oversized payloads, no pagination | Paginate, field selection, gzip/brotli, avoid serializing unused relations |
| 6 | Random slow requests, microsecond-to-second spikes | `pg_stat_activity` shows lock waits | Row or table lock contention from long transactions | Shorten transactions, move I/O out of the tx, retry with jitter, `SKIP LOCKED` for queues |
| 7 | Latency degrades over minutes | `pg_stat_activity` idle-in-transaction grows | Connections leaked or transactions never closed | Fix ownership, add pool metrics, `idle_in_transaction_session_timeout` |
| 8 | Throughput capped at a round number | Pool queue depth > 0, wait time dominates | Connection pool too small, or held during slow calls | Size pool to `cores x 2-4` for IO, measure wait, never hold a connection across external calls |
| 9 | Errors under spikes: "pool timeout" | Pool exhausted at reconnect | Pool has no queue bound, no timeout, no health check | Bounded queue, acquire timeout, statement timeout, backpressure |
| 10 | High CPU on the DB, low app CPU | `pg_stat_statements` top by total time | Repeated identical expensive query (no cache, no prepared statement) | Cache with TTL and single-flight, prepared statements |
| 11 | First request after idle is slow | Connection re-establishment in logs | No keepalive, DNS per request, TLS handshake per request | Persistent connections, pooling, connection reuse |
| 12 | Latency spikes at exact intervals | GC log correlation | GC pressure from per-request allocations | Reduce allocations, reuse buffers, tune heap, stream instead of buffer |

## Concurrency and runtime

| # | Symptom | Evidence | Mechanism | Fix direction |
|---|---------|----------|-----------|---------------|
| 13 | Latency floor high even at low load | Event loop lag monitor, flame graph | Sync CPU or blocking I/O inside an async handler | Move to thread pool or worker, use async client |
| 14 | p99 spikes with no DB evidence | Flame graph shows lock wait in app code | Global lock or mutex around hot path | Shard the lock, use lock-free structure, per-key locks |
| 15 | Throughput drops as concurrency rises | Thread dump shows many threads on one lock | Lock convoy, undersized critical section granularity | Reduce critical section, batch, shard |
| 16 | Memory grows under load, flat after restart | Heap profile, RSS slope | Per-request allocation retained (cache without eviction, listener leak) | Bound caches, fix subscriptions, add eviction |
| 17 | File descriptors climb | `lsof`, `ss` count | Sockets or file handles not closed on error paths | `finally` close, `defer`, connection middleware |
| 18 | CPU 100% at moderate load with tiny payloads | CPU profile | Busy-wait, polling loop, retry without backoff | Event-driven wait, exponential backoff with jitter |
| 19 | Errors only at spawn/restart | Logs: connection refused, DNS failures | No graceful shutdown, in-flight requests killed, retry storm | Drain on SIGTERM, readiness gate, jittered retries, circuit breaker |
| 20 | Slow after deploy, warm after 10 min | Cold-start metrics | Cold caches, JIT warmup, lazy init | Readiness warmup, precomputed caches, preload |

## Caching and fan-out

| # | Symptom | Evidence | Mechanism | Fix direction |
|---|---------|----------|-----------|---------------|
| 21 | Every key expiry causes a latency spike | Correlated p99 across all keys | Cache stampede, no single-flight | Lock or probabilistic early refresh, stale-while-revalidate |
| 22 | Load test fast, prod slow | Test hits the same key | Hot key measured as cache hit; real traffic fans out | Randomize keys in the test, measure hit ratio |
| 23 | Reconnect storms after a dependency blip | Connection count spike, CPU spike | Synchronized retries, no jitter | Backoff with jitter, reconnect budget, circuit breaker |
| 24 | Queue never drains after the load stops | Backlog metric flat or rising | Missing backpressure, prefetch too high, poison messages | Bounded prefetch, DLQ, scale consumers, rate-limit producers |
| 25 | Duplicate rows after retries | Count check | Non-idempotent write with retry | Idempotency key, unique constraint, upsert |
| 26 | One shard hotter than others | Per-shard metrics | Poor partition key (low cardinality, time-ordered) | Reshard key, add salt, composite key |

## Serialization, network, gateway

| # | Symptom | Evidence | Mechanism | Fix direction |
|---|---------|----------|-----------|---------------|
| 27 | Large responses slow end-to-end, server fast | TTFB fast, total time slow | No compression, no streaming | gzip/brotli, chunked streaming, `sendfile` for files |
| 28 | Many small calls per request | Trace span count per request | Chatty internal API, serial `await` in a loop | Batch endpoint, parallel calls, request coalescing |
| 29 | Latency doubles through the proxy but not direct | Compare direct vs proxy run | Proxy hop, extra TLS, undersized proxy buffers | Keepalive to upstream, HTTP/2, tune worker connections |
| 30 | High rps but throughput low | Status mix includes 429/503 | Rate limiter or gateway shedding load | Confirm intended limit, fix the limiter key, or raise capacity |
| 31 | Regex CPU spikes on specific inputs | Flame graph in regex engine | Catastrophic backtracking | Bounded pattern, input length cap, non-regex parser |
| 32 | Slow JSON for big arrays | Profile shows serialization | Building full object graph then serializing | Stream, field selection, cursor paging |

## Detection table for profiling evidence

| Need | Command |
|------|---------|
| Where is CPU going (Node) | `node --cpu-prof app.js`, then `0x` or Chrome DevTools |
| Where is CPU going (Python) | `py-spy record -o profile.svg --pid <pid>` |
| Where is CPU going (Go) | `go tool pprof http://localhost:6060/debug/pprof/profile?seconds=30` |
| Where is CPU going (JVM) | `asprof -d 30 -f out.html <pid>` |
| Where is memory going | heap snapshot, `memray`, `pprof heap`, `jcmd GC.heap_dump` |
| Which query is slow | `pg_stat_statements`, `EXPLAIN (ANALYZE, BUFFERS)` |
| Which lock is held | `pg_locks` joined with `pg_stat_activity` |
| Is GC the cause | GC log, `-Xlog:gc*`, `--trace-gc` |
| Is the container throttled | cgroup `cpu.stat` `nr_throttled`, `memory.pressure` |

## Fix discipline

1. One mechanism per change. Two fixes in one commit cannot be attributed.
2. Prefer the fix that removes the mechanism, not the one that hides the symptom (raising timeouts, adding replicas, caching blindly).
3. After the fix, re-check the second-order effect: caching moves load to the DB on miss; batching increases memory; a bigger pool can overload the DB.
4. If the fix moves the knee instead of raising it, report both numbers.
