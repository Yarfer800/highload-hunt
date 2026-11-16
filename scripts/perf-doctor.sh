#!/usr/bin/env bash
# perf-doctor.sh — read-only preflight for a highload hunt.
#
# Usage: bash scripts/perf-doctor.sh [--json] [project-dir]
#
# Detects stack, entry point, test runner, datastore, generators, and CI so the
# hunt starts from facts instead of guesses. Changes nothing.
# --json prints a machine-readable report for agents and CI.

set -uo pipefail

JSON_MODE=0
if [ "${1:-}" = "--json" ]; then JSON_MODE=1; shift; fi

TARGET="${1:-.}"
cd "$TARGET" 2>/dev/null || { echo "perf-doctor: cannot cd to $TARGET" >&2; exit 2; }

CURRENT="general"
RECORDS=()

section() {
  CURRENT="$1"
  [ "$JSON_MODE" -eq 1 ] || printf '\n## %s\n' "$1"
}
have() { command -v "$1" >/dev/null 2>&1; }
file_has() { [ -f "$1" ] && grep -q -- "$2" "$1" 2>/dev/null; }
note() {
  local value="${2//$'\n'/ }"
  RECORDS+=("$CURRENT"$'\t'"$1"$'\t'"$value")
  [ "$JSON_MODE" -eq 1 ] || printf '  %-22s %s\n' "$1" "$2"
}

[ "$JSON_MODE" -eq 1 ] || printf '# perf-doctor report\n'
note "path" "$(pwd)"
note "date" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -d .git ]; then
  note "commit" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  note "branch" "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  note "dirty" "$(git status --porcelain 2>/dev/null | wc -l) changed files"
fi

section "Stack"
if [ -f package.json ]; then
  note "language" "Node/TypeScript (package.json)"
  if [ -f package-lock.json ]; then note "package manager" "npm"; fi
  if [ -f pnpm-lock.yaml ]; then note "package manager" "pnpm"; fi
  if [ -f yarn.lock ]; then note "package manager" "yarn"; fi
  if [ -f bun.lockb ] || [ -f bun.lock ]; then note "package manager" "bun"; fi
  for dep in next @nestjs/core express fastify koa hono @hapi/hapi; do
    if file_has package.json "\"$dep\""; then note "framework" "$dep"; fi
  done
  for dep in vitest jest @playwright/test node:test mocha; do
    if file_has package.json "\"$dep\""; then note "test runner" "$dep"; fi
  done
  if file_has package.json '"type": "module"'; then note "module type" "esm"; fi
fi
if [ -f pyproject.toml ] || [ -f setup.py ] || [ -f requirements.txt ]; then
  note "language" "Python"
  for dep in fastapi django flask starlette litestar; do
    if file_has pyproject.toml "$dep" || file_has requirements.txt "$dep"; then note "framework" "$dep"; fi
  done
  if have uv; then note "package manager" "uv"; fi
  if [ -f poetry.lock ]; then note "package manager" "poetry"; fi
  if have pytest || file_has pyproject.toml "pytest"; then note "test runner" "pytest"; fi
fi
if [ -f go.mod ]; then
  note "language" "Go ($(head -1 go.mod 2>/dev/null))"
  note "test runner" "go test"
fi
if [ -f pom.xml ]; then note "language" "JVM (maven)"; fi
if [ -f build.gradle ] || [ -f build.gradle.kts ]; then note "language" "JVM (gradle)"; fi
if [ -f Cargo.toml ]; then note "language" "Rust"; fi
if [ -f composer.json ]; then note "language" "PHP"; fi
if ls ./*.csproj >/dev/null 2>&1; then note "language" ".NET"; fi

section "Run commands"
if [ -f package.json ]; then
  if have node; then note "node" "$(node --version 2>/dev/null)"; fi
  while IFS=$'\t' read -r script_name script_cmd; do
    [ -n "$script_name" ] && note "script:$script_name" "$script_cmd"
  done < <(python3 - <<'PY' 2>/dev/null
import json
try:
    pkg = json.load(open('package.json'))
except Exception:
    raise SystemExit
scripts = pkg.get('scripts', {})
for name in ('dev', 'start', 'serve', 'preview', 'build', 'start:prod', 'test', 'test:e2e'):
    if name in scripts:
        print(f"{name}\t{scripts[name]}")
PY
)
fi
for f in Makefile Procfile Procfile.dev compose.yaml docker-compose.yml; do
  [ -f "$f" ] && note "found" "$f"
done
if [ -f pyproject.toml ] && file_has pyproject.toml "\[tool.poetry.scripts\]"; then note "entry" "pyproject poetry scripts"; fi
if [ -d cmd ]; then note "go entrypoints" "$(ls cmd 2>/dev/null | tr '\n' ' ')"; fi
if [ -d src/main ]; then note "possible entry" "src/main (JVM)"; fi

section "Data stores"
for f in compose.yaml docker-compose.yml .env .env.example .env.local; do
  [ -f "$f" ] || continue
  for db in postgres postgresql mysql mariadb redis mongo kafka rabbitmq clickhouse elasticsearch; do
    if grep -qi -- "$db" "$f" 2>/dev/null; then note "$f" "$db"; fi
  done
done
if [ -f prisma/schema.prisma ]; then note "orm" "prisma"; fi
if [ -f alembic.ini ]; then note "migrations" "alembic"; fi
if [ -d migrations ]; then note "migrations" "migrations/"; fi

section "Load generators"
found_any=0
for g in k6 locust autocannon wrk wrk2 vegeta ab hey artillery ghz hurl; do
  if have "$g"; then note "available" "$g"; found_any=1; fi
done
if [ "$found_any" -eq 0 ]; then
  note "available" "none"
  note "install" "k6: https://k6.io/docs/get-started/installation/ | locust: pipx install locust"
fi
if have npx && ! have autocannon; then note "via npx" "npx autocannon"; fi

section "Observability"
for f in docker-compose.yml compose.yaml; do
  [ -f "$f" ] && grep -qiE 'prometheus|grafana|otel|jaeger|tempo' "$f" && note "stack" "prometheus/otel found in $f"
done
if [ -d node_modules/@opentelemetry ] 2>/dev/null || file_has package.json "@opentelemetry/api"; then note "tracing" "OpenTelemetry (node)"; fi
if file_has requirements.txt opentelemetry || file_has pyproject.toml opentelemetry; then note "tracing" "OpenTelemetry (python)"; fi
if file_has go.mod "go.opentelemetry.io"; then note "tracing" "OpenTelemetry (go)"; fi
if ls /proc/self >/dev/null 2>&1; then note "profiling" "py-spy / pprof / --cpu-prof available per stack"; fi

section "Tests and CI"
for d in tests test __tests__ e2e playwright tests/perf test/perf; do
  [ -d "$d" ] && note "test dir" "$d ($(find "$d" -type f 2>/dev/null | wc -l) files)"
done
for d in .github/workflows .gitlab-ci.yml .circleci azure-pipelines.yml Jenkinsfile; do
  [ -e "$d" ] && note "ci" "$d"
done
if [ -d .github/workflows ]; then
  note "ci jobs" "$(grep -rhoE '^\s{2}[a-zA-Z0-9_-]+:' .github/workflows/*.y*ml 2>/dev/null | tr -d ' :' | tr '\n' ' ')"
fi

section "Hardware"
if have nproc; then note "cpus" "$(nproc)"; fi
if [ -r /proc/meminfo ]; then note "memory" "$(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)"; fi
if have uname; then note "kernel" "$(uname -sr)"; fi
if [ -f /sys/fs/cgroup/cpu.max ]; then note "cpu limit" "$(cat /sys/fs/cgroup/cpu.max)"; fi
if [ -f /sys/fs/cgroup/memory.max ]; then note "mem limit" "$(cat /sys/fs/cgroup/memory.max)"; fi

section "Next steps"
if [ "$JSON_MODE" -eq 1 ]; then
  printf '%s\n' "${RECORDS[@]}" | python3 -c '
import json, sys

report = {}
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    section, key, value = (line.split("\t") + ["", ""])[:3]
    bucket = report.setdefault(section, {})
    if key in bucket:
        if not isinstance(bucket[key], list):
            bucket[key] = [bucket[key]]
        bucket[key].append(value)
    else:
        bucket[key] = value
print(json.dumps(report, indent=2, ensure_ascii=False))
'
  exit 0
fi

cat <<'EOF'
  1. Confirm the server command and port; use the production build for verdict runs.
  2. Write the load model and SLO (references/load-model.md).
  3. Seed a production-like dataset with a fixed seed.
  4. Baseline at 1 rps, then climb the ladder 10/50/100/150%.
  5. Export a summary JSON and gate it with scripts/slo-gate.sh.
EOF
