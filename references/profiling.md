# Profiling under load

Profile while the load runs, not after. A profile of an idle process explains nothing.

## Order of evidence

1. Resource counters: is it CPU, memory, IO, network, or a lock?
2. Application profile: where inside the process.
3. Datastore: which query, which plan, which lock.
4. Trace: which hop in the call graph.

Do not jump to the code before step 1 tells you which resource is saturated.

## System counters

```bash
# Per-process CPU, memory, threads
pidstat -p <pid> 1 30

# Blocked vs running, context switches
vmstat 1 30
pidstat -w -p <pid> 1 30

# Socket states, TIME_WAIT growth
ss -s
ss -tan state time-wait | wc -l

# Disk
iostat -xz 1 10

# Container limits and throttling (cgroup v2)
cat /sys/fs/cgroup/cpu.stat
cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.max
cat /sys/fs/cgroup/memory.pressure
```

`nr_throttled` climbing with `throttled_usec` growing means the container, not the code, is the bottleneck. Report it; a fix in code will not move the number.

## Node.js

```bash
# CPU profile for the whole process
node --cpu-prof --cpu-prof-dir=./prof app.js

# Flame graph
npx 0x -o flame.html -- node app.js

# Event loop lag during load (in-process)
node -e "const {monitorEventLoopDelay}=require('perf_hooks');const h=monitorEventLoopDelay({resolution:10});h.enable();setInterval(()=>console.log('p99 lag ms',h.percentile(99)/1e6),5000)"
```

- `--inspect` + Chrome DevTools for a live heap snapshot under load.
- `clinic doctor` and `clinic flame` for a guided run; `clinic bubbleprof` for async latency.
- Check `process.memoryUsage().rss` trend and `v8.getHeapStatistics()`; heap growth with flat GC frequency means retention.
- Async hooks / `async_hooks` count: millions of active resources means leaked promises or listeners.

## Python

```bash
# Sampling profiler, works on production processes
py-spy record -o profile.svg --pid <pid> --duration 30
py-spy dump --pid <pid>              # live stack, no restart

# Allocation profiling
memray run -o out.bin app.py
memray flamegraph out.bin

# Line-level CPU, includes native frames
scalene app.py
```

- `PYTHONASYNCIODEBUG=1` and `loop.slow_callback_duration = 0.05` to catch blocking calls in async code.
- Gunicorn/uvicorn workers: profile one worker, and check `max_requests` recycling masks leaks.
- `tracemalloc` snapshots before/after a load phase if memray is unavailable.

## Go

```go
import _ "net/http/pprof"
go func() { _ = http.ListenAndServe("localhost:6060", nil) }()
```

```bash
go tool pprof -http=:8081 http://localhost:6060/debug/pprof/profile?seconds=30   # CPU
go tool pprof -http=:8081 http://localhost:6060/debug/pprof/heap                 # live heap
go tool pprof -http=:8081 http://localhost:6060/debug/pprof/block                # blocking
go tool pprof -http=:8081 http://localhost:6060/debug/pprof/mutex                # contention
curl -o trace.out "http://localhost:6060/debug/pprof/trace?seconds=10"
go tool trace trace.out
```

- `GODEBUG=gctrace=1` for pause times; `go test -bench . -benchmem` for allocations per op.
- `block` and `mutex` profiles only report if the sample rate is set: `runtime.SetBlockProfileRate(1)`.

## JVM

```bash
asprof -d 30 -e cpu -f cpu.html <pid>
asprof -d 30 -e alloc -f alloc.html <pid>
asprof -d 30 -e lock -f lock.html <pid>

jcmd <pid> GC.heap_info
jcmd <pid> Thread.print > threads.txt   # 3 snapshots, 5s apart
jcmd <pid> JFR.start duration=60s filename=rec.jfr
```

- Thread dumps repeated during the spike identify the lock holder, not just the waiters.
- Virtual threads: `-Djdk.tracePinnedThreads=full` to catch pinning on `synchronized`.

## Databases

### PostgreSQL

```sql
-- Enable once
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Top by total time
SELECT calls, round(total_exec_time) AS total_ms, round(mean_exec_time, 2) AS mean_ms,
       rows, query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;

-- What is running and waiting now
SELECT pid, state, wait_event_type, wait_event, now() - query_start AS dur, query
FROM pg_stat_activity
WHERE state <> 'idle' ORDER BY dur DESC;

-- Blocks
SELECT blocked.pid AS blocked, blocking.pid AS blocking, blocked.query
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid = blocked.pid AND NOT bl.granted
JOIN pg_locks kl ON kl.locktype = bl.locktype AND kl.database IS NOT DISTINCT FROM bl.database
  AND kl.relation IS NOT DISTINCT FROM bl.relation AND kl.page IS NOT DISTINCT FROM bl.page
  AND kl.tuple IS NOT DISTINCT FROM bl.tuple AND kl.granted
JOIN pg_stat_activity blocking ON blocking.pid = kl.pid;

EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) <query>;
```

- Compare `actual rows` to `rows` estimate; a 100x misestimate means stale statistics or a bad plan.
- `shared read` blocks on a hot query means the index does not cover it.
- Reset stats before a measured run: `SELECT pg_stat_statements_reset();`

### MySQL

```sql
SELECT * FROM sys.statement_analysis ORDER BY total_latency DESC LIMIT 20;
SELECT * FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC LIMIT 20;
SHOW ENGINE INNODB STATUS;
```

### Redis

```bash
redis-cli --latency-history -i 5
redis-cli info stats | grep -E 'keyspace|evicted|expired'
redis-cli slowlog get 20
```

`evicted_keys` climbing means memory pressure is the defect, not the cache code.

## Tracing

- OpenTelemetry spans per request: find the slowest hop, not the slowest service.
- Compare span count per request to detect chatty calls (finding #28 in the catalog).
- Sample high under load: 100% for a 60-second diagnostic run, then back to 1-5%.

## Profile hygiene

- Record the rate and duration next to the profile; a profile without load context is unreadable.
- One variable at a time. Do not profile while changing the code.
- Keep the profile artifact path in the report.
- If the profile is flat (no hotspot), the bottleneck is outside the process: locks, IO, network, or the datastore.
