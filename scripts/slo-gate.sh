#!/usr/bin/env bash
# slo-gate.sh — turn a load-test result into a PASS/FAIL exit code.
#
# Usage:
#   scripts/slo-gate.sh --file results/k6.json --p95 200 --p99 500 --err 0.5 --rps 300
#   scripts/slo-gate.sh --file results/ab.txt --tool ab --p95 250
#   scripts/slo-gate.sh --file results/locust_stats.csv --tool locust --p95 200
#
# Accepts k6 --summary-export, locust --csv, autocannon -j, ab text,
# vegeta -type=json, ghz --format json, and normalized/flat JSON.
# Only the thresholds you pass are checked. Exit 1 on violation, 2 on bad input.
#
# Sample discipline: p95 requires >= 200 samples, p99 requires >= 2000 (override
# with --min-samples / --min-samples-p99). A generator bottleneck
# (dropped_iterations > 0) fails the gate unless --allow-dropped is set.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE=""
TOOL="auto"
TH_P95=""
TH_P99=""
TH_ERR=""
TH_RPS=""
MIN_SAMPLES="${MIN_SAMPLES:-200}"
MIN_SAMPLES_P99="${MIN_SAMPLES_P99:-2000}"
ALLOW_DROPPED=0
SAVE_NORMALIZED=""

die() { printf 'slo-gate: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2 ;;
    --tool) TOOL="${2:-auto}"; shift 2 ;;
    --p95) TH_P95="${2:-}"; shift 2 ;;
    --p99) TH_P99="${2:-}"; shift 2 ;;
    --err) TH_ERR="${2:-}"; shift 2 ;;
    --rps) TH_RPS="${2:-}"; shift 2 ;;
    --min-samples) MIN_SAMPLES="${2:-}"; shift 2 ;;
    --min-samples-p99) MIN_SAMPLES_P99="${2:-}"; shift 2 ;;
    --allow-dropped) ALLOW_DROPPED=1; shift ;;
    --save-normalized) SAVE_NORMALIZED="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$FILE" ] || die "missing --file"
[ -f "$FILE" ] || die "file not found: $FILE"
command -v python3 >/dev/null 2>&1 || die "python3 required"

NORM="$(mktemp)"
TMP="$(mktemp)"
trap 'rm -f "$NORM" "$TMP"' EXIT

python3 "$SCRIPT_DIR/normalize-result.py" --input "$FILE" --tool "$TOOL" --out "$NORM" >/dev/null \
  || die "cannot parse $FILE (try --tool k6|locust|autocannon|ab|vegeta|ghz)"

[ -n "$SAVE_NORMALIZED" ] && cp "$NORM" "$SAVE_NORMALIZED"

python3 - "$NORM" >"$TMP" <<'PY' || exit 2
import json, sys

with open(sys.argv[1]) as fh:
    d = json.load(fh)

def emit(key, value):
    if value is None:
        print(f"{key}=")
    elif isinstance(value, bool):
        print(f"{key}={1 if value else 0}")
    elif isinstance(value, float):
        print(f"{key}={value:.3f}")
    else:
        print(f"{key}={value}")

emit("P95", d.get("p95"))
emit("P99", d.get("p99"))
emit("ERR", d.get("error_rate"))
emit("RPS", d.get("rps"))
emit("SAMPLES", d.get("samples"))
emit("DROPPED", d.get("dropped") or 0)
emit("APPROX", bool(d.get("approx_p95")))
emit("TOOL", d.get("tool") or "unknown")
PY

# shellcheck disable=SC1090
. "$TMP"

FAIL=0
WARN=0
row() { printf '  %-14s %-14s %-13s %s\n' "$1" "${2:-n/a}" "${3:-none}" "$4"; }
cmp_le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }
cmp_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

printf 'slo-gate: %s (tool=%s)\n' "$FILE" "${TOOL:-unknown}"
printf '  %-14s %-14s %-13s %s\n' "metric" "measured" "threshold" "verdict"

if [ -n "$TH_P95" ]; then
  if [ -z "${P95:-}" ]; then row "p95" "" "${TH_P95}ms" "FAIL (missing)"; FAIL=1
  elif cmp_le "$P95" "$TH_P95"; then row "p95" "${P95}ms" "${TH_P95}ms" "PASS"
  else row "p95" "${P95}ms" "${TH_P95}ms" "FAIL"; FAIL=1; fi
fi

if [ -n "$TH_P99" ]; then
  if [ -z "${P99:-}" ]; then row "p99" "" "${TH_P99}ms" "FAIL (missing)"; FAIL=1
  elif cmp_le "$P99" "$TH_P99"; then row "p99" "${P99}ms" "${TH_P99}ms" "PASS"
  else row "p99" "${P99}ms" "${TH_P99}ms" "FAIL"; FAIL=1; fi
fi

if [ -n "$TH_ERR" ]; then
  if [ -z "${ERR:-}" ]; then row "error rate" "" "${TH_ERR}%" "FAIL (missing)"; FAIL=1
  elif cmp_le "$ERR" "$TH_ERR"; then row "error rate" "${ERR}%" "${TH_ERR}%" "PASS"
  else row "error rate" "${ERR}%" "${TH_ERR}%" "FAIL"; FAIL=1; fi
fi

if [ -n "$TH_RPS" ]; then
  if [ -z "${RPS:-}" ]; then row "rps" "" "$TH_RPS" "FAIL (missing)"; FAIL=1
  elif cmp_ge "$RPS" "$TH_RPS"; then row "rps" "${RPS}" "$TH_RPS" "PASS"
  else row "rps" "${RPS}" "$TH_RPS" "FAIL"; FAIL=1; fi
fi

if [ -n "${SAMPLES:-}" ] && [ "${SAMPLES:-0}" -gt 0 ] 2>/dev/null; then
  if [ "$SAMPLES" -lt "$MIN_SAMPLES" ] 2>/dev/null; then
    row "samples" "$SAMPLES" ">= $MIN_SAMPLES" "FAIL (p95 unreliable)"
    FAIL=1
  else
    row "samples" "$SAMPLES" ">= $MIN_SAMPLES" "PASS"
  fi
  if [ -n "$TH_P99" ] && [ "$SAMPLES" -lt "$MIN_SAMPLES_P99" ] 2>/dev/null; then
    row "samples/p99" "$SAMPLES" ">= $MIN_SAMPLES_P99" "FAIL (p99 unreliable)"
    FAIL=1
  fi
else
  row "samples" "unknown" ">= $MIN_SAMPLES" "WARN (not reported)"
  WARN=1
fi

if [ "${APPROX:-0}" = "1" ]; then
  row "p95 source" "approx" "exact" "WARN (tool has no p95, used p97.5)"
  WARN=1
fi

if [ "${DROPPED:-0}" -gt 0 ] 2>/dev/null; then
  if [ "$ALLOW_DROPPED" -eq 1 ]; then
    row "dropped iters" "$DROPPED" "allow" "WARN (generator bottleneck)"
    WARN=1
  else
    row "dropped iters" "$DROPPED" "0" "FAIL (generator bottleneck)"
    FAIL=1
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  if [ "$WARN" -eq 1 ]; then printf 'slo-gate: PASS (with warnings)\n'; else printf 'slo-gate: PASS\n'; fi
  exit 0
fi
printf 'slo-gate: FAIL\n'
exit 1
