#!/usr/bin/env bash
# End-to-end demo: measures the demo-api defect, fixes it, proves the delta.
#
#   bash examples/demo-api/run.sh            # ~90 s, needs npx (autocannon)
#   DURATION=5 REPEAT=1 bash examples/demo-api/run.sh   # faster
#   RUNNER=ab bash examples/demo-api/run.sh             # no network needed
#
# Artifacts land in examples/demo-api/results/ (gitignored).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PORT="${PORT:-18080}"
RPS="${RPS:-100}"
DURATION="${DURATION:-10}"
REPEAT="${REPEAT:-3}"
RUNNER="${RUNNER:-autocannon}"
OUT="$ROOT/examples/demo-api/results"
HOST="http://localhost:$PORT"
PATH_="${PATH_:-/api/items?id=42}"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

server_pid=""
start_server() {
  local defect="$1"
  [ -n "$server_pid" ] && { kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; } || true
  PERF_DEFECT="$defect" PORT="$PORT" ITEMS="${ITEMS:-200000}" \
    node examples/demo-api/server.mjs >"$OUT/server-$defect.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 100); do
    local mode
    mode="$(curl -sf --noproxy '*' "$HOST/health" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("defect",""))' 2>/dev/null || true)"
    if [ "$mode" = "$defect" ]; then
      return 0
    fi
    if [ -n "$mode" ] && [ "$mode" != "$defect" ]; then
      echo "demo: $HOST is serving defect=$mode, expected $defect — port in use by another process" >&2
      exit 1
    fi
    sleep 0.1
  done
  echo "demo: server did not become ready, see $OUT/server-$defect.log" >&2
  exit 1
}

cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

ladder() {
  local label="$1"
  bash scripts/ladder.sh --runner "$RUNNER" --host "$HOST" --path "$PATH_" \
    --rps "$RPS" --levels 10,50,100 --duration "$DURATION" --repeat "$REPEAT" \
    --out "$OUT/$label" --gate-p95 100 --gate-p99 200 --gate-err 0.5
}

echo "== 1/4 defect ON"
start_server on
ladder before

echo "== 2/4 defect OFF"
start_server off
ladder after

echo "== 3/4 delta"
diff_status=0
bash scripts/perf-diff.sh --before "$OUT/before/normalized" --after "$OUT/after/normalized" \
  --level 100 --p95 100 --err 0.5 --rps "$RPS" --out "$OUT/delta.md" || diff_status=$?

echo "== 4/4 regression test"
node --test examples/demo-api/test/detail.test.mjs

echo
if [ "$diff_status" -ne 0 ]; then
  echo "demo: gate FAILED on this run; see $OUT/delta.md"
  echo "demo: short runs on a shared host are noisy — use DURATION=30 REPEAT=3 for a verdict"
fi
echo "demo: artifacts in $OUT"
[ "${STRICT:-0}" = "1" ] && exit "$diff_status"
exit 0
