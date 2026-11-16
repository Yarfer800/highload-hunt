# Stack detection

`scripts/perf-doctor.sh` automates this. Use the tables below when the script output is ambiguous or the repo is a monorepo.

## Detection table

| Signal file | Stack | Test runner | Perf test home | Profiler |
|-------------|-------|-------------|----------------|----------|
| `package.json` + `next.config.*` | Next.js | vitest / jest / playwright | `tests/perf`, `playwright` project `perf` | `NEXT_RUNTIME`, clinic, `--cpu-prof` |
| `package.json` + `@nestjs/core` | NestJS | jest / vitest | `test/perf/*.e2e-spec.ts` | `node --cpu-prof`, 0x |
| `package.json` + `express`/`fastify` | Node HTTP | vitest / jest / node:test | `tests/perf` | `node --cpu-prof`, autocannon |
| `pyproject.toml` + `fastapi`/`django`/`flask` | Python ASGI/WSGI | pytest | `tests/perf` | py-spy, scalene, memray |
| `go.mod` | Go | `go test` | `*_perf_test.go`, benchmarks | pprof, `-trace` |
| `pom.xml` / `build.gradle*` | JVM | JUnit / JMH | `src/test/java/.../perf` | async-profiler, JFR |
| `Cargo.toml` | Rust | `cargo test` | `benches/`, `tests/perf` | `perf`, `cargo flamegraph` |
| `composer.json` | PHP | phpunit | `tests/Perf` | blackfire, xhprof |
| `*.csproj` | .NET | xunit / nunit | `tests/Perf` | dotnet-trace, dotnet-counters |

## Entry point rules

1. **Prefer the real server** over an in-process handler when the question is HTTP latency or throughput. Middleware, serialization, compression, and connection handling all matter.
2. **Prefer in-process** when the question is a specific layer: one query, one pool, one cache, one queue consumer.
3. Find the start command, not a guess:
   - `package.json` scripts: `dev`, `start`, `serve`, `preview`.
   - `Makefile`, `Procfile`, `docker-compose.yml`, `compose.yaml`.
   - `pyproject.toml` scripts, `uvicorn`/`gunicorn` entry, `manage.py runserver` (never for load).
   - Go: `cmd/*/main.go`, `go run ./cmd/api`.
   - JVM: `mvn spring-boot:run`, `./gradlew bootRun`, or the built jar.
4. Use the **production build** for verdict runs: `next build && next start`, `vite build && vite preview`, `gunicorn -w N`, `go build` binary. Dev servers add reload, source maps, and verbose logging.
5. In a monorepo, pick the package that owns the endpoint under test and record its path. Do not load the gateway and call it the service.

## Environment and datastore

- Detect Postgres/MySQL/Redis/Kafka from `docker-compose.yml`, `.env.example`, ORM config, or connection strings. Do not assume SQLite in a load test unless the service really uses it.
- Seed data must be reproducible: a seed script under `tests/perf/seed.*` with a fixed random seed, or a SQL dump with a checksum.
- Reset between runs with a documented command (truncate, migrate, seed). Latency from a growing table across runs is not comparable.
- If the datastore is remote or shared, say so; network and noisy neighbors change the verdict.

## Test runner integration

The perf test must be runnable with one command and must exit non-zero on SLO violation.

| Stack | Command |
|-------|---------|
| Node (vitest) | `npx vitest run tests/perf --testTimeout=600000` |
| Node (jest) | `npx jest --config tests/perf/jest.config.js --runInBand` |
| Python | `pytest tests/perf -m perf -q --timeout=900` |
| Go | `go test ./tests/perf -run TestLoad -v -timeout 15m` |
| JVM | `./gradlew perfTest` or `mvn -Pperf verify` |

Tag perf tests so normal CI stays fast: `@pytest.mark.perf`, `describe.skipIf(!process.env.PERF)`, Go build tag `//go:build perf`, JUnit `@Tag("perf")`.

## Observability inventory

Record what exists before the hunt; missing observability is itself a finding.

- Metrics endpoint (`/metrics`, `/health`, OpenTelemetry exporter).
- Structured logs with request id and duration.
- DB: `pg_stat_statements` enabled, slow query threshold, `log_min_duration_statement`.
- Container: cgroup v2 `memory.pressure`, `cpu.stat` throttling.
- Tracing: OTel collector, Jaeger, Tempo.

If nothing exists, measure from the outside and say the diagnosis is coarse. Do not install a full observability stack as a side quest unless the user asks.
