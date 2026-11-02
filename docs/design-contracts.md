# Structured agent contracts and trusted handoffs (F02)

Status: **implemented**, on 1.1.0, on top of the F00/F00.5/F01 changes; the version was not bumped. This document is F02's spec, design, task list and verification record. Goal: the work given to an agent (the handoff) and the answer the agent returns should be structured as far as **the machine can verify**, but without creating extra context, extra agent calls or duplicate state for the agents. Principle: *structured where the machine needs a guarantee, short where the agent needs context.*

This release makes no token or cost savings claim: the simulated benchmark measures only **bytes, events and script calls** (section 7); the token impact cannot be stated until it is measured with a real run (`--real`, user approval), and it was not measured.

## 1. Spec

Scope: a versioned handoff contract (call + result), a single script that validates it (`scripts/contract.sh`), hooking it into the supported boundaries (Claude Code hook, `run-role.sh`), a `contract.check` event in F01 telemetry, contract benchmark fixtures, tests.
Out of scope (deliberately): changes to agent behaviour, model routing, risk policy or the phase machine; validation by an extra agent/LLM; a JSON schema library or an external service; hook claims for Cursor/Gemini/OpenCode/Codex that are not verified live.

Acceptance criteria (DoD) and their evidence (`tests/slow/contract.test.sh`, 197 cases, all pass; section 8):

| # | Criterion | Evidence section (test) |
|---|---|---|
| D1 | The contract is versioned and documented (`CONTRACT: 1`, `HANDOFF-RESULT/1`); an unsupported version is refused | "malformed output", "handoff validation" |
| D2 | The supported boundaries (Claude hook, `run-role.sh`, `contract.sh` by hand) validate the contract deterministically | "the Claude Code hook", "run-role.sh" |
| D3 | A broken/inconsistent contract can never count as valid: broken JSON/prose, missing field, unknown/duplicate field, role, task, ID, unsafe path, missing artifact, out of scope | "malformed output", "identity", "artifacts of a result" |
| D4 | Success reported by the agent cannot bypass independent verification: a valid contract grants no phase transition and records no verdict | "the verifier stays independent" |
| D5 | Existing gates stay intact: `sdd.sh`, `parse-verdict.sh` and `record-verdict.sh` do not know about the contract | same section (`grep` tests) + existing suites unchanged |
| D6 | Telemetry records contract results (valid/invalid, version, role, ID, status, category, size); no second ledger; missing data is not counted as 0 | "telemetry" |
| D7 | Benchmark fixtures are reproducible; the F01 baseline is bit-for-bit identical | "contract benchmarks" + section 7 |
| D8 | Backward compatibility: a handoff/answer without a `CONTRACT:` line works as before; off by default | "backward compatibility" |
| D9 | Host limitations are documented (section 5) | this document, `references/hosts.md` |

## 2. Reuse of existing capabilities (relative to F00/F01)

| Existing boundary | In F02 |
|---|---|
| `references/handoff.md` (ROLE, TASK, READ, SCOPE, OUT, DONE WHEN, ...) | **This already is the call contract.** No new schema/file: only the `CONTRACT: 1`, `ID:` and fixed `REPLY-END:` lines (and `RETRY-OF:` when needed) are added; the existing lines are validated |
| `parse-verdict.sh` + `record-verdict.sh` (verifier block) | **Untouched.** The single authority on the verdict. The contract validates only the envelope (identity/role/status) and does not look at DOD/VERDICT |
| `sdd.sh` (phase, gate, verdict binding) | **Untouched.** The word `contract` does not appear in this file (test) |
| `state.sh retry` (single retry) | The same single chance applies to an invalid/incomplete contract; a second retry goes to the user |
| `check-writes.sh` (scope: file or directory prefixes) | The same prefix rule for artifact scope (`in_scope`); the real write check is still in `check-writes.sh`/git hooks |
| `telemetry.sh` (`events.jsonl`, `q` quality label, failure categories) | New event type `contract.check` + `failure/contract`; same file, same `errs` schema |
| `run-role.sh` (separate-process execution point) | On a contracted handoff, `issue` before the call and `check-result` after; `close` on a host error |
| `hooks/guard-budget.sh` (PreToolUse Agent) | `check-contract.sh` was added to the same matcher group; not a separate mechanism |
| `bench/` | New scenarios in the same driver; `--contracts` and `overhead` commands |

No new state file; only `work/<slug>/contracts/<label>.json` (one small record per ID: role, scope, status). This is the "was this handoff issued, was it answered" information, which is kept nowhere else; git state, the SDD phase, token data and verification evidence are **not copied**.

## 3. Design

### 3.1 Choice of format: three candidates

| Candidate | Assurance | Compatibility | Cost | Decision |
|---|---|---|---|---|
| JSON result **file** (`out/<id>.result.json`) | high | **weak**: read-only roles cannot write files (reviewer, verifier, scout); extra tool call | extra write + read | Rejected: it abandons the most reliable channel, the answer text |
| JSON payload inside the answer | high | good | escape characters, multiple lines; risk of LLM JSON syntax errors; hurts prose readability | Rejected |
| **One-line marker** (`HANDOFF-RESULT/1 \| key: value ...`) | sufficient (fixed fields, strict parsing) | **best**: the final text, present on every host and in `last_assistant_message` | ~120 bytes | **Chosen**: humans can read it, `awk`/bash parse it, no jq needed |

The existing `parse-verdict.sh` is the proven form of the same approach (text block + strict parser).

### 3.2 Call contract

```
ROLE: developer     RISK: medium     PROJECT-DIR: .sdkit
CONTRACT: 1
TASK: ...                         # goal
READ: plan.md,src/a.sh            # inputs: existing, repo-relative paths (comma-separated, no prose)
SCOPE: writes: src/,docs/x.md     # allowed write scope; `none` for read-only roles
OUT: work/t1/out/dev-a.md         # expected output (under work/<task>/out/)
ID: t1/dev-a                      # <task>/<label>: run ID
REPLY-END: one line "HANDOFF-RESULT/1 | id: <ID> | role: <ROLE> | status: ... | artifacts: ... | blockers: ... | next: ..."
RETRY-OF: t1/dev-a                # only on a retry
```
`CONTRACT:` is a fixed line (cache prefix); `ID:` changes on every issue (close to the end). Task ID = the first part of `ID` (compared with the active task); the run ID is added automatically in telemetry (`run`). Constraints stay as prose in the `DONE WHEN` / `NOT YOUR JOB` lines: the machine does not validate them, the agent reads them.

### 3.3 Result contract

`HANDOFF-RESULT/1 | id: t1/dev-a | role: developer | status: done | artifacts: src/a.sh | blockers: none | next: -`

| Field | Rule |
|---|---|
| version | `/1`; `malformed` if it is not a number, `unsupported-version` if it is another number |
| `id`, `role`, `status`, `artifacts`, `blockers` | required, cannot be empty (write `none`); `next` is optional |
| `status` | `done` `partial` `blocked` `failed` (**there is no "verified" status**) |
| consistency | `done` ⇔ `blockers: none`; `partial/blocked/failed` require a blocker |
| `artifacts` | `none` or comma-separated paths: safe, existing, within `writes:` (or `OUT`); a read-only role must say `none` |
| length/characters | `blockers`/`next` ≤ 200; no `\|` inside a value; unknown or duplicate fields are refused |
| single line | one (distinct) marker per answer; more than one distinct line is ambiguous |

### 3.4 Validation categories

`no-result` `malformed` `unsupported-version` `missing-field` `bad-value` `inconsistent` `id-mismatch` `role-mismatch` `task-mismatch` `unknown-id` `duplicate` `stale` `unsafe-path` `missing-artifact` `out-of-scope`. The output is one line: `CONTRACT=valid|invalid stage=handoff|result id=.. role=.. [status=..] [reason=..: detail]`.
Exit code (the same triple as `parse-verdict.sh`): **0** valid and `done`, **1** valid but `partial/blocked/failed`, **2** invalid. Exit 0 never means "verified".

### 3.5 Record and lifecycle

`issue` records the ID as `work/<slug>/contracts/<label>.json` (exclusive create: the same ID cannot be issued twice). States: `issued → accepted` | `invalid` (can be resubmitted) | `superseded` (a new one was issued with `RETRY-OF`) | `interrupted` (`close`). A second valid answer to the same ID is `duplicate`; a late answer to a superseded/dead ID is `stale`; an ID that was never issued is `unknown-id`. Since acceptance is a "check and write" under a lock, exactly one of eight concurrent identical answers is accepted (test).

### 3.6 Verification independence (D4/D5)

Four concepts stay separate and are kept in separate places:

| Concept | Where | Relation to the contract |
|---|---|---|
| Contract validity | `contract.sh` (this feature) | only the envelope: format, identity, role, path |
| Execution result | `status` in the result line | the agent's claim; not evidence |
| Test evidence | `sdd.sh advance red/green --test-cmd` (runs the tests itself) | untouched |
| Independent verification | `parse-verdict.sh` / `record-verdict.sh` / `sdd.sh advance verified` | untouched; a verdict is recorded without a contract too, and a verdict is required even when the contract is valid |
| Workflow completion | `sdd.sh` phases | `contract.sh` does not call the phase machine, `_verdict` or `parse-verdict` (test) |

`next:` is only suggestion text; no script runs it.

## 4. Boundaries and integration

| Boundary | What it does | Does it block? |
|---|---|---|
| `hooks/check-contract.sh`, PreToolUse `Agent\|Task` (Claude Code) | If `tool_input.prompt` contains `CONTRACT:`, runs `contract.sh issue` (validate + record). If invalid: **ask** in `strict`, a warning in `guided`, silent in `off` | only `ask`; a hook error never blocks |
| `hooks/check-contract.sh`, SubagentStop (Claude Code) | Validates the last message (otherwise the last text of the transcript) with `check-result --record --legacy-ok`; if invalid, a `systemMessage` to the orchestrator | no; independent of the verdict path |
| `scripts/run-role.sh` (any host) | If `CONTRACT:` is present, `issue` before the call (invalid: exit 2, **the agent is not started**, the budget is not counted), then `check-result`; the answer is still printed/stored. Exit 4: broken contract, 5: valid but `partial/blocked/failed`; `close` on a host error | yes (exit code) |
| `contract.sh issue / check-result / pending / close / status` by hand | For the orchestrator on hosts without hooks | — |

When it is off (`CONTRACTS` empty, no `CONTRACT:` line), none of these does anything; the `run-role.sh` prompt is byte-for-byte identical (the extra sentence appears only on a contracted handoff, test).

### Research findings about Claude Code (none of them made up)

- The `Agent` tool's input was seen as `{description, prompt, subagent_type}` in real transcripts; so the PreToolUse hook can see the handoff (`prompt`).
- In the repo and in the transcripts at hand, **no shared ID linking** PreToolUse(`Agent`) and SubagentStop was seen (SubagentStop has `agent_id`, `agent_type`, `last_assistant_message`, `agent_transcript_path`; PreToolUse has `tool_use_id`). So the match is made not through host metadata but through **`ID:` in the handoff and `id:` in the answer**. If the answer has no marker, the hook counts it as a finding only if there is a pending (`issued`) handoff for that role; otherwise it is an old (uncontracted) call and the hook stays silent. Concurrent contracted and uncontracted agents in the same role can produce a false warning in this case (warning only).
- Can the `ID:` be read from the first user message of the subagent transcript? **Could not be verified** (no subagent transcript at hand); not used.
- The SubagentStop hook's field names rely on the same assumptions as the existing hooks in the repo (`record-verdict.sh`, `usage-log.sh`); **this F02 hook was not run in a live Claude Code session**, and the tests feed the hook sample JSON.

## 5. Host compatibility status

| Host | Call validation | Answer validation | Status |
|---|---|---|---|
| Claude Code, `Agent` tool | PreToolUse hook (`check-contract.sh`) | SubagentStop hook | Tested with sample hook JSON; **not verified live** |
| Claude Code, `run-role.sh --host claude` | `run-role.sh` | `run-role.sh` (from the `result` JSON) | Tested with a stub host; no live CLI |
| Codex, OpenCode, Cursor, Gemini — `run-role.sh` | `run-role.sh` | `run-role.sh` | Tested with a stub host (codex format included); live CLI flags **not verified**, as in F00 §8.8 |
| Codex, OpenCode, Cursor, Gemini — the host's own subagent | none | none | The kit has no subagent result hook (`adapt.sh` only translates tool calls; the OpenCode plugin does not carry the contract hook). **Safe fallback:** the orchestrator calls the `contract.sh issue/check-result` commands by hand (`references/contract.md`) or opens the role as a separate process with `run-role.sh` |
| Other | — | — | Playing the role in the main session: again by hand |

## 6. Telemetry integration (reuse of F01)

New event type `contract.check` (same `events.jsonl`, same `errs` schema, no second ledger), new fields `contract` (label), `stage` (`handoff\|result`), `status` (`done/partial/blocked/failed`), `reason` (15 categories), `bytes`, `cv` (contract version); `role`, `source`, `task` and the run ID (`run`) are existing fields. On an invalid result, also `failure` + the new category `contract`. `summary`/`render` produce a new `contracts` section (checks, valid/invalid, category distribution, agent status, handoff/answer bytes, version); with no contract events at all, the output does not change.

- Text, prompts and blocker descriptions are **not recorded** (test): only the ID label, role, category, status and byte count.
- `bytes` is the real value measured locally (the shell drops the trailing newline, so it can be off by 1-2 bytes). Token/duration fields are not in this event; missing tokens are never counted as 0 anywhere (the F01 rule, unchanged).
- When it is off (`TELEMETRY` ≠ 1), the contract works and no event file is created (test).
- Validation latency is **not** in the event (macOS `date` gives no milliseconds); `bench/run.sh overhead` measures it.

## 7. Benchmark: against the F01 baseline (simulated; no token/cost claim)

Baseline integrity: the `deterministic` part of the `bench/run.sh run all` output taken before the F02 changes is **bit-for-bit identical** to the one taken after them (4/4 scenarios, equal digest checksums).

**Five contract fixtures** (`bench/run.sh run contracts`, GROUP=contract; `run all` still covers only F01's four scenarios):

| Fixture | What it tests | Result (same in two runs) |
|---|---|---|
| `contract-valid-single` | a valid single handoff | 1 handoff, 1 answer, 0 invalid; completed |
| `contract-invalid-handoff` | dev-a's handoff is incomplete (no `SCOPE`): refused **before the agent starts** (`missing-field`), fixed and reissued; dev-b's answer has no marker (`malformed`) and is fixed by the single retry (new ID + `RETRY-OF`); independent verifier PASS | 2 invalid (`malformed`, `missing-field`), 1 retry, `failure/contract` 2; completed |
| `contract-multi-chain` | 7 agents, all contracted; later handoffs name earlier outputs in `READ` (the artifact chain is validated); reviewer+verifier on another host | 7 handoffs, 7 answers, 0 invalid; completed |
| `contract-interrupted` | the agent process crashes (exit 7); the ID is closed as `interrupted`, the single retry succeeds | `host-error` 1, `no-result` 1, 1 retry; tokens measured in 1/2 runs (the crashed run is not counted as 0); completed |
| `contract-verifier-evidence` | the verifier handoff contains only the artifacts/diff base (**no implementer output**); its contract is valid, and the verdict is decided separately by `parse-verdict.sh` | PASS comes only from the verdict; completed |

**Overhead, F01 scenarios with/without contracts** (`bench/run.sh overhead`, deterministic columns):

| Scenario | Agents | Handoff bytes (plain → contracted) | Answer bytes (plain → contracted) | Events (plain → contracted) | `contract.sh` calls |
|---|---|---|---|---|---|
| low-single-file | 1 | 293 → 456 | 29 → 154 | 13 → 15 | 2 |
| medium-multi-file | 2 | 879 → 985 | 209 → 482 | 15 → 19 | 4 |
| high-independent-verify | 5 | 2934 → 3085 | 649 → 1334 | 24 → 34 | 10 |
| multi-agent-handoff | 7 | 4225 → 4515 | 282 → 1164 | 25 → 39 | 14 |

Reading notes: (a) in a contracted handoff some existing prose lines turn into structured lines, so the "plain → contracted" difference is not only added text; the **fixed** added text is 202 bytes per handoff (`CONTRACT`, `ID`, `REPLY-END`) and typically 119 bytes per answer. (b) The large ratio in answer bytes comes from the fixture answers already being very short (`low`: 29 bytes). (c) 2 `contract.sh` calls per agent (`issue` before the call, `check-result` after), and 1 `telemetry.sh emit` per call when `TELEMETRY=1` (+1 if invalid); extra agent calls are **zero**. (d) In simulation the token columns are fixture values; a token/cost difference **cannot be read** from this table.

**Validation latency** (measured on this machine, varies; not in the deterministic part of the result files): averaged over 100 calls, `contract.sh issue --check-only` ≈ 189 ms, `contract.sh check-result` ≈ 180 ms, and `parse-verdict.sh` ≈ 153 ms for comparison. The time is mostly process start-up cost (CPU ≈ 5%); negligible next to the seconds an LLM call takes, but not zero.

**Real LLM measurement: not done.** All numbers come from fixtures or local script measurements.

## 8. Backward compatibility and migration

- Off by default: `CONTRACTS` is empty (`templates/sdkit.env`, a team setting; `init`/`upgrade` add the new setting to existing files and do not overwrite existing values).
- A handoff without a `CONTRACT:` line is a **legacy handoff**: the `run-role.sh` prompt is byte-for-byte identical, the hook is silent, no record, no event (tests). A legacy answer (no marker) is silent too.
- Consumer review for legacy formats: the only code that reads the handoff is `run-role.sh` (puts the file into the prompt as is) and the bench driver; the only code that reads the answer is `parse-verdict.sh`/`record-verdict.sh` (verifier block). Neither changed. A verifier answer may now carry an extra `HANDOFF-RESULT` line at the end; `parse-verdict.sh` is not affected because it does not look for that line among the `DOD/FINDINGS/VERIFY/VERDICT` sections (test: the same text passes both parsers).
- Structured but broken is never silently accepted: **if** there is a `CONTRACT:` line, the handoff is fully validated; an answer whose marker is missing/broken/duplicated/has unknown fields becomes `invalid`.
- No migration step is needed. To turn it on: `CONTRACTS=1` in `sdkit.env`, and add the three lines from `references/contract.md` to handoffs (the skill knows this when `CONTRACTS=1`). Copy mode: `templates/settings.copy.json` includes the hook; `migrate.sh` added `check-contract` to the hook name pattern.
- Note (a hidden bug found in the F01 driver): `make_handoff` in `bench/run.sh` used `$label` before assigning it, in a single `local` line; the `fix` step's handoff was written to the file of the caller's label. Fixed; the F01 `deterministic` output was not affected (verified).

## 9. Tasks and verification record

| Task | Status |
|---|---|
| T1 `scripts/contract.sh` (issue, check-result, close, pending, status, id) | done |
| T2 boundary integration: `hooks/check-contract.sh` (+ `hooks.json`, `settings.copy.json`, `migrate.sh`), `run-role.sh` | done |
| T3 telemetry: `contract.check`, `failure/contract`, `contracts` summary | done |
| T4 setting: `CONTRACTS` (`templates/sdkit.env`) | done |
| T5 bench: 5 fixtures, `--contracts`, `overhead`, stub host (`fail/`, automatic marker) | done |
| T6 `tests/slow/contract.test.sh` (197 cases) | done |
| T7 docs: this file, `references/contract.md`, `handoff.md`, `hosts.md`, `SKILL.md`, `guide.md`, `cheatsheet.md`, `README.md`, `CONTRIBUTING.md`, `upgrading.md`, `design-telemetry.md` | done |

Checks run: `tests/slow/run.sh` 109, `sdd` 52, `shared` 29, `memory` 38, `budget` 45, `sdkit-dir` 64, `risk-floor` 76, `hardening` 53, `telemetry` 118 (all with the same counts as before F02, none broken), **`contract` 197**; all pass. `bin/build-adapters.sh --check` is up to date (role files not touched). `bash -n` and `jq .` are clean; `shellcheck` is not installed on this machine and was not run.

## 10. Known limits and remaining risks

- **Compliance with the answer format depends on the agent.** The contract *detects* non-compliance; it does not *make* the agent comply. How often real models write the marker correctly was **not measured** (no real run was done). To measure it: `bench/run.sh run <scenario> --contracts --real --host <h> --yes` is **not defined** in this release (`--contracts` is simulated only); adding contracts to a real run awaits a decision before F03.
- The Claude Code hook was not run live (sections 4/5). Matching relies on the `ID` text; reading the ID from the subagent transcript was not verified.
- If an uncontracted and a contracted instance of the same role run at the same time in the hook, a false warning can appear for the answer without a marker (warning only).
- The `READ:` field must be a comma-separated list of paths; prose with explanations gives `unsafe-path`/`missing-artifact`. A file that does not exist yet goes in `SCOPE: writes:`, not in `READ`.
- The scope check compares only the *declared* artifacts with `writes:`; what the agent actually changed is checked by `check-writes.sh` and the git hooks (the agent's claim is not trusted).
- The `bytes` count loses trailing newlines through the shell's `$(...)` (1-2 bytes).
- The validation latency measurement depends on the machine; process start-up dominates.
- Whether the orchestrator actually adds the contract lines to the handoff depends on the skill instruction (the machine does not enforce it); if it does not, the handoff counts as a legacy handoff and stays out of scope.
- No `agent.start` from the subagent transcript (F01 §7, unchanged); this feature does not solve that.

## 11. Proposed next feature

**F03: real-run measurement with contracts, and the compliance rate.** With user approval, (a) F01's real baseline run (not taken yet), (b) the same scenarios with `--contracts`; measured: the marker compliance rate, `invalid` categories, retry cost, the real token difference. The decision depends on that measurement: if the compliance rate is low, the `REPLY-END` text is shortened/given an example, or the contract is made mandatory only for independent roles and parallel writers. Also: live verification of the Claude hook and (if possible) reading the `ID` from the subagent transcript.
