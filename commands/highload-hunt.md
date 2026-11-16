---
description: Run a measured highload performance hunt — write explicit perf E2E tests in the repo, find the breaking point, prove p95/p99/throughput defects with numbers, report before changing code.
argument-hint: "[target endpoint, service, or path] [--rps 300] [--slo-p95 200] [--slo-p99 500] [--tier S|M|L] [--report-only]"
---

# Highload Hunt

Arguments: `$ARGUMENTS`

If no arguments: treat the whole project as the target, ask for the production peak rps and latency expectations, then pick Tier M.

## Step 0 — Load the skill

This command is a launcher. The protocol lives in the skill. Read `SKILL.md` before any action, in this order:

1. `~/.agents/skills/highload-hunt/SKILL.md`
2. `~/.claude/skills/highload-hunt/SKILL.md`
3. `~/.config/opencode/skills/highload-hunt/SKILL.md`
4. `~/.codex/skills/highload-hunt/SKILL.md`
5. `.agents/skills/highload-hunt/SKILL.md`
6. If none exist: `git clone https://github.com/Yarfer800/highload-hunt /tmp/highload-hunt` and read `/tmp/highload-hunt/SKILL.md`, then run its `install.sh`.

Follow the 8 phases and the hard gates in that file. They override convenience. Do not summarize the skill, do not propose a plan instead of executing it, and do not skip Phase 0.

## Step 1 — Preflight

```bash
bash "$(dirname <skill-path>)/scripts/perf-doctor.sh" .
```

Report the detected stack, start command, port, datastore, and available generators in 10 lines or less. Ask only what the doctor cannot detect: target rate, SLO expectations, environment to use.

## Step 2 — Execute the hunt

Run phases 0 through 5 without stopping for permission at each step. Requirements:

- Write the perf test into `tests/perf/` in this repo, not in `/tmp`.
- Seed production-like data with a fixed seed and record it.
- Ramp 10/50/100/150%, 3 runs at target, export JSON summaries.
- Gate each result: `bash <skill>/scripts/slo-gate.sh --file <result> --p95 ... --p99 ... --err ... --rps ...`
- Collect at least one profile and the top DB queries before naming a mechanism.

## Step 3 — Report, then stop

Write `PERF-REPORT.md` from `<skill>/references/report-template.md`. Finish with exactly one verdict: PASS, FAIL, or BLOCKED.

Then stop and ask the user to approve fixes. Unless the arguments include `--report-only`, still stop: Gate G4 requires explicit approval before production code changes.

## Step 4 — Fixes only after approval

One defect per change. Re-run the identical scenario (same seed, rate, duration, dataset) and fill the before/after delta table. Add a regression test that fails on the old code. Revert any fix that does not move the number and say so.

## Forbidden

`sleep` as throttle, mocked DB or cache in the load test, p95 from fewer than 200 samples, one-run comparisons, changing SLO thresholds mid-hunt, declaring success without a gate result. If you catch one of these, discard the run.
