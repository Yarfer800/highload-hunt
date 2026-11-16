#!/usr/bin/env bash
# slo-gate.sh — turn a load-test result file into a PASS/FAIL exit code.
#
# Usage:
#   scripts/slo-gate.sh --file results/k6.json --p95 200 --p99 500 --err 0.5 --rps 300
#   scripts/slo-gate.sh --file results/k6.json --p95 200 --allow-dropped
#
# Works with k6 --summary-export, locust --csv-summary JSON, vegeta JSON,
# autocannon -j, ghz JSON, or a flat {"p95":..,"p99":..,"error_rate":..,"rps":..}.
# Only the thresholds you pass are checked. Exit 1 on violation.

set -uo pipefail

FILE=""
TH_P95=""
TH_P99=""
TH_ERR=""
TH_RPS=""
MIN_SAMPLES="${MIN_SAMPLES:-200}"
ALLOW_DROPPED=0

die() { printf 'slo-gate: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2 ;;
    --p95) TH_P95="${2:-}"; shift 2 ;;
    --p99) TH_P99="${2:-}"; shift 2 ;;
    --err) TH_ERR="${2:-}"; shift 2 ;;
    --rps) TH_RPS="${2:-}"; shift 2 ;;
    --min-samples) MIN_SAMPLES="${2:-}"; shift 2 ;;
    --allow-dropped) ALLOW_DROPPED=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$FILE" ] || die "missing --file"
[ -f "$FILE" ] || die "file not found: $FILE"
command -v python3 >/dev/null 2>&1 || die "python3 required to parse JSON"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

python3 - "$FILE" >"$TMP" <<'PY' || exit 2
import json, sys

path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)

def walk(node):
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from walk(v)

def flat(name):
    for obj in walk(data):
        if name in obj and isinstance(obj[name], (int, float)):
            return float(obj[name])
    return None

metrics = data.get("metrics") if isinstance(data, dict) else None
metrics = metrics if isinstance(metrics, dict) else {}

def metric(name, *keys):
    node = metrics.get(name)
    if not isinstance(node, dict):
        return None
    for key in keys:
        val = node.get(key)
        if isinstance(val, (int, float)):
            return float(val)
    val = node.get("value")
    return float(val) if isinstance(val, (int, float)) else None

def first(*values):
    for v in values:
        if v is not None:
            return v
    return None

bucket = lambda name: metrics.get(name, {}) if isinstance(metrics.get(name), dict) else {}

steady_duration = first(
    bucket("http_req_duration{phase:steady}").get("p(95)"),
    bucket("http_req_duration").get("p(95)"),
)
# Prefer the steady-state tags when present.
dur = bucket("http_req_duration{phase:steady}") or bucket("http_req_duration") or {}
failed = bucket("http_req_failed{phase:steady}") or bucket("http_req_failed") or {}
reqs = bucket("http_reqs") or {}
dropped = bucket("dropped_iterations") or {}
latency = data.get("latency") if isinstance(data.get("latency"), dict) else {}

p95 = first(dur.get("p(95)"), flat("p95"), flat("p(95)"), latency.get("95"), flat("percentile95"))
p99 = first(dur.get("p(99)"), flat("p99"), flat("p(99)"), latency.get("99"), flat("percentile99"))
err_raw = first(failed.get("rate"), flat("error_rate"), flat("err"), flat("errorRate"))
rps = first(reqs.get("rate"), flat("rps"), flat("requests_per_second"), flat("throughput"))
samples = first(reqs.get("count"), flat("samples"), flat("count"), flat("total_requests"))
dropped_n = first(dropped.get("count"), flat("dropped_iterations"), 0.0)

# Normalize error rate to percent: k6 and most tools give a 0..1 ratio.
err_pct = None
if err_raw is not None:
    err_pct = err_raw * 100.0 if err_raw <= 1.0 else err_raw

def emit(key, value):
    print(f"{key}={'' if value is None else value}")

emit("P95", p95)
emit("P99", p99)
emit("ERR", err_pct)
emit("RPS", rps)
emit("SAMPLES", int(samples) if samples is not None else None)
emit("DROPPED", int(dropped_n) if dropped_n is not None else 0)
PY

# shellcheck disable=SC1090
. "$TMP"

[ -n "${P95:-}" ] || printf 'slo-gate: warning: p95 not found in %s\n' "$FILE" >&2
[ -n "${P99:-}" ] || printf 'slo-gate: warning: p99 not found in %s\n' "$FILE" >&2
[ -n "${RPS:-}" ] || printf 'slo-gate: warning: rps not found in %s\n' "$FILE" >&2

FAIL=0
print_row() { printf '  %-12s %-14s %-12s %s\n' "$1" "${2:-n/a}" "${3:-none}" "$4"; }

cmp_le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }
cmp_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

printf 'slo-gate: %s\n' "$FILE"
printf '  %-12s %-14s %-12s %s\n' "metric" "measured" "threshold" "verdict"

if [ -n "$TH_P95" ]; then
  if [ -z "${P95:-}" ]; then print_row "p95" "" "$TH_P95" "FAIL (missing)"; FAIL=1
  elif cmp_le "$P95" "$TH_P95"; then print_row "p95" "${P95}ms" "${TH_P95}ms" "PASS"
  else print_row "p95" "${P95}ms" "${TH_P95}ms" "FAIL"; FAIL=1; fi
fi

if [ -n "$TH_P99" ]; then
  if [ -z "${P99:-}" ]; then print_row "p99" "" "$TH_P99" "FAIL (missing)"; FAIL=1
  elif cmp_le "$P99" "$TH_P99"; then print_row "p99" "${P99}ms" "${TH_P99}ms" "PASS"
  else print_row "p99" "${P99}ms" "${TH_P99}ms" "FAIL"; FAIL=1; fi
fi

if [ -n "$TH_ERR" ]; then
  if [ -z "${ERR:-}" ]; then print_row "error rate" "" "${TH_ERR}%" "FAIL (missing)"; FAIL=1
  elif cmp_le "$ERR" "$TH_ERR"; then print_row "error rate" "${ERR}%" "${TH_ERR}%" "PASS"
  else print_row "error rate" "${ERR}%" "${TH_ERR}%" "FAIL"; FAIL=1; fi
fi

if [ -n "$TH_RPS" ]; then
  if [ -z "${RPS:-}" ]; then print_row "rps" "" "$TH_RPS" "FAIL (missing)"; FAIL=1
  elif cmp_ge "$RPS" "$TH_RPS"; then print_row "rps" "${RPS}" "$TH_RPS" "PASS"
  else print_row "rps" "${RPS}" "$TH_RPS" "FAIL"; FAIL=1; fi
fi

if [ -n "${SAMPLES:-}" ] && [ "$SAMPLES" -lt "$MIN_SAMPLES" ] 2>/dev/null; then
  print_row "samples" "$SAMPLES" ">= $MIN_SAMPLES" "FAIL (too few)"
  FAIL=1
fi

if [ "${DROPPED:-0}" -gt 0 ] 2>/dev/null; then
  if [ "$ALLOW_DROPPED" -eq 1 ]; then
    print_row "dropped iters" "$DROPPED" "allow" "WARN (generator bottleneck)"
  else
    print_row "dropped iters" "$DROPPED" "0" "FAIL (generator bottleneck)"
    FAIL=1
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  printf 'slo-gate: PASS\n'
  exit 0
fi
printf 'slo-gate: FAIL\n'
exit 1
