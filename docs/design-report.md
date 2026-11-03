# Value Report: task and session value report

`scripts/report.sh` (`sdkit report ...`) automatically reports **what SDKit did in a task and in a session, who did it, what it spent, and what it saved in a demonstrable way**. It is **not** a new telemetry system: it only reads the records the kit already keeps. It makes no LLM calls (pinned by a test: host CLIs on a trapped PATH are never called). Verification: `tests/report.test.sh`.

## 1. What it reuses

| Need | Source | What this feature adds |
|---|---|---|
| Tokens, cache categories, deduplication, price resolution, cost | `usage.sh report --json` (F07) | Only `rows[]` (reconciled runs) and `--as-model M` (the price "if the same run had been on model M"; **the same** price resolver). No other price computation |
| Phase durations, tests, verification, gate refusals, contract result, workflow decision | `telemetry.sh summary --json` (F01) | none |
| Routing decisions (reuse / duplicate / optional-skipped / budget) | `work/<slug>/routing.jsonl` (F06) | none |
| Context views (bytes) | `work/<slug>/context.jsonl` (`digest.sh`, F09) | none |
| Test selection | `work/<slug>/selection.jsonl` | `test-select.sh` now writes one line per run (only counts and seconds; the duration of a cached green run is kept in the cache file) |
| Task/session lifecycle | `sdd.sh advance done`, `sdd.sh abort [failed\|blocked\|partial]`, `SessionEnd`/`SessionStart` hook | `hooks/value-report.sh` |

Storage: `<project-dir>/work/_reports/` (personal, outside git): `task/<slug>@<run>.json`, `session/<id>.json`, `index.jsonl` (one line per report), `sessions.jsonl` (session end signals). Markdown and text outputs are **generated from the JSON every time** and not stored separately. A report contains no prompt, transcript, file content or path; only identifiers, roles, models, counts and reason codes. A typical report is a few KB.

## 2. When it is produced

| Event | Trigger | Output |
|---|---|---|
| Task completed | `sdd.sh advance done` | compact report to stderr; `completed` |
| Task ended but not finished | `sdd.sh abort` → `aborted`; `abort failed` / `abort blocked` / `abort partial` | same; the status is stated explicitly |
| Session ended | Claude Code `SessionEnd` hook (the real end signal) | session summary is stored (`ended`) |
| Session cut off without a signal | `recover` at the next `SessionStart`: old sessions that have a record but no end signal | summary is stored, **`interrupted`** (never called finished). `report regenerate session ID` refreshes it later |

`VALUE_REPORT=on` (`sdkit.local.env`, comes from the template in new installs; empty = off, silent). The commands (`sdkit report ...`) work regardless of the setting. **Once only:** `finalize` writes the report once for the same `slug@run`; a second call says "already exists" and leaves the file untouched (`--force` rewrites). A report failure does not affect the task: `finalize`, `session-end` and `recover` always exit 0; output goes to stderr and does not mix into the tool's own output or the contract/verdict parsing.

Status: `completed | failed | blocked | partial | aborted`; the live view of an open task is `in-progress` (not stored, says "not terminal"). If `completed` was requested but an agent result is `partial/blocked/failed`, the report says **`partial`** (`status_requested` is still `completed`). A failed task is never described as successful.

## 3. Commands

```
sdkit report task [slug|latest] [--run ID] [--detailed|--json|--markdown]
sdkit report session [id|latest|current] [--detailed|--json|--markdown]
sdkit report latest [--detailed|--json|--markdown]
sdkit report history [--json]                 # every stored report, one line (history comparison)
sdkit report regenerate task|session ID       # rebuild from the records (status is kept)
```
`scripts/report.sh` also runs directly. `--json` is machine-readable (`schema: value-report/1`), `--markdown` gives the full tables of sections A–D, the default is compact, and `--detailed` additionally gives the method table, "why it ran", verification and warnings.

## 4. Measured and estimated

| Value | Kind |
|---|---|
| Token categories (in, out, cache_read, cache_write), run count, duration, test/verification result | **measured** (the record the host wrote). A run that cannot be measured is `unavailable`/`N/A`, **not 0** (`tq: unavailable`); the total is marked as a lower bound |
| API-equivalent cost | **estimate**: tokens × `pricing.json`. Not an invoice; `billed` is always "unavailable" |
| Number of avoided executions (reuse, duplicate, optional-skipped) | **measured count** (routing decision) |
| Tokens/cost of an avoided execution | **estimate**, only if a defensible comparable run exists |
| Routing savings | **estimate** (counterfactual) |
| Test selection | measured count and cache duration; the duration of skipped suites is **not measured**; no token claim |
| Context optimization | **heuristic** (~4 bytes/token), **not included** in the savings ratio |
| Budget / workflow enforcement | **qualitative**: number of recorded decisions and refusals, no dollar claim |

Only **observed** optimizations are listed; a feature being on does not by itself count as savings. A cache read is not an SDKit saving (it is a provider feature): in the cost section it is given on a separate "prompt caching" line, is not included in the savings ratio, and does not count as newly produced tokens.

## 5. Savings methodology

Order of evidence: (1) a comparable real run without SDKit, (2) previously recorded similar runs, (3) an explicitly defined counterfactual, (4) a clearly labelled heuristic, (5) **N/A**. The current kit has no (1); what is used is (2) and (3).

**Tokens** (only from avoided executions):
- Avoided execution = routing decision `reuse` (`EVIDENCE_REUSED`), `DUPLICATE_COMPLETED/IN_FLIGHT` or `OPTIONAL_SKIPPED`.
- Comparable run: first the measured runs of **the same role in the same task** (confidence: medium), otherwise the runs of the same role in **earlier stored reports** (low). If neither exists, the execution is counted but not priced.
- `fresh tokens = in + out + cache_write` (cache reads excluded; the same definition as `usage.sh budget`). Baseline = actual fresh + estimated fresh of the avoided; `ratio = (baseline − actual) / baseline × 100`. Baseline and actual have the same scope (the task). If no execution can be priced: "N/A — insufficient baseline data".
- Routing does not change the token count (it changes its price), so it does not enter token savings. **No** token value is assigned to shell-script work.

**Cost** (not mixed with tokens, a separate percentage):
- Routing: `REPORT_BASELINE_MODEL` (`sdkit.env`, a model ID in `pricing.json`; **N/A if empty**, the kit makes no assumption). The **same tokens** of every non-orchestrator, measured, priced run are priced on the baseline model with `usage.sh --as-model`; `delta = Σ(baseline cost − actual cost)`. A run on the baseline model contributes 0; a **run on a more expensive model** contributes a negative amount (the regression is shown, not hidden). Confidence: low (a different model may not produce the same number of tokens).
- Cost of avoided executions: the average cost of the comparable runs × the count (only if all are priced).
- `baseline cost = actual priced cost + routing delta + avoided`; `savings = baseline − actual`; `ratio = savings / baseline × 100`. Unpriced runs are left out and stated on the scope line ("3 of 4 run(s) priced").
- Every saving comes with: baseline source, method, scope, confidence, and the measured/estimated distinction.

## 6. Preventing double counting

All numbers come from the reconciled rows of `usage.sh`: the key is `(execution ID, model)`; a snapshot does not overwrite a final, a smaller read does not overwrite a larger. Writing the same run twice, or a nested agent appearing again in the main session, is a single run. The session summary does **not sum** task reports; it filters ledger lines by session ID, so a task spanning several sessions is split across sessions but none is counted twice. Avoided executions are summed only from tasks entirely inside that session; spanning tasks are noted in the summary.

Role and physical run are separate: in the table it is `role (kind)`, where the kind is `orchestrator` (main session), `subagent` (delegated agent) or `host-agent` (a separate host process via `run-role.sh`; its ID is `rr-…`). If the same role ran on two models there are two rows; the run count is by unique ID.

## 7. Limits

- The counterfactual is an estimate: it assumes the baseline model would have used the same tokens for the same work. Confidence is written as "low".
- If `REPORT_BASELINE_MODEL` is empty, routing savings are N/A; the kit does not invent a default model.
- Routing decisions count as avoided executions only when recorded (`--reserve`, `ROUTING=on`); work skipped on an undecided path is not visible.
- Codex, OpenCode and Cursor do not report tokens: the report counts them as `unmeasured`, and cost/savings are a lower bound (the F07 limits apply as they are).
- The session end signal exists only in the Claude Code `SessionEnd` hook. On other hosts the session report is requested with `sdkit report session ID`; the `running`/`interrupted` states say there is no end signal.
- The `SessionEnd` output may not be shown to the user; the summary is stored in every case and is read with `sdkit report latest`.
- If `work/<slug>` is deleted, the records are in the archive (`telemetry.sh archive` now also copies the routing/context/selection files); without an archive, `regenerate` leaves the stored report intact.
- "Changed files" is `git diff <base>` plus untracked files; if it comes out empty after a merge, it is `N/A`.
- Because the duration of skipped suites in test selection is never measured, time savings are reported only for green runs reused from the cache.

## 8. Overhead

A task report: `usage.sh` + `telemetry.sh summary` + `resolve-base.sh` + a few `jq`; the measurement is in the `tests/report.test.sh` output and the handover note. The report is produced only at the end of a task/session, not per tool call.
