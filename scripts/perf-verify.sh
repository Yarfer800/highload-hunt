#!/usr/bin/env bash
# perf-verify.sh — artifact gate. Refuse to call a hunt finished without evidence.
#
# Usage:
#   scripts/perf-verify.sh --dir . --runs 3
#   scripts/perf-verify.sh --report PERF-REPORT.md --tests tests/perf --results results --json
#
# Checks:
#   report exists, has a single PASS/FAIL/BLOCKED verdict, no placeholders
#   report has at least one finding with reproducer + metric + mechanism
#   perf tests exist in the repo
#   at least N parseable runs with >= min samples at one level
#   report has a "Not tested" section
#
# Exit 0 = evidence complete. Exit 1 = the hunt cannot be called done.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="."
REPORT="PERF-REPORT.md"
TESTS="tests/perf"
RESULTS="results"
RUNS=3
MIN_SAMPLES="${MIN_SAMPLES:-200}"
JSON_MODE=0

die() { printf 'perf-verify: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:-.}"; shift 2 ;;
    --report) REPORT="${2:-PERF-REPORT.md}"; shift 2 ;;
    --tests) TESTS="${2:-tests/perf}"; shift 2 ;;
    --results) RESULTS="${2:-results}"; shift 2 ;;
    --runs) RUNS="${2:-3}"; shift 2 ;;
    --min-samples) MIN_SAMPLES="${2:-200}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

REPORT_PATH="$DIR/$REPORT"
TESTS_PATH="$DIR/$TESTS"
RESULTS_PATH="$DIR/$RESULTS"

python3 - "$REPORT_PATH" "$TESTS_PATH" "$RESULTS_PATH" "$RUNS" "$MIN_SAMPLES" "$JSON_MODE" "$SCRIPT_DIR" <<'PY'
import glob
import json
import os
import re
import subprocess
import sys

report, tests_dir, results_dir = sys.argv[1], sys.argv[2], sys.argv[3]
required_runs, min_samples = int(sys.argv[4]), int(sys.argv[5])
as_json = sys.argv[6] == "1"
normalizer = os.path.join(sys.argv[7], "normalize-result.py")

checks = []


def add(name, ok, detail):
    checks.append({"check": name, "ok": bool(ok), "detail": detail})


# 1. Report exists.
text = ""
if os.path.isfile(report):
    with open(report, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
add("report exists", bool(text.strip()), report if text.strip() else "missing or empty")

# 2. Verdict line.
verdicts = re.findall(r"^\s*Verdict:\s*\**\s*(PASS|FAIL|BLOCKED)\b", text, re.MULTILINE | re.IGNORECASE)
add("verdict present", len(verdicts) >= 1, f"found: {verdicts}" if verdicts else "no 'Verdict: PASS|FAIL|BLOCKED' line")
add("verdict single", len(set(v.upper() for v in verdicts)) <= 1, "conflicting verdicts" if len(set(verdicts)) > 1 else "ok")

# 3. Placeholders.
placeholders = re.findall(r"(?:<x>|<y>|<n>|\bTBD\b|\bTODO\b|\bpending\b)", text, re.IGNORECASE)
add("no placeholders", not placeholders, f"{len(placeholders)} placeholder(s): {sorted(set(p.lower() for p in placeholders))}" if placeholders else "clean")

# 4. Findings with evidence.
finding_blocks = re.split(r"^###\s+F\d+", text, flags=re.MULTILINE)[1:]
complete = [b for b in finding_blocks if re.search(r"Reproducer", b, re.I) and re.search(r"Mechanism", b, re.I) and re.search(r"Metric", b, re.I)]
add(
    "findings have evidence",
    bool(finding_blocks) and len(complete) == len(finding_blocks),
    f"{len(complete)}/{len(finding_blocks)} finding(s) have reproducer+metric+mechanism",
)

# 5. Tests exist.
test_files = []
if os.path.isdir(tests_dir):
    for root, _, files in os.walk(tests_dir):
        for name in files:
            if re.search(r"(perf|load|stress|bench|concurrency)", name, re.I):
                test_files.append(os.path.join(root, name))
add("perf tests present", bool(test_files), f"{len(test_files)} file(s) under {tests_dir}")

# 6. Result runs.
raw_files = []
for pattern in ("*.json", "*.csv", "*.txt"):
    raw_files.extend(glob.glob(os.path.join(results_dir, "**", pattern), recursive=True))
normalized = []
for path in sorted(set(raw_files)):
    try:
        out = subprocess.run(
            [sys.executable, normalizer, "--input", path],
            capture_output=True, text=True, timeout=30,
        )
        if out.returncode != 0:
            continue
        data = json.loads(out.stdout)
    except Exception:
        continue
    if data.get("p95") is None:
        continue
    normalized.append(data)

by_level = {}
for run in normalized:
    level = str(run.get("level") or "unknown")
    by_level.setdefault(level, []).append(run)

best_level, best_runs = (None, [])
for level, group in by_level.items():
    if len(group) > len(best_runs):
        best_level, best_runs = level, group

good_runs = [r for r in best_runs if (r.get("samples") or 0) >= min_samples]
add(
    "repeat runs",
    len(good_runs) >= required_runs,
    f"{len(good_runs)}/{required_runs} run(s) with >= {min_samples} samples at level {best_level}",
)

# 7. Not tested section.
add("not tested section", bool(re.search(r"^#+\s*Not tested", text, re.MULTILINE | re.IGNORECASE)), "present" if "not tested" in text.lower() else "missing")

# 8. Artifact links (informational: examples and CI copies often drop raw files).
linked = re.findall(r"`([^`]+\.json)`", text)
linked_ok = [p for p in linked if os.path.isfile(os.path.join(os.path.dirname(report), p)) or os.path.isfile(p) or glob.glob(os.path.join(os.path.dirname(report), p))]
warnings = []
if linked and not linked_ok:
    warnings.append(f"{len(linked)} linked result file(s) not found next to the report")

failed = [c for c in checks if not c["ok"]]
payload = {
    "report": report,
    "verdict": verdicts[0].upper() if verdicts else None,
    "checks": checks,
    "warnings": warnings,
    "passed": len(checks) - len(failed),
    "failed": len(failed),
    "ok": not failed,
}

if as_json:
    print(json.dumps(payload, indent=2))
else:
    print(f"perf-verify: {report}")
    for c in checks:
        mark = "PASS" if c["ok"] else "FAIL"
        print(f"  [{mark}] {c['check']:<24} {c['detail']}")
    for warning in warnings:
        print(f"  [WARN] {'artifacts':<24} {warning}")
    print()
    print(f"perf-verify: {'PASS' if not failed else 'FAIL'} ({payload['passed']}/{len(checks)} checks)")

sys.exit(0 if not failed else 1)
PY
