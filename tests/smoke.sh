#!/usr/bin/env bash
# smoke.sh — repository self-check. No network required except --full.
#
#   bash tests/smoke.sh          # fast: ~10 s
#   bash tests/smoke.sh --full   # also runs the demo ladder (needs npx or ab)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

PASS=0
FAIL=0
SKIP=0

ok() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }
skip() { SKIP=$((SKIP + 1)); printf '  [SKIP] %s\n' "$1"; }
section() { printf '\n== %s\n' "$1"; }

section "bash syntax"
for f in install.sh scripts/*.sh tests/smoke.sh examples/demo-api/run.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f" "bash -n failed"; fi
done

section "python syntax"
for f in scripts/normalize-result.py templates/locustfile.py templates/concurrency_pytest.py templates/seed_python.py; do
  if python3 -m py_compile "$f" 2>/dev/null; then ok "$f"; else bad "$f" "py_compile failed"; fi
done
find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null

section "javascript syntax"
for f in examples/demo-api/server.mjs examples/demo-api/data.mjs examples/demo-api/test/detail.test.mjs templates/seed-node.mjs; do
  if node --check "$f" 2>/dev/null; then ok "$f"; else bad "$f" "node --check failed"; fi
done

section "go template"
if command -v gofmt >/dev/null 2>&1; then
  if gofmt -e templates/perf_go_test.go >/dev/null 2>&1; then ok "templates/perf_go_test.go parses"; else bad "templates/perf_go_test.go" "gofmt parse error"; fi
else
  skip "gofmt not installed"
fi

section "normalizer fixtures"
check_metric() {
  local file="$1" key="$2" expected="$3" tol="${4:-0.05}"
  local actual
  actual="$(python3 scripts/normalize-result.py --input "$file" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$key'))")"
  python3 - "$actual" "$expected" "$tol" "$file $key" <<'PY'
import sys
actual, expected, tol, label = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
ok = actual not in ("None", "") and abs(float(actual) - expected) <= tol
print(f"  [{'PASS' if ok else 'FAIL'}] {label} = {actual} (expected {expected})")
sys.exit(0 if ok else 1)
PY
  if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

check_metric tests/fixtures/k6-summary.json p95 186.734
check_metric tests/fixtures/k6-summary.json samples 50815 1
check_metric tests/fixtures/k6-summary.json error_rate 0.18 0.001
check_metric tests/fixtures/autocannon.json p95 44.12
check_metric tests/fixtures/autocannon.json samples 54000 1
check_metric tests/fixtures/ab.txt p95 183 1
check_metric tests/fixtures/ab.txt rps 999.93 1
check_metric tests/fixtures/vegeta.json p95 118.4
check_metric tests/fixtures/ghz.json p95 11.84
check_metric tests/fixtures/locust_stats.csv p95 178 1
check_metric tests/fixtures/locust_stats.csv error_rate 0.164 0.001

section "slo-gate"
gate_case() {
  local expect="$1" label="$2"; shift 2
  bash scripts/slo-gate.sh "$@" >/tmp/opencode/gate.out 2>&1
  local code=$?
  if { [ "$expect" = pass ] && [ $code -eq 0 ]; } || { [ "$expect" = fail ] && [ $code -ne 0 ]; }; then
    ok "$label"
  else
    bad "$label" "expected $expect, exit $code"
  fi
}
gate_case pass "k6 meets SLO" --file tests/fixtures/k6-summary.json --p95 200 --p99 500 --err 0.5 --rps 300
gate_case fail "k6 misses p95" --file tests/fixtures/k6-summary.json --p95 150
gate_case fail "100% errors is not a 1% pass" --file tests/fixtures/k6-error-100.json --err 0.5
gate_case fail "too few samples" --file tests/fixtures/k6-few-samples.json --p95 200
gate_case fail "generator bottleneck" --file tests/fixtures/k6-dropped.json --p95 200
gate_case pass "locust csv" --file tests/fixtures/locust_stats.csv --p95 200 --err 0.5
gate_case pass "ab text" --file tests/fixtures/ab.txt --p95 200 --err 1 --rps 900
gate_case pass "vegeta json" --file tests/fixtures/vegeta.json --p95 200

section "perf-diff"
mkdir -p /tmp/opencode/smoke/before /tmp/opencode/smoke/after
cp tests/fixtures/k6-summary.json /tmp/opencode/smoke/before/a.json
python3 - tests/fixtures/k6-summary.json /tmp/opencode/smoke/after/a.json <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
steady = data["metrics"]["http_req_duration{phase:steady}"]["values"]
steady["p(95)"] = 92.4
steady["p(99)"] = 201.2
steady["p(50)"] = 41.0
json.dump(data, open(sys.argv[2], "w"), indent=2)
PY
if bash scripts/perf-diff.sh --before /tmp/opencode/smoke/before --after /tmp/opencode/smoke/after \
  --p95 200 --err 0.5 --rps 300 >/tmp/opencode/diff.out 2>&1; then
  if grep -q 'improved' /tmp/opencode/diff.out; then ok "detects improvement"; else bad "detects improvement" "no 'improved' row"; fi
else
  bad "perf-diff passes gate" "exit non-zero"
fi
if bash scripts/perf-diff.sh --before /tmp/opencode/smoke/before --after /tmp/opencode/smoke/before \
  --p95 100 >/tmp/opencode/diff2.out 2>&1; then
  bad "perf-diff fails a missed gate" "exit 0"
else
  ok "perf-diff fails a missed gate"
fi

section "perf-doctor"
if bash scripts/perf-doctor.sh --json . | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "general" in d and "Hardware" in d' 2>/dev/null; then
  ok "doctor --json emits valid JSON"
else
  bad "doctor --json emits valid JSON"
fi
if grep -q '^## Hardware' <<<"$(bash scripts/perf-doctor.sh .)"; then ok "doctor human output"; else bad "doctor human output"; fi

section "perf-verify"
VPROJ=/tmp/opencode/smoke/verify
rm -rf "$VPROJ"
mkdir -p "$VPROJ/tests/perf" "$VPROJ/results/run"
cp examples/report.md "$VPROJ/PERF-REPORT.md"
printf 'import test from "node:test"\n' >"$VPROJ/tests/perf/items.load.test.mjs"
for i in 1 2 3; do cp tests/fixtures/k6-summary.json "$VPROJ/results/run/r$i.json"; done
if bash scripts/perf-verify.sh --dir "$VPROJ" --runs 3 >/tmp/opencode/verify.out 2>&1; then
  ok "verify accepts a complete hunt"
else
  bad "verify accepts a complete hunt" "$(grep '\[FAIL\]' /tmp/opencode/verify.out | head -3 | tr '\n' ' ')"
fi
sed -i '/Reproducer/d' "$VPROJ/PERF-REPORT.md"
if bash scripts/perf-verify.sh --dir "$VPROJ" --runs 3 >/dev/null 2>&1; then
  bad "verify rejects a finding without evidence" "exit 0"
else
  ok "verify rejects a finding without evidence"
fi

section "demo regression test"
if node --test examples/demo-api/test/detail.test.mjs >/tmp/opencode/demo-test.out 2>&1; then
  ok "demo-api regression test"
else
  bad "demo-api regression test" "$(tail -5 /tmp/opencode/demo-test.out | tr '\n' ' ')"
fi

section "install matrix"
FAKE=$(mktemp -d)
if HOME="$FAKE" ./install.sh --host claude --host codex --host opencode >/tmp/opencode/install.out 2>&1 \
  && [ -r "$FAKE/.claude/skills/highload-hunt/SKILL.md" ] \
  && [ -r "$FAKE/.claude/commands/highload-hunt.md" ] \
  && [ -r "$FAKE/.codex/prompts/highload-hunt.md" ] \
  && [ -r "$FAKE/.config/opencode/commands/highload-hunt.md" ]; then
  ok "link install places skills and commands"
else
  bad "link install places skills and commands" "$(tail -3 /tmp/opencode/install.out | tr '\n' ' ')"
fi
HOME="$FAKE" ./install.sh --host dsh --mode copy >/dev/null 2>&1
if [ -r "$FAKE/.dsh/skills/highload-hunt/references/load-model.md" ]; then ok "copy install includes references"; else bad "copy install includes references"; fi
HOME="$FAKE" ./install.sh --host claude --uninstall >/dev/null 2>&1
if [ ! -e "$FAKE/.claude/skills/highload-hunt" ] && [ ! -e "$FAKE/.claude/commands/highload-hunt.md" ]; then
  ok "uninstall removes skill and command"
else
  bad "uninstall removes skill and command"
fi
rm -rf "$FAKE"

if [ "$FULL" -eq 1 ]; then
  section "demo ladder (--full)"
  if DURATION=6 REPEAT=1 bash examples/demo-api/run.sh >/tmp/opencode/demo-run.out 2>&1 \
    && grep -q 'improved' examples/demo-api/results/delta.md; then
    ok "demo run.sh end to end"
  else
    bad "demo run.sh end to end" "$(tail -5 /tmp/opencode/demo-run.out | tr '\n' ' ')"
  fi
else
  skip "demo ladder (pass --full)"
fi

printf '\nsmoke: %s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
