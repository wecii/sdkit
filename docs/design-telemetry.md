# Baseline measurement and telemetry (F01)

Status: **implemented**, on 1.1.0, on top of the F00/F00.5 changes. This document is F01's spec, design, task list and verification record (under `docs/`, like the kit's other design records). The goal is to be able to measure how efficiently **today's** SDKit runs a workflow before changing the architecture. This version makes no savings claim: savings can only be stated from a before/after measurement of the same scenario (`bench/run.sh compare`).

## 1. Spec

Scope: a structured local event log per task, a report that reads it, event writing hooked into boundary points, a repeatable benchmark framework.
Out of scope (on purpose): LiteLLM/proxy, external service or database, dashboard, changes to agent behaviour or model routing, changes to the phase machine.

Acceptance criteria (DoD) and their evidence (`tests/telemetry.test.sh`, all passed; section 6):

| # | Criterion | Evidence section |
|---|---|---|
| D1 | The event schema is defined in one place; an invalid event is not written, a broken line is found by `validate` | "schema and validation" |
| D2 | Every event is tied to a task, a run (`run`) and, where needed, a `span`; a new `task.start` opens a new run | "correlation ids" |
| D3 | Concurrent writes neither lose nor corrupt lines | "concurrent recording" |
| D4 | A value that cannot be measured is not written and is marked `unavailable`, not written as 0; every measurement is `actual/estimated/unavailable` | "missing or incomplete usage data" |
| D5 | A telemetry error does not break the workflow (no jq, unwritable directory, broken/missing script, invalid field) | "failure isolation" |
| D6 | Off by default; while off, existing behaviour and files are unchanged; the token ledger (`usage.jsonl`) does not become a second ledger | "backward compatibility", "off by default" |
| D7 | Prompts, credentials and file contents are not recorded | schema (section 2), test "no prompt-like field" |
| D8 | Benchmark of four representative workflows; a deterministic run is repeatable; a real LLM run only on explicit instruction | "benchmarks" |
| D9 | Local command: summary, status, agent/phase durations, tokens, cost (if a reliable price exists), retries/failures, verification; readable output and `--json` | "the phase machine ..." and bench |
| D10 | The existing test suite passes | section 6 |

## 2. Reuse of existing capabilities (per F00)

| Existing | In F01 |
|---|---|
| `usage.sh` / `usage.jsonl` (token ledger; written by the Claude hook and `run-role.sh`) | **Stays the token ledger.** The `agent.end` event carries the same numbers with a source label; the report shows the `usage.sh` lines separately as a "cross-check" and does not mix them into the totals (no double counting) |
| `sdkit_active_slug` (ADR-0002), `sdkit_lock`, the `env.sh` parser | Task resolution, lock (only for the first `run.id`), reading settings. `sdkit_lock` used to wait forever on an unwritable directory; this was found while testing this feature's failure isolation and fixed (`[ -w dir ] || return 0`) |
| `sdd.sh` phase history (`history`, deleted on `done`) | Events are durable: `phase.enter` records every transition; `archive` copies them before `work/<slug>` is deleted (F00 D6) |
| `state.sh retry/spawn` | `retry` event; an exhausted retry is `failure/verdict-block` |
| `record-verdict.sh`, `parse-verdict.sh` | Verification events: `sdd.sh _verdict` (PASS/BLOCK), hook (malformed) |
| `run-role.sh` (separate-process execution point) | `agent.start/agent.end`, duration, tokens (if the host reported them), `host-error`/`host-missing`/`budget` failures |
| `hooks/usage-log.sh` (Claude SubagentStop/Stop) | `agent.end` from the same transcript read: tokens, **tool call count**, duration (estimate) |

There is no new second logging system: the only new file is `events.jsonl` and the only new script is `scripts/telemetry.sh` (+ the `bench/` developer tool).

## 3. Design

### 3.1 Event model

`<project-dir>/work/<slug>/events.jsonl`, personal and outside git (`work/` is already ignored). One JSON per line; enabled with `TELEMETRY=1` (`sdkit.local.env`). The schema is the single `errs` definition inside `scripts/telemetry.sh`; `emit` and `validate` use the same rule.

| Field | Meaning |
|---|---|
| `v` | schema version, 1 for now |
| `ts` | UTC, second resolution |
| `type` | `task.start task.end phase.enter phase.reject agent.start agent.end retry test.result verify.result failure bench.mark` (+ `contract.check`, F02) |
| `task` | task id (slug) |
| `run` | **run id**: `task.start` opens a new one (`work/<slug>/run.id`); can be supplied from outside with `SDKIT_RUN_ID` (benchmark) |
| `span` / `parent` | ties together one agent run (start+end) and its parent run; the last `agent.end` of the same `span` wins (growing session snapshots) |
| `mode` | `live` or `simulated` (fixture) |
| `phase`, `from`, `to` | workflow phase |
| `role`, `host`, `model`, `tier` | agent; there is **no** provider field: the host does not determine the provider (OpenCode/Cursor are multi-provider), and the kit does not invent model names |
| `in`, `out`, `cache_read`, `cache_write`, `dur_ms`, `tool_calls`, `attempt` | non-negative integers; if unknown, **the field is not written** |
| `q` | measurement quality: `{tokens, duration, tool_calls: actual\|estimated\|unavailable}`; `unavailable` is forced when there is no number |
| `outcome`, `category` | outcome (`pass/fail/PASS/BLOCK/malformed/completed/aborted/ok/error`); failure category `budget gate tests verdict-block verdict-malformed host-error host-missing timeout contract other` (`contract`: F02, detail field `reason`) |
| `source`, `risk`, `note` | producer; risk label; free note of at most 160 characters (fields are truncated so that lines can be appended with a single `write`) |

Privacy: there is no field for the prompt, handoff text, answer, file path or contents; callers do not pass them. `note` is only a short status text (e.g. `exit 7`).

### 3.2 Writing and failure isolation

- `telemetry.sh emit` exits with `exit 0` on every error (no jq, unwritable directory, invalid field: the event is dropped). `--strict` is for tests only.
- Callers additionally wrap it with `>/dev/null 2>&1 || true`; in `sdd.sh`, `state.sh` and `run-role.sh` the `tele` helper does not even start a process while `TELEMETRY≠1`.
- A line is a single `O_APPEND` write (short line, not split); concurrent agents need no lock. The lock is only for the first creation of `run.id`.
- While off, no new file is written; hooks and scripts work as before.

### 3.3 Instrumented boundaries

| Boundary | Events |
|---|---|
| `sdd.sh start/advance/abort` | `task.start`, `phase.enter`, `task.end`, `phase.reject` (category `tests` on red/green, `gate` on the others; phase skipping included), `test.result` (+duration), `verify.result` (low: verify command) |
| `sdd.sh gate` refusal | `phase.reject` (source `gate-edit`/`gate-push`) |
| `sdd.sh _verdict` | `verify.result` (PASS/BLOCK), on BLOCK `failure/verdict-block` |
| `state.sh retry` | `retry`; on the second attempt `failure/verdict-block` |
| `run-role.sh` | `agent.start`, `agent.end` (duration is measured; tokens only if the host reported them), `failure` (`host-error`, `host-missing`, `budget`) |
| `hooks/usage-log.sh` | `agent.end` (Claude: tokens, tool call count, estimated duration) |
| `hooks/record-verdict.sh` | malformed verdict: `verify.result/malformed` + `failure/verdict-malformed` |

### 3.4 Which metric is reliable?

| Metric | Status | Note |
|---|---|---|
| Phase order and durations | **actual** (seconds) | from event timestamps; macOS `date` does not give milliseconds |
| Test result and duration (red/green) | **actual** | `sdd.sh advance` runs them itself |
| Verification result (PASS/BLOCK/malformed) | **actual** | single decision point `parse-verdict`/`_verdict` |
| Retry, gate refusal, failure counts | **actual** | with category |
| Agent count | **actual** on the `run-role` path; on Claude only finished `agent.end`s are counted | no `agent.start` on Claude (the PreToolUse hook only runs while the budget is on) |
| Agent duration | `run-role`: **actual**; Claude hook: **estimated** (first-last timestamp of the transcript) | |
| Tokens (input/output/cache) | Claude (`run-role` and hook): **actual**; Gemini: input/output **actual**, no cache; Codex, OpenCode, Cursor: **unavailable** | the report writes "measured X / Y runs" and says the total is a lower bound if something is missing |
| Tool call count | Claude hook: **actual**; `run-role` path: **unavailable** | |
| Model | only what is configured/seen in the transcript | never invented |
| Cost | **estimated**, only if the user supplies a price table (`<project-dir>/pricing.json` or `TELEMETRY_PRICES`: model → USD per million tokens) | `unavailable` without a table; the kit ships no prices (F00 §7) |
| Retries (host level, network) | **unavailable** | inside the host CLI, invisible |
| Provider | none | see schema |

## 4. Commands

```bash
# enable (personal): .sdkit/sdkit.local.env  →  TELEMETRY=1
scripts/telemetry.sh summary [slug] [--run ID] [--json]   # summary of one run
scripts/telemetry.sh list                                  # tasks with events (archived ones included)
scripts/telemetry.sh validate [slug]                       # schema check
scripts/telemetry.sh archive [slug]                        # before closeout: copy to work/_archive/ (work/<slug> gets deleted)
scripts/telemetry.sh emit <type> [...]                     # by hand / for new boundaries; never fails

bench/run.sh list
bench/run.sh run <scenario|all> [--out DIR] [--json] [--keep]               # SIMULATED (default): free, deterministic
bench/run.sh run <scenario|all> --real --host claude [--verifier-host codex] --yes   # REAL: spends real tokens, by hand only
bench/run.sh compare A.json B.json
```

Price table (F07: versioned v2 format with model/provider/effective date; details in [design-usage.md](design-usage.md) §3). The old flat format is still valid. Example (`pricing.json`; fill the values in from your own contract, the kit provides none):

```json
{ "<model-id>": { "in": 0.0, "out": 0.0, "cache_read": 0.0, "cache_write": 0.0 } }
```

## 5. Benchmark framework

`bench/scenarios/<name>/` holds four scenarios; each runs the real `sdd.sh` phase machine, the real `run-role.sh`, `parse-verdict.sh --record` and `state.sh retry`. In **simulated** mode only the host CLI is a fixture (`bench/stub-host/claude|codex`: copies the files in the step directory, returns the canned answer and the canned token counts).

| Scenario | Risk | What it tests |
|---|---|---|
| `low-single-file` | low | single file, gate = verify command, no verifier |
| `medium-multi-file` | medium | three files, independent verifier PASS |
| `high-independent-verify` | high | test-writer → developer → `verifier-deep`; BLOCK first, single retry, fix, then PASS; race section in the design |
| `multi-agent-handoff` | medium | scout, engineer, test-writer, two parallel developers, reviewer, verifier; handoffs via `out/` files; reviewer+verifier on another host (one that reports no tokens) |

Result file `{scenario, mode, host, deterministic, timing, summary}`. `deterministic` is **bit-for-bit identical** across two simulated runs (verified by a test); `timing` is not. A real run uses the same driver, the same gates and the same report; the only difference is that the roles are live CLIs and the token/duration values are real. A real run is **never** started by `tests/` or CI; it requires `--real` and `--yes` (or a typed `yes`).

## 6. Tasks and verification record

| Task | Status |
|---|---|
| T1 `scripts/telemetry.sh` (emit/summary/list/validate/archive/run-id/now-ms) | done |
| T2 boundary instrumentation: `sdd.sh`, `state.sh`, `run-role.sh`, `usage-log.sh`, `record-verdict.sh` | done |
| T3 setting: `TELEMETRY` (`templates/sdkit.local.env`, personal; `split_personal_env` takes it from the template) | done |
| T4 `bench/` (driver, 2 stub hosts, 4 scenarios, `compare`) | done |
| T5 `tests/telemetry.test.sh` (118 cases) | done |
| T6 docs: this file, `guide.md` (§2, §9, §10, §15, §18), `cheatsheet.md`, `README.md`, `CONTRIBUTING.md`, `upgrading.md` | done |
| T7 fix so `sdkit_lock` does not wait on an unwritable directory | done |

Checks run: `tests/smoke.test.sh` 109, `sdd` 52, `shared` 29, `memory` 38, `budget` 45, `sdkit-dir` 64, `risk-floor` 76, `hardening` 53, **`telemetry` 118**; all passed, none broke. `bin/build-adapters.sh --check` up to date (role files not touched).

### Simulated benchmark results (fixture; NOT a real measurement)

`bench/run.sh run all` (mode `simulated`). The token counts come from fixture files; this table shows **the accuracy of the kit's own counters and reporting**, not SDKit's model cost.

| Scenario | Agents | in | out | cache_read | cache_write | Measured / total runs | Retries | Failures | Events |
|---|---|---|---|---|---|---|---|---|---|
| low-single-file | 1 | 1200 | 300 | 4000 | 500 | 1/1 | 0 | 0 | 13 |
| medium-multi-file | 2 | 8300 | 1820 | 37000 | 2600 | 2/2 | 0 | 0 | 15 |
| high-independent-verify | 5 | 21100 | 4920 | 106000 | 4000 | 5/5 | 1 | 1 (`verdict-block`) | 24 |
| multi-agent-handoff | 7 | 11000 | 2540 | 46000 | 4900 | **4/7** | 0 | 0 | 25 |

The last row is the tested form of the "missing data" path: since three runs (scout and the reviewer/verifier on codex) report no tokens, the total is marked as a **lower bound**.

**Real LLM measurement: not done.** A real run spends tokens and waits for the user's explicit instruction; the framework is ready (`--real`), but no number in this document comes from a real model run.

## 7. Known limits

- Timestamps have second resolution; short phases show as 0 s.
- On Claude only finished agents are counted (no `agent.start`); the `Agent` tool does not pass through a hook while the budget is off. An agent that started and never finished is invisible.
- The Claude hook's duration is an estimate (transcript span); the tool call count is counted from the transcript and is absent on the `run-role` path.
- Codex, OpenCode and Cursor have no tokens (the host does not output them or they are not parsed); Gemini has no cache. The `run-role.sh` output formats of these hosts were not validated live (F00 §8.8).
- `run-role` does not see the host's own internal retries and timeouts; the `timeout` category exists in the schema but nothing produces it (it fills in once F00 R5 `RUN_ROLE_TIMEOUT` is done).
- `usage.jsonl` writes zero (when the host reports nothing); the report's "cross-check" line can therefore show real consumption as a lower bound. The event log separates this as `unavailable`.
- The Claude Stop snapshot and SubagentStop do not share the same `span`; the orchestrator session shows up as a separate "agent" row (`orchestrator`).
- Parsed formats: on the non-host (`parse-verdict.sh --record`) path, the `malformed` event for a malformed verdict is written only by the benchmark driver and the Claude hook; other hosts' orchestrators can write it with `telemetry.sh emit verify.result --outcome malformed`.
- `pricing.json` comes from the user: cost is never "actual", at best "estimated".
- A real run (`--real`) depends on live host CLI flags; the flag spellings were not validated live (check with `run-role.sh --dry-run`).

## 8. Recommendations for F02 (Structured Agent Contracts)

> F02 is implemented: [design-contracts.md](design-contracts.md). Of the items below, 1 (contract version as a separate event field: `cv`), 2 (violation category: `contract`), the bytes part of 3 (`bytes`; simulated comparison with/without contracts `bench/run.sh overhead`) and 6 (single retry: `state.sh retry`) were done; 4 (real baseline run) and the token claim of 3 are **still not done**; 5 was not done (separate decision).

1. **Tie the handoff and answer format to the event.** In F02 let every role contract (input fields, output schema) have a `contract` name/version; let `agent.end` carry it as a separate field instead of in `source`. That answers "how many tokens, how many BLOCKs per contract version".
2. **Make a contract violation a failure category** (`contract`): today an off-schema answer is measured only for the verifier, as `verdict-malformed`; scout/engineer/developer answers are not measured.
3. **Measure the handoff size:** `handoff_bytes` and `answer_bytes` fields (size, not content) are the first step to measuring the token effect of structured handoffs vs. prose before/after. That claim must not be made until it is proven with two runs of the F01 scenarios, with and without contracts (`bench/run.sh compare`).
4. **Record the baseline first:** before F02 starts, take the real baseline run once with `bench/run.sh run all --real --host <h> --yes` (user decision, costly) and keep the JSONs; simulated numbers cannot serve as a comparison baseline.
5. On Claude, the `PreToolUse: Agent` hook for `agent.start` should also run while the budget is off (in a form that only writes the event and never blocks); needed if F02 wants to measure the number of parallel agents.
6. If contracted roles are going to validate `run-role.sh --out` output with `parse-*.sh` and do a single retry on a violation, the existing `state.sh retry` and the `retry` event can be reused.

## F17 — `telemetry.sh trace [slug] [--run ID] [--json]`
The story of one task, in chronological order and joined by ids: task → phase → role/execution (`span`) → usage-ledger row (request-level counts, `ledger(...)`) → routing decision (`decision=rd-…`) → gate result. Only ids, roles, numbers, outcomes and reason codes are printed; **never notes, prompts, answers or file paths**. The last line, `explain:`, names the most recent problem (failure / phase.reject / BLOCK). `--json` is for export; nothing is sent anywhere. `tests/trace.test.sh`.
