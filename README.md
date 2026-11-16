<div align="center">

# 🎯 highload-hunt

**A skill that makes AI coding agents prove performance under load — instead of guessing.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![CI](https://github.com/Yarfer800/highload-hunt/actions/workflows/ci.yml/badge.svg)](https://github.com/Yarfer800/highload-hunt/actions/workflows/ci.yml)
[![Agents](https://img.shields.io/badge/agents-Claude%20Code%20%7C%20Codex%20%7C%20DSH%20%7C%20OpenCode%20%7C%20Antigravity-8b5cf6?style=flat-square)](#-install)
[![Dependencies](https://img.shields.io/badge/runtime%20deps-none-22c55e?style=flat-square)](#-design-principles)
[![Evidence](https://img.shields.io/badge/verdict-p95%20%2B%20p99%20%2B%20rps%20only-f59e0b?style=flat-square)](#-hard-gates)

</div>

---

AI agents are very good at saying *"I optimized the endpoint, it should be much faster now."*
They are much worse at proving it. `highload-hunt` turns that sentence into a measured verdict:

```
p95  183 ms  ->  92 ms      (target <= 200 ms)
rps  301     ->  318        (target >= 300)
errors 0.20% ->  0.00%      (target <= 0.5%)
```

No baseline, no number, no finding. No reproducer, no fix. No re-run, no claim.

## 🧠 What it does

The skill drives an agent through a fixed protocol: detect the stack, define an SLO, seed production-like data, ramp load in a ladder, find the breaking point, diagnose with profiles and query plans, then write a report. Production code changes only after you approve that report.

It writes **explicit, committed E2E performance tests** — not throwaway scripts in `/tmp`. Tests start the real service, seed deterministic data, generate load at a fixed arrival rate, assert p95/p99/error/throughput bounds, and fail the build on violation.

```mermaid
flowchart LR
    A[0 Detect<br/>stack] --> B[1 SLO +<br/>load model]
    B --> C[2 Baseline<br/>+ correctness]
    C --> D[3 Ladder<br/>10/50/100/150%]
    D --> E[4 Observe<br/>profiles, DB, CPU]
    E --> F[5 Diagnose<br/>defect catalog]
    F --> G{6 Report<br/>user gate}
    G -->|approved| H[7 Fix<br/>re-run identical]
    G -->|report only| I[Done]
    H --> J[8 Regression test<br/>+ CI]
```

## 🚧 Hard gates

The whole point is what the agent is **not allowed** to do.

| Gate | Rule |
|:----:|------|
| **G1** | No verdict without baseline + load + repeat runs |
| **G2** | Load tests live in `tests/perf/` in the repo, not `/tmp` |
| **G3** | Every finding has a reproducer, a metric, and a mechanism |
| **G4** | Report first, code second — fixes need your explicit approval |
| **G5** | A fix is proven by an identical re-run: same seed, rate, dataset |
| **G6** | Forbidden shortcuts: `sleep` as throttle, mocked DB, p95 from 10 samples, one-run comparisons, SLO moved mid-hunt |
| **G7** | Exit is *SLO met* or *accepted risk* — never "looks fine" |
| **G8** | Every fixed defect leaves a regression test that fails on the old code |

> A perf test that passes because it never checked the response body is worse than no test.
> Correctness is asserted under load, not just status codes.

## 📦 What you get

```
tests/perf/
├── README.md                  # how to run each test
├── thresholds.ts              # one source of truth for the SLO
├── seed.ts                    # deterministic dataset, fixed seed
├── api.items.load.test.ts     # HTTP load at fixed arrival rate
├── db.items.concurrency.test.ts
├── journey.checkout.e2e.spec.ts
└── results/                   # raw JSON artifacts, gitignored
PERF-REPORT.md                 # verdict, metrics, ranked findings
```

Each finding in the report looks like this:

> **F1: list endpoint does N+1 queries per item**
> Reproducer: `tests/perf/api.items.load.test.ts` — `npm run perf:items`
> Metric: p95 640 ms → 210 ms expected at 300 rps; DB calls 41 per request
> Evidence: `pg_stat_statements` top query, 54k calls in the 100% run
> Mechanism: serializer awaits `item.owner` inside a `for` loop
> Fix direction: prefetch owners with one `IN (...)` query

## 🚀 Install

Clone once, link into every harness you use. Symlink mode means `git pull` updates all of them.

```bash
git clone https://github.com/Yarfer800/highload-hunt.git
cd highload-hunt
./install.sh --list        # see detected harnesses and target paths
```

| Harness | Command | Target |
|---------|---------|--------|
| **Claude Code** | `./install.sh --host claude` | `~/.claude/skills/highload-hunt` |
| **Codex** | `./install.sh --host codex` | `~/.codex/skills/highload-hunt` |
| **DeepSeek Harness** | `./install.sh --host dsh` | `~/.dsh/skills/highload-hunt` |
| **OpenCode / ECC** | `./install.sh --host opencode` | `~/.config/opencode/skills/highload-hunt` |
| **Cross-host** | `./install.sh --host agents` | `~/.agents/skills/highload-hunt` |
| **Antigravity / Gemini** | `./install.sh --all` | `~/.antigravity/skills`, `~/.gemini/skills` + `AGENTS.md` snippet |
| **This repo only** | `./install.sh --project .` | `./.agents/skills/highload-hunt` + `./.claude/skills/highload-hunt` |

Other flags: `--mode copy` (no symlink), `--force` (replace existing), `--dry-run`, `--uninstall`, `--no-commands`.

The installer also wires a slash command where the harness supports custom commands: **Claude Code** (`~/.claude/commands`), **Codex** (`~/.codex/prompts`), **OpenCode** (`~/.config/opencode/commands`). Harnesses that read `AGENTS.md` instead of a skills directory get a ready block printed by the installer:

```markdown
## Highload performance hunts
When asked to load-test, stress-test, benchmark, or explain slowness under
traffic, read ~/.agents/skills/highload-hunt/SKILL.md and follow its phases
and hard gates. Report first; do not change production code before approval.
```

## ⌨️ Slash command

Installed next to the skill where supported (`/highload-hunt`):

```
/highload-hunt GET /api/items --rps 300 --slo-p95 200 --slo-p99 500
/highload-hunt --tier S --report-only
/highload-hunt checkout flow, 500 concurrent users
```

Arguments are freeform: the command loads `SKILL.md`, runs preflight, then the protocol. With no arguments it treats the project as the target and asks for the production peak rate and latency expectations.

| Harness | Command file | Invocation |
|---------|--------------|------------|
| Claude Code | `~/.claude/commands/highload-hunt.md` | `/highload-hunt` |
| Codex | `~/.codex/prompts/highload-hunt.md` | `/highload-hunt` |
| OpenCode | `~/.config/opencode/commands/highload-hunt.md` | `/highload-hunt` |
| DSH, Antigravity, Gemini | skill only | natural language trigger |

## 🔬 Worked example

`examples/demo-api` is a zero-dependency Node server with one real defect: a full scan over 200,000 items on every detail request. `examples/report.md` is the report the skill produced, with measured numbers.

```
before fix   100 rps:  p50 130 ms   p95 377 ms   p99 422 ms
after fix    100 rps:  p50  18 ms   p95  80 ms   p99  85 ms
                     -86%          -79%          -80%
```

Reproduce it in about a minute:

```bash
bash examples/demo-api/run.sh          # ladder before/after, delta, regression test
cat examples/demo-api/results/delta.md
```

The report also records what the hunt ruled out (serialization, generator saturation, client pool size) and what it did not test (writes, datastore, soak). That honesty is part of the protocol.

## ⚡ Quick start

Once installed, just ask. The skill triggers on the intent, not on a magic command.

> **You:** Why does `GET /api/items` stall at around 200 rps? Load-test it properly and find the bottleneck.

Then the agent:

```bash
bash scripts/perf-doctor.sh --json .            # facts, not guesses
bash scripts/ladder.sh --runner k6 \
     --script tests/perf/k6/items.js --rps 300 \
     --levels 10,50,100,150 --repeat 3 --out results/ladder
bash scripts/perf-diff.sh --before results/before/normalized \
     --after results/after/normalized --level 100 --p95 200 --rps 300
py-spy record -o profile.svg --pid <pid> --duration 30
bash scripts/perf-verify.sh --dir . --runs 3
```

...and returns `PERF-REPORT.md` with a verdict, not adjectives.

Gate a run by hand at any time:

```bash
$ bash scripts/slo-gate.sh --file tests/fixtures/k6-summary.json --p95 200 --p99 500 --err 0.5 --rps 300
slo-gate: tests/fixtures/k6-summary.json (tool=k6)
  metric         measured       threshold     verdict
  p95            186.734ms      200ms         PASS
  p99            405.882ms      500ms         PASS
  error rate     0.180%         0.5%          PASS
  rps            301.190        300           PASS
  samples        50815          >= 200        PASS
slo-gate: PASS
```

Fixtures are captured from real tool output, not handwritten shapes: k6 `--summary-export`, locust `--csv`, autocannon `-j`, ab text, vegeta JSON, ghz JSON. `normalize-result.py` maps all of them into one schema, so the gate works with whatever the project already uses.

It also fails the run when the **generator** becomes the bottleneck (`dropped_iterations > 0`) or when there are too few samples for the percentile — the two most common sources of fake good news.

## 🗂️ What's inside

| Path | Purpose |
|------|---------|
| `SKILL.md` | The protocol: 8 phases, tiers S/M/L, hard gates, exit criteria |
| `references/load-model.md` | Open vs closed model, Little's law, SLO math, statistics, measurement traps |
| `references/generators.md` | k6, locust, autocannon, wrk/wrk2, vegeta, ghz, queue load |
| `references/in-process-load.md` | Concurrency tests for Node, Python, Go, JVM: pools, stampede, leaks, locks |
| `references/e2e-test-anatomy.md` | How to write the explicit perf E2E test and wire it into CI |
| `references/defect-catalog.md` | 32 symptom → mechanism → fix rows: N+1, missing index, pool exhaustion, stampede, lock convoy, retry storm, leaks |
| `references/profiling.md` | py-spy, 0x/`--cpu-prof`, pprof, async-profiler, `pg_stat_statements`, locks, cgroups |
| `references/stack-detection.md` | Manifest → stack → runner → entry point, monorepo rules |
| `references/report-template.md` | The report skeleton the agent must fill |
| `templates/` | k6 scenario, locust journey, Node/Python/Go concurrency tests, deterministic Postgres/Python/Node seeds, `ci-perf.yml` |
| `commands/highload-hunt.md` | `/highload-hunt` launcher for Claude Code, Codex, OpenCode |
| `scripts/perf-doctor.sh` | Read-only preflight: stack, run command, datastore, generators, CI, hardware (`--json` supported) |
| `scripts/ladder.sh` | Ladder runner: 10/50/100/150%, repeats, medians, knee detection, gate columns |
| `scripts/slo-gate.sh` | Result file → PASS/FAIL exit code; rejects too few samples and generator bottlenecks |
| `scripts/perf-diff.sh` | A/B series → delta table, medians, spread, per-level comparison, gate verdict |
| `scripts/perf-verify.sh` | Artifact gate: report, verdict, findings with evidence, tests, 3 usable runs |
| `scripts/normalize-result.py` | k6, locust, autocannon, ab, vegeta, ghz → one normalized JSON schema |
| `examples/demo-api/` | Runnable defect target with a regression test and a measured report |
| `tests/smoke.sh` | 45 repository self-checks: syntax, fixtures, gates, install matrix, verify |

## 🧩 Supported stacks and tools

**Stacks:** Node/TypeScript (Next.js, NestJS, Express, Fastify), Python (FastAPI, Django, Flask), Go, JVM, Rust, PHP, .NET.
The agent detects the manifest and picks the matching runner, profiler, and query stats tool.

**Load:** k6 (default for HTTP SLOs), locust (Python journeys), autocannon (30-second sanity), wrk2 (coordinated-omission-correct tails), vegeta (constant-rate soak), ghz (gRPC), plus direct broker load for workers. `normalize-result.py` reads all of their outputs, so the gate does not care which one a project already uses.

**Test runners:** vitest/jest/Playwright, pytest, `go test -tags perf`, JUnit/JMH. All perf tests are tagged so normal CI stays fast.

## 🎚️ Tiers

Not every question needs a two-day hunt.

| Tier | Scope | Time box |
|:----:|-------|----------|
| **S** | One endpoint or query | 30–60 min |
| **M** | One service, realistic read/write mix | 2–4 h |
| **L** | Multi-service journey, release gate, soak + spike | 1–2 days |

Gates apply at every tier. A Tier S hunt still produces numbers, a test, and a verdict.

## 💡 Design principles

1. **Evidence over vibes.** A latency claim without a sample count is a guess.
2. **The test is the artifact.** A fix that leaves no regression test will regress.
3. **Measure the knee, not just pass/fail.** Passing at 300 rps with a knee at 310 rps is fragile, and the report says so.
4. **Realism beats volume.** Production-like data cardinality exposes the missing index; 10k rows do not.
5. **Report before rewrite.** The user decides what gets changed, with the cost in front of them.
6. **Zero runtime dependencies.** Bash, a JSON parser, and whichever generator the project already trusts.

## ❓ FAQ

**Does it need k6 installed?**
No. It picks from what is available (`k6`, `locust`, `autocannon`, `wrk`, `vegeta`, `ab`) and says which one it used. `slo-gate.sh` needs only `bash` and `python3`.

**Is there a slash command?**
Yes, `/highload-hunt` for Claude Code, Codex, and OpenCode. It is a thin launcher: it loads the skill, runs preflight, and then follows the protocol. Other harnesses trigger the skill from natural language.

**Will it load-test production?**
The protocol targets a local or staging environment. Pointing a generator at production is a separate decision with its own approval, and the skill requires you to say so explicitly.

**Does it change my code automatically?**
No. Default output is `PERF-REPORT.md` plus tests. Fixes happen only after you approve the findings (Gate G4), then each fix is proven by an identical re-run.

**What if the service cannot be started or measured?**
The hunt ends `BLOCKED` with the exact missing piece. The skill forbids inventing numbers.

**Is this a benchmark framework?**
It is a protocol that tells an agent how to use one correctly — plus five scripts that keep it honest and a demo target that proves the scripts work.

**How do I know the scripts themselves are correct?**
`bash tests/smoke.sh` runs 45 checks: parse fixtures captured from real k6, locust, autocannon, ab, vegeta and ghz output, gate pass/fail cases (including the 100%-errors trap and too-few-samples), diff detection, install matrix in a temp HOME, and the demo regression test. CI runs it on every push.

## 🤝 Contributing

Issues and PRs welcome: new defect-catalog entries with a real reproducer, new stack detection rows, additional generator templates. Keep the zero-dependency rule for `scripts/`.

## 📄 License

[MIT](LICENSE) © Yarfer
