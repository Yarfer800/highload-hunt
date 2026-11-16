#!/usr/bin/env bash
# ladder.sh — run a load ladder, take medians, find the knee.
#
# Usage:
#   scripts/ladder.sh --runner k6 --script tests/perf/k6/items.js --rps 300
#   scripts/ladder.sh --runner autocannon --host http://localhost:8080 --path /api/items \
#     --rps 300 --levels 10,50,100,150 --repeat 3 --out results/ladder \
#     --gate-p95 200 --gate-p99 500 --gate-err 0.5 --gate-rps 300
#   scripts/ladder.sh --runner ab --rps 200 --duration 60 --levels 10,100
#   scripts/ladder.sh --runner custom --rps 300 --levels 50,100 \
#     --cmd 'vegeta attack -rate={rps} -duration=60s -targets=targets.txt | vegeta encode > {out}.bin'
#
# Writes raw + normalized results and a markdown table to <out>/ladder.md.
# Exit 0 by default: ladder results are expected to include a failing level.
# Use --strict to exit 1 when any level misses a gate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPS=""
LEVELS="10,50,100,150"
REPEAT=1
WARMUP=60
DURATION=180
RUNNER=""
SCRIPT=""
HOST="http://localhost:8080"
TARGET_PATH="/api/items"
OUT="results/ladder"
CMD_TMPL=""
GP95=""
GP99=""
GERR=""
GRPS=""
TOOL="auto"
STRICT=0
CONNECTIONS=100
SLEEP_BETWEEN=5

die() { printf 'ladder: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rps) RPS="${2:-}"; shift 2 ;;
    --levels) LEVELS="${2:-}"; shift 2 ;;
    --repeat) REPEAT="${2:-1}"; shift 2 ;;
    --warmup) WARMUP="${2:-60}"; shift 2 ;;
    --duration) DURATION="${2:-180}"; shift 2 ;;
    --runner) RUNNER="${2:-}"; shift 2 ;;
    --script) SCRIPT="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --path) TARGET_PATH="${2:-}"; shift 2 ;;
    --out) OUT="${2:-results/ladder}"; shift 2 ;;
    --cmd) CMD_TMPL="${2:-}"; RUNNER="custom"; shift 2 ;;
    --gate-p95) GP95="${2:-}"; shift 2 ;;
    --gate-p99) GP99="${2:-}"; shift 2 ;;
    --gate-err) GERR="${2:-}"; shift 2 ;;
    --gate-rps) GRPS="${2:-}"; shift 2 ;;
    --tool) TOOL="${2:-auto}"; shift 2 ;;
    --connections) CONNECTIONS="${2:-100}"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$RPS" ] || die "missing --rps (target rate at the 100% level)"
[ -n "$RUNNER" ] || die "missing --runner k6|autocannon|ab|custom"

URL="${HOST%/}/${TARGET_PATH#/}"

prepare_runner() {
  case "$RUNNER" in
    k6)
      command -v k6 >/dev/null 2>&1 || die "k6 not installed (or use --runner autocannon|ab|custom)"
      [ -n "$SCRIPT" ] || die "--runner k6 requires --script"
      [ -f "$SCRIPT" ] || die "script not found: $SCRIPT"
      ;;
    autocannon) command -v npx >/dev/null 2>&1 || die "npx not found for autocannon" ;;
    ab) command -v ab >/dev/null 2>&1 || die "ab not found" ;;
    custom) [ -n "$CMD_TMPL" ] || die "--runner custom requires --cmd" ;;
    *) die "unknown runner: $RUNNER" ;;
  esac
}

prepare_runner
mkdir -p "$OUT/raw" "$OUT/normalized" || die "cannot create $OUT"
rm -f "$OUT"/raw/* "$OUT"/normalized/* 2>/dev/null

IFS=',' read -r -a LVLS <<<"$LEVELS"

total_runs=$(( ${#LVLS[@]} * REPEAT ))
printf 'ladder: %s runner, rps=%s at 100%%, levels=%s, %s run(s) x %ss\n' \
  "$RUNNER" "$RPS" "$LEVELS" "$total_runs" "$DURATION"

run_generator() {
  local rate="$1" raw="$2" level="$3"
  case "$RUNNER" in
    k6)
      TARGET_RPS="$rate" BASE_URL="$HOST" PATH="$TARGET_PATH" \
        WARMUP="${WARMUP}s" DURATION="${DURATION}s" RESULT_FILE="$raw" \
        k6 run --summary-export="$raw" "$SCRIPT" >"$raw.log" 2>&1 \
        || printf 'ladder: k6 exited non-zero at %s rps (check %s)\n' "$rate" "$raw.log" >&2
      ;;
    autocannon)
      npx --yes autocannon -c "$CONNECTIONS" -d "$DURATION" -R "$rate" -j "$URL" >"$raw" 2>"$raw.log" \
        || printf 'ladder: autocannon exited non-zero at %s rps\n' "$rate" >&2
      ;;
    ab)
      local requests=$(( rate * DURATION ))
      ab -n "$requests" -c "$CONNECTIONS" -q "$URL" >"$raw" 2>"$raw.log" \
        || printf 'ladder: ab exited non-zero at %s rps\n' "$rate" >&2
      ;;
    custom)
      local cmd="$CMD_TMPL"
      cmd="${cmd//\{rps\}/$rate}"
      cmd="${cmd//\{duration\}/$DURATION}"
      cmd="${cmd//\{level\}/$level}"
      cmd="${cmd//\{out\}/$raw}"
      cmd="${cmd//\{url\}/$URL}"
      bash -c "$cmd" >"$raw" 2>"$raw.log" \
        || printf 'ladder: custom command failed at %s rps\n' "$rate" >&2
      ;;
  esac
}

ext_for_runner() {
  case "$RUNNER" in
    ab) printf 'txt' ;;
    *) printf 'json' ;;
  esac
}

for level in "${LVLS[@]}"; do
  rate=$(( RPS * level / 100 ))
  [ "$rate" -lt 1 ] && rate=1
  for rep in $(seq 1 "$REPEAT"); do
    raw="$OUT/raw/L${level}-r${rep}.$(ext_for_runner)"
    printf '  level %s%% (%s rps) run %s/%s\n' "$level" "$rate" "$rep" "$REPEAT"
    run_generator "$rate" "$raw" "$level"
    if ! python3 "$SCRIPT_DIR/normalize-result.py" --input "$raw" --tool "$TOOL" \
      --level "$level" --target-rps "$rate" \
      --out "$OUT/normalized/L${level}-r${rep}.json" 2>"$raw.norm.log"; then
      printf '  warning: cannot normalize %s, see %s\n' "$raw" "$raw.norm.log" >&2
    fi
    [ "$rep" -lt "$REPEAT" ] && sleep "$SLEEP_BETWEEN"
  done
done

python3 - "$OUT/normalized" "$OUT/ladder.md" "$GP95" "$GP99" "$GERR" "$GRPS" "$STRICT" <<'PY'
import glob, json, os, statistics, sys

norm_dir, out_path = sys.argv[1], sys.argv[2]
gates = {"p95": sys.argv[3], "p99": sys.argv[4], "err": sys.argv[5], "rps": sys.argv[6]}
strict = sys.argv[7] == "1"

runs = []
for path in sorted(glob.glob(os.path.join(norm_dir, "*.json"))):
    with open(path) as fh:
        try:
            data = json.load(fh)
        except json.JSONDecodeError:
            continue
    try:
        level = float(data.get("level"))
    except (TypeError, ValueError):
        continue
    data["_level"] = level
    runs.append(data)

if not runs:
    print("ladder: no normalized results", file=sys.stderr)
    sys.exit(2)

by_level = {}
for run in runs:
    by_level.setdefault(run["_level"], []).append(run)

def med(values):
    values = [v for v in values if isinstance(v, (int, float))]
    return statistics.median(values) if values else None

def agg(group, key):
    return med([r.get(key) for r in group])

lines = ["# Load ladder", "", "| level | target rps | runs | p50 | p95 | p99 | error % | rps | samples | gate |",
         "|------:|-----------:|-----:|----:|----:|----:|--------:|----:|--------:|------|"]
knee = None
base_p95 = None
gate_fail = False
points = []

for level in sorted(by_level):
    group = by_level[level]
    p50, p95, p99 = agg(group, "p50"), agg(group, "p95"), agg(group, "p99")
    err, rps, samples = agg(group, "error_rate"), agg(group, "rps"), agg(group, "samples")
    target = agg(group, "target_rps")

    checks = []
    if gates["p95"] and p95 is not None:
        checks.append(p95 <= float(gates["p95"]))
    if gates["p99"] and p99 is not None:
        checks.append(p99 <= float(gates["p99"]))
    if gates["err"] and err is not None:
        checks.append(err <= float(gates["err"]))
    if gates["rps"] and rps is not None:
        checks.append(rps >= float(gates["rps"]))
    status = "—" if not checks else ("PASS" if all(checks) else "FAIL")
    if status == "FAIL":
        gate_fail = True

    def f(value, digits=1):
        return "n/a" if value is None else f"{value:.{digits}f}"

    lines.append(
        f"| {level:g}% | {f(target, 0)} | {len(group)} | {f(p50)} | {f(p95)} | {f(p99)} | "
        f"{f(err, 2)} | {f(rps)} | {f(samples, 0)} | {status} |"
    )
    points.append((level, p95, err))

if points:
    base_p95 = points[0][1]
    if base_p95:
        for level, p95, err in points[1:]:
            if p95 is not None and p95 >= 2 * base_p95:
                knee = level
                break
    error_knee = next((level for level, _, err in points if err is not None and err > 1.0), None)

    lines += ["", f"- knee (p95 >= 2x the lowest level): **{f'{knee:g}%' if knee else 'not reached'}**"]
    if error_knee is not None:
        lines.append(f"- first level above 1% errors: **{error_knee:g}%**")
    lines.append(f"- levels tested: {', '.join(f'{l:g}%' for l, _, _ in points)}")
    configured = any(gates.values())
    lines.append(f"- gate: {'PASS' if not gate_fail else 'FAIL'}" if configured else "- gate: not configured")

lines.append("")
with open(out_path, "w") as fh:
    fh.write("\n".join(lines))

print("\n".join(lines))
sys.exit(1 if (gate_fail and strict) else 0)
PY
status=$?

printf '\nladder: artifacts in %s (ladder.md, raw/, normalized/)\n' "$OUT"
if [ "$STRICT" -eq 1 ] && [ "$status" -ne 0 ]; then
  printf 'ladder: FAIL (--strict, a level missed its gate)\n'
  exit 1
fi
exit 0
