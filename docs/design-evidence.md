# Evidence integrity and high-risk enforcement (F04)

Known limits of F03: at high risk, `reviewer` and `security-auditor` existed only in the prompt; evidence staleness was tracked only for the verifier; `parse-verdict.sh --record` was a path anyone could call by hand. F04 closes these **in code**, with no extra LLM call.

## 1. What is enforced

| Risk / profile | `verified` | `pr` | `done` |
|---|---|---|---|
| low, standard / small | verify command (unchanged) | – | – |
| medium | independent verifier PASS, for this diff (unchanged) | – | – |
| low + high-assurance | verifier PASS (unchanged) | – | – |
| **high** (any profile) | verifier **+ reviewer + security-auditor**, each a PASS from *a registered agent run*, this task, this diff | evidence still valid for this diff | evidence still valid against the verified fingerprint (`verifiedFingerprint`), and no later BLOCK |

The policy lives in one place, `scripts/workflow.sh evidence-roles`; `scripts/sdd.sh` applies the gate (independent of `SDD_MODE`, like the verifier gate). The risk floor (`RISK_FLOOR_GLOBS`) raises the label, and the raised label enters this table; choosing a light profile does not lower the gate.

## 2. Evidence record

In `.sdkit/.sdd/state.json` (no new file):

- `evidence.<role>` = `{result, fingerprint, task, trust, source, run, at, seq}` — the **last** record per role is the valid one; a newer BLOCK always overrides an older PASS.
- `spawns[]` = agent runs that have started but not yet been recorded `{role, source, run, fp, at}` (at most 16).
- `evidenceLog[]` = every attempt (accepted/refused and why; at most 40). For auditing.
- `evseq` = a counter incremented on every accepted piece of evidence (concurrency guard).
- `verdict` = legacy field; written together with the verifier evidence (backward compatibility).

Validity state (`sdd.sh evidence [--json]`): `valid | missing | block | wrong-task | untrusted | stale | conflict`. A stale PASS can never silently pass a gate; re-verification does not reset the task: the roles run again, and the new record replaces the old one.

## 3. Trust: how identity is established

Text the agent writes is **untrusted input**; the role name is not a line in the output. A trusted record (`trust=spawned`) is created only like this:

1. When the run **starts**, the execution boundary opens a registration: `sdd.sh _spawn <role>` (Claude Code: `guard-budget.sh`, `PreToolUse` Agent; other hosts: `run-role.sh` for its own process, with a unique `--run` ID). The registration is bound to the diff fingerprint at that moment.
2. When the run **ends**, that same boundary makes the record: on Claude Code `record-verdict.sh` (`SubagentStop`, the host's `agent_id`), elsewhere `run-role.sh` at the end of the process with `parse-verdict.sh --role <role> --record --source run-role --run <id>`.
3. `sdd.sh _evidence` counts a record as trusted only by **consuming** an open registration: same role, same source, same diff (otherwise `stale-at-record`, if the code changed during the run), and each registration only once.

Consequences: a hand record (`manual`) is kept but does not open the gate at high risk; a host event without a registration becomes `unregistered`; an unregistered `run-role` claim is **refused** (`unknown-run`); the same ID cannot be used for two roles (`role-conflict`); a second submission with the same ID is refused (`duplicate`); a submission in another task's name is refused (`task-mismatch`); evidence arriving after the task has ended is refused (no state file, exit 4). A hand-recorded PASS does not replace a trusted PASS for the same diff; a hand-recorded BLOCK always counts (the safe direction).

On Claude Code, `guard-pr.sh` refuses `sdd.sh _evidence|_spawn|_verdict`, `record-verdict.sh`, `guard-budget.sh` and access to `.sdd/` from the model's shell.

`run-role.sh` does the registration and format checks for reviewer/security-auditor only when the risk is `high` (at lower risk their answers stay free-form; the verifier is registered at every risk). The `bench/run.sh` simulation now takes the verifier verdict from `run-role.sh` (no second hand record), and the high-independent-verify scenario runs all three roles: **at high risk the simulated agent count goes up by 2** (reviewer + security-auditor; these were already in SKILL.md, but the simulation did not model them).

Interrupted run: `run-role.sh` returns the host process's error code, releases the registration (`_spawn-close`) and writes no evidence. A malformed answer, or one `sdd.sh` refuses, exits 6 and writes no evidence.

## 4. Roles and format

Two lines were added to the `reviewer` and `security-auditor` outputs (`SUMMARY` counts and `VERDICT: PASS|BLOCK`). `parse-verdict.sh --role` validates them: the finding line counts must match SUMMARY, there must be a complete `VERDICT`, BLOCKER → BLOCK for the reviewer, CRITICAL/HIGH → BLOCK for the auditor, and `NO FINDINGS` if there are no findings. There is no LLM call.

## 5. Atomicity and concurrency

All writes go through a single `put` under `sdkit_lock` (read-modify-write). A phase transition folds the `testCmd`/`verifiedFingerprint` write into the **same** write as the phase move: an `advance` that is refused or loses a race does not change the state. The attestation is written after the move succeeds. A `verified|pr|done` move is refused if new evidence arrived after the evidence it decided on (`concurrent`, `evseq`).

## 6. Host capability matrix (`workflow.sh capabilities`)

| Path | Contract at spawn | Verdict parsing | Trusted identity | Evidence record | Staleness detection | Completion gate | Error reporting |
|---|---|---|---|---|---|---|---|
| Claude Code (hooks) | asks (`PreToolUse` Agent, only with `CONTRACTS=1`/high-assurance) | automatic (`SubagentStop`) | host `agent_id` + registration | automatic | enforced | enforced (`sdd.sh advance`) | `systemMessage` to the orchestrator |
| `run-role.sh` (any host) | enforced (exit 2, the process does not start) | automatic (when the process ends) | process-owned ID + registration | automatic | enforced | enforced | exit 3/4/5/6 + stderr |
| The host's own subagents (Codex, OpenCode, Cursor, Gemini) | **none** | by hand (`parse-verdict.sh --record`) | **none**: `manual`, refused at high risk | by hand | detected at advance | enforced | refusal at advance |
| Git hooks / CI | none | none | attestation review | from the attestation | `ci-check` | `ci-check` | CI log |

`tests/evidence.test.sh` tests the matrix's claims against the shipped files (e.g. no adapter other than Claude's wires `SubagentStop`/`guard-budget`). In the host's own subagents an execution identity cannot be established; at high risk the gate **stays closed** there: on that host the three roles must be run with `run-role.sh`.

## 7. CI

On an attestation with risk `high`, `ci-check` looks for a record of each of the three roles with `PASS`, `trust=spawned` and a fingerprint matching the one CI recomputes (the attestation carries an `evidence` field). High-risk attestations from before F04 do not carry this field: for a new diff, the task must be verified again.

## 8. Limits (accepted)

- **A process with shell access as the same user can forge any local file, `state.json` included.** F04 prevents accidental and prompt-level self-approval (the agent writing "PASS", calling `--record`, reusing another task's evidence, a stale PASS); it cannot stop a determined attacker locally. `guard-pr.sh` is a regular expression (e.g. an indirect call through a variable bypasses it). Backstop: CI `ci-check` + CODEOWNERS review for `<project-dir>/attestations/`; CI cannot tell a hand-written attestation apart either.
- The `agent_id` field in the Claude Code `SubagentStop` payload relies on the assumption made by the hooks in this repo; **not run in a live session**. If the field is absent, the record becomes `manual` and the gate stays closed at high risk (the safe direction).
- The `run-role.sh` flags are not verified against live CLIs (since F02).
- Whether an agent's answer is *correct* is not verified; only its format, task, role, execution registration and diff are. Content quality is the role's job.
- Parallel runs of the same role on the same diff share a registration; if there is an edit between them, it is refused in the safe direction.

- A registration (spawn) is tied to the role, not the agent: there is no `agent_id` at `PreToolUse` time. So when a role has an open registration **for an old diff**, an incoming record is refused (`stale-at-record`, the roles run again); a "ghost" registration on the same diff, for which no agent ever started, can be consumed by another stop event (accepted limit; on the `run-role.sh` path the registration matches the `--run` ID one to one).
- An independent review (the F04 evaluation) reproduced that the `guard-pr.sh` regular expression can be bypassed by an indirect call through a variable (`S=…/sdd.sh; $S _evidence …`): a process with local shell access can produce trusted evidence. There is no local fix besides CI/CODEOWNERS.

## 9. Cost

At low/medium risk there is **no** new mandatory LLM call. At high risk, `reviewer` and `security-auditor` were already part of SKILL.md §5; F04 makes them impossible to skip and adds no call; valid evidence for the same diff is reused, and a role whose evidence is not stale is not rerun. Overhead: `SKILL.md` +201 bytes, `reviewer` +94, `security-auditor` +176 bytes (only when those roles run); for an independent role spawn, one `git` fingerprint + one `jq` write (~0.3 s on a small fixture); ~70 ms in the hook for other agent spawns. No real token measurement was done.

## 10. F04.1: runtime trust and hardening

**Trust boundary (two categories).** (A) What can be bypassed through agent output and workflow commands (accidentally or at prompt level): code closes it. (B) What needs arbitrary shell/file writes as the same user: cannot be closed locally, and is not presented as "closed" by a regex.

Reproduced attempts and their results (`tests/evidence.test.sh`, "F04.1" block):

| Attempt | Result | Category |
|---|---|---|
| Unregistered `run-role` claim, made-up `rr-…` ID | refused (`unknown-run`) | A, closed |
| `agent_id` present but no spawn registration / no `agent_id` | `untrusted`; `advance verified` refuses at high | A, closed |
| Same ID for two roles; reusing an ID | `role-conflict` / `duplicate` | A, closed |
| Another task's evidence; stale fingerprint; evidence after the task ended | `wrong-task` / `stale` / exit 4 | A, closed |
| Parallel recording and parallel `advance verified` | `state.json` stays valid, the registration is consumed once | A, closed |
| An agent that ends without an answer (interrupted), leaving its spawn registration open | **fixed**: on an empty answer `record-verdict.sh` closes the registration with `_spawn-close --role`; before, the registration made the next real run go to waste with `stale-at-record` | A, fixed |
| `.sdd/` and `attestations/` through `Write`/`Edit` | `guard-protected` refuses | A, closed |
| `sdd.sh "_evidence"` (quoted), `S=…; $S _evidence` | `guard-pr.sh` lets it through | **B**, accepted |
| Writing `state.json` by hand, a forged attestation | cannot be prevented locally; **a forged attestation passes `ci-check`** (for the same diff) | **B**, accepted |

**The CI reality.** `ci-check` recomputes the fingerprint, the risk floor and the flags in CI, but it **reads** the role evidence (`trust=spawned`) from the attestation file; CI cannot reproduce the LLM run. So CI *partially* trusts a locally produced attestation: it only verifies the diff the file names (any later edit invalidates it). The smallest practical measure is process, not code: CODEOWNERS + mandatory review + a protected branch for `<project-dir>/attestations/`; signing infrastructure is not justified for this threat model (the signing key would also sit on the same user's machine). If something stronger is needed, rerunning reviewer/auditor in CI with `run-role.sh` on high-risk PRs (paid, optional) is the only truly independent verification.

**Live Claude Code verification: UNVERIFIED.** A real `Agent` call needs a paid model call; there was no authorization for one. All that was observed is that the schema of the `claude` 2.1.316 binary defines the `agent_id`, `agent_type`, `agent_transcript_path` and `last_assistant_message` fields for `SubagentStop` input (static evidence). The PreToolUse `Agent|Task` matcher is in `hooks.json`. The other host CLIs (codex, opencode, cursor-agent, gemini) are not installed on this machine: their flags are unverified.
