#!/usr/bin/env bash
# perf-diff.sh — A/B two series of load-test runs with medians and spread.
#
# Usage:
#   scripts/perf-diff.sh --before results/before --after results/after
#   scripts/perf-diff.sh --before 'results/before/*.json' --after 'results/after/*.json' \
#     --p95 200 --err 0.5 --rps 300 --out results/delta.md
#   scripts/perf-diff.sh --before a.json,b.json --after c.json,d.json --noise 10
#
# Inputs: directories or globs of raw outputs any tool slo-gate.sh understands.
# Outputs: markdown table with medians, delta percent, and PASS/FAIL of the
# "after" series against thresholds. Exit 1 if the after series violates a gate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEFORE=""
AFTER=""
TH_P95=""
TH_P99=""
TH_ERR=""
TH_RPS=""
NOISE="${NOISE:-10}"
OUT=""
PRINT_JSON=0
LEVEL=""

die() { printf 'perf-diff: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --before) BEFORE="${2:-}"; shift 2 ;;
    --after) AFTER="${2:-}"; shift 2 ;;
    --p95) TH_P95="${2:-}"; shift 2 ;;
    --p99) TH_P99="${2:-}"; shift 2 ;;
    --err) TH_ERR="${2:-}"; shift 2 ;;
    --rps) TH_RPS="${2:-}"; shift 2 ;;
    --noise) NOISE="${2:-10}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --level) LEVEL="${2:-}"; shift 2 ;;
    --json) PRINT_JSON=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$BEFORE" ] || die "missing --before"
[ -n "$AFTER" ] || die "missing --after"

collect_files() {
  local spec="$1" item
  if [ -d "$spec" ]; then
    find "$spec" -maxdepth 1 -type f \( -name '*.json' -o -name '*.csv' -o -name '*.txt' \) | sort
    return
  fi
  IFS=',' read -r -a items <<<"$spec"
  for item in "${items[@]}"; do
    if [ -d "$item" ]; then
      find "$item" -maxdepth 1 -type f \( -name '*.json' -o -name '*.csv' -o -name '*.txt' \) | sort
    elif compgen -G "$item" >/dev/null; then
      compgen -G "$item" | sort
    fi
  done
}

norm_series() {
  local spec="$1" dest="$2" files file idx=0
  mkdir -p "$dest" || die "cannot create $dest"
  mapfile -t files < <(collect_files "$spec")
  [ "${#files[@]}" -gt 0 ] || die "no result files matched: $spec"
  for file in "${files[@]}"; do
    idx=$((idx + 1))
    python3 "$SCRIPT_DIR/normalize-result.py" --input "$file" --out "$dest/$(printf '%03d' "$idx").json" >/dev/null 2>&1 \
      || { printf 'perf-diff: skipping unparseable %s\n' "$file" >&2; rm -f "$dest/$(printf '%03d' "$idx").json"; }
  done
  [ -n "$(ls -A "$dest" 2>/dev/null)" ] || die "no parseable results in: $spec"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

norm_series "$BEFORE" "$WORK/before"
norm_series "$AFTER" "$WORK/after"

python3 - "$WORK/before" "$WORK/after" "$NOISE" "$TH_P95" "$TH_P99" "$TH_ERR" "$TH_RPS" "$PRINT_JSON" "$LEVEL" <<'PY' >"$WORK/report.md"
import glob, json, os, sys

before_dir, after_dir, noise = sys.argv[1], sys.argv[2], float(sys.argv[3])
th = {"p95": sys.argv[4], "p99": sys.argv[5], "err": sys.argv[6], "rps": sys.argv[7]}
as_json = sys.argv[8] == "1"
level_filter = sys.argv[9] if len(sys.argv) > 9 else ""

def series(path):
    runs = []
    for f in sorted(glob.glob(os.path.join(path, "*.json"))):
        with open(f) as fh:
            try:
                d = json.load(fh)
            except json.JSONDecodeError:
                continue
        runs.append(d)
    return runs

def median(values):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    mid = len(values) // 2
    return values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) / 2

before, after = series(before_dir), series(after_dir)

def levels_of(runs):
    found = set()
    for run in runs:
        raw = run.get("level")
        if raw is None:
            continue
        try:
            found.add(float(str(raw).rstrip("%")))
        except ValueError:
            continue
    return found

all_levels = levels_of(before) | levels_of(after)
chosen = None
if level_filter:
    chosen = float(str(level_filter).rstrip("%"))
elif len(all_levels) > 1:
    chosen = max(all_levels)

if chosen is not None:
    def match(run):
        raw = run.get("level")
        try:
            return float(str(raw).rstrip("%")) == chosen
        except (TypeError, ValueError):
            return False
    filtered_before = [r for r in before if match(r)]
    filtered_after = [r for r in after if match(r)]
    if filtered_before and filtered_after:
        before, after = filtered_before, filtered_after

METRICS = [
    ("p50", "p50, ms", "lower"),
    ("p95", "p95, ms", "lower"),
    ("p99", "p99, ms", "lower"),
    ("error_rate", "error rate, %", "lower"),
    ("rps", "rps", "higher"),
]

def stat(runs, key):
    return median([r.get(key) for r in runs])

def fmt(value):
    if value is None:
        return "n/a"
    if abs(value) >= 100:
        return f"{value:.0f}"
    return f"{value:.1f}"

rows = []
for key, label, direction in METRICS:
    b, a = stat(before, key), stat(after, key)
    if b is None or a is None:
        delta = None
    elif b == a:
        delta = 0.0
    elif b == 0:
        delta = None
    else:
        delta = (a - b) / b * 100.0
    if delta is None:
        verdict = "n/a"
    elif abs(delta) <= noise:
        verdict = "flat"
    elif (delta < 0) == (direction == "lower"):
        verdict = "improved"
    else:
        verdict = "regressed"
    rows.append((label, b, a, delta, verdict))

gate_fail = []
gates = []
if th["p95"]:
    gates.append(("p95", th["p95"], "le"))
if th["p99"]:
    gates.append(("p99", th["p99"], "le"))
if th["err"]:
    gates.append(("error_rate", th["err"], "le"))
if th["rps"]:
    gates.append(("rps", th["rps"], "ge"))

after_med = {key: stat(after, key) for key, _, _ in METRICS}
for key, limit, op in gates:
    value = after_med.get(key)
    ok = value is not None and ((value <= float(limit)) if op == "le" else (value >= float(limit)))
    if not ok:
        gate_fail.append((key, value, limit, op))

if as_json:
    payload = {
        "before": {"runs": len(before), "metrics": {k: stat(before, k) for k, _, _ in METRICS}},
        "after": {"runs": len(after), "metrics": after_med},
        "rows": [
            {"metric": label, "before": b, "after": a, "delta_pct": delta, "verdict": verdict}
            for label, b, a, delta, verdict in rows
        ],
        "gates_failed": [{"metric": k, "after": v, "limit": l, "op": op} for k, v, l, op in gate_fail],
    }
    print(json.dumps(payload, indent=2))
    sys.exit(0)

print(f"# A/B performance delta\n")
print(f"- before: {len(before)} run(s)")
print(f"- after: {len(after)} run(s)")
if chosen is not None:
    print(f"- level compared: {chosen:g}%")
print(f"- noise threshold: ±{noise:g}%")
print()
print("| metric | before (median) | after (median) | delta | verdict |")
print("|--------|----------------:|---------------:|------:|---------|")
for label, b, a, delta, verdict in rows:
    dtext = "n/a" if delta is None else f"{delta:+.1f}%"
    print(f"| {label} | {fmt(b)} | {fmt(a)} | {dtext} | {verdict} |")
print()
p95s = [r.get("p95") for r in after if isinstance(r.get("p95"), (int, float))]
if len(p95s) >= 2:
    print(f"p95 spread after: min {min(p95s):.1f} ms, median {median(p95s):.1f} ms, max {max(p95s):.1f} ms\n")

if gates:
    print("| gate | after | limit | result |")
    print("|------|------:|------:|--------|")
    for key, limit, op in gates:
        value = after_med.get(key)
        ok = value is not None and ((value <= float(limit)) if op == "le" else (value >= float(limit)))
        print(f"| {key} {'<=' if op == 'le' else '>='} | {fmt(value)} | {limit} | {'PASS' if ok else 'FAIL'} |")
    print()

print("perf-diff: " + ("FAIL" if gate_fail else "PASS"))
sys.exit(1 if gate_fail else 0)
PY
status=$?

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  cp "$WORK/report.md" "$OUT"
  printf 'perf-diff: report written to %s\n' "$OUT" >&2
fi

cat "$WORK/report.md"
exit "$status"
