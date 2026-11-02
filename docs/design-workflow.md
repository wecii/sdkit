# Deterministic workflow engine (F03)

Status: **implemented**, on 1.1.0, on top of the F00/F00.5/F01/F02 changes; version not bumped, nothing committed. This document is F03's scope, design, decision records and verification record. Goal: which workflow is chosen, how phases are passed, when an agent contract is required and the failure/retry behaviour are decided **by code**, not left to the memory of the model reading `SKILL.md`. There is no new orchestration framework, extra agent call or second state file.

## 1. Current state: what is tied to code and what is not

| Decision | Before F03 | After F03 |
|---|---|---|
| Phase order, no skipping | in code (`sdd.sh`) | same; the table is read with `sdd.sh transitions`, single definition `PHASES` |
| RED (tests **must fail**), GREEN (**must pass**) | in code | same |
| `proposed` entry: DoD list; for high a race/ordering section | in code | same |
| Risk floor (`RISK_FLOOR_GLOBS`) | in code | same |
| Independent verifier PASS for medium/high, tied to the diff fingerprint | in code | same |
| **Process weight (small / normal / strict)** | only `SKILL.md` prose ("you may do small low tasks yourself") | `--profile`, fixed in the task state, validated in code |
| Adding the contract marker to a handoff | only the orchestrator's memory | `workflow.sh require`: the Claude hook and `run-role.sh` ask/refuse where it is required |
| Unanswered / interrupted agent | prose + `contract.sh pending` (nobody asked) | `green` and `verified` gate in high-assurance |
| The **reason** for a refused transition | human text (stderr) | text + `reason` in the `phase.reject` event |
| Stale evidence after `verified` | `gate push` refuses, but the message saying "re-verify, `advance verified`" **could not be followed** (`verified→verified` was refused) | `verified`/`pr` → `verified` re-verification, only if the evidence is stale |
| Two `advance`s at the same time | read-check-write had no lock: both could pass, history was written twice | the write is under a lock and passes only if the phase is still the checked phase; one wins |
| Two `start`s at the same time | both could see "no open task" | check under a lock |
| Retry limit | `state.sh retry` (in code) + "no third loop" (prose) | same; the BLOCK message now says whether the retry has been used |
| Running reviewer / security-auditor (high) | prose | **still prose** (section 9, risk 1) |

## 2. Profiles

A profile is **process weight**, risk is **gates**. The user confirms the risk; the profile is proposed with it. Both are written by `sdd.sh start` and do not change during the task (like the risk label): a profile cannot be lightened mid-task.

| Profile | Rule (in code) | When |
|---|---|---|
| `small` | `low` only; `start` with `medium`/`high` is refused. No contract overhead (at most the project's `CONTRACTS=1`). No mandatory step is skipped: RED/GREEN, risk floor, verify command unchanged | single-file, low-risk work |
| `standard` (default) | today's workflow, bit-for-bit identical. Used if `--profile` is not given | most tasks |
| `high-assurance` | `verified` requires an independent verifier PASS at every risk (low included); contracts are **mandatory** for writing/deciding roles (`developer test-writer devsecops engineer verifier reviewer security-auditor`); an unanswered agent blocks `green`/`verified`. The `CONTRACTS` setting is not needed | irreversible work with security/money/data impact |

Invariants (proven by tests): `small` does not lower the risk floor (`RISK_FLOOR_GLOBS` high path → `green` refused); `high` risk requires the race/ordering section in every profile; `high-assurance` removes no gate, it only adds; a valid contract does not pass `advance verified`. CI side: `ci-check` requires a PASS even at low risk if the attestation has `profile: high-assurance` (only `sdd.sh` writes the attestation).

**Why is `small` only this much?** Honest assessment: the `low` flow is already light; the two things `small` provides in code are (a) protection against a wrong label: `small` + medium/high is impossible, (b) turning off the contract overhead. Things like skipping the plan gate and the analyst would go against the "never skip" guards in `SKILL.md`; they were not added. At prompt level `small` only means "do it yourself in a single session" (`references/workflow.md`).

## 3. Transition policy

The only valid move is to the next phase; going back is only `abort` (it ends the task). Exception: **re-verification** (`verified|pr → verified`), only if `verifiedFingerprint` does not match the current diff, and with the same gates.

```
$ sdd.sh transitions
intake > proposed  proposal.md has a Definition of Done list (high risk: design.md has a race/ordering/timing section)
proposed > red     --test-cmd runs and FAILS
red > green        the tests PASS, the risk floor holds, no agent is still in flight (high-assurance)
green > verified   the risk floor holds; low: the verify command passes; medium/high/high-assurance: an independent PASS for this exact diff
verified > pr      none beyond verified: the push gate already holds the diff to the verified one before a PR exists
pr > done          none (the PR is merged: the user's call)
verified|pr > verified  re-verification, only while the verified diff is stale: the same checks as verified
any > (aborted)    sdd.sh abort; the only way back, and it ends the task
```
No extra condition **was added** to the `pr` entry (it was tried): existing tests drove flows that drop an untracked file into the repo after `verified` through to `pr`; the push gate (`gate push`) already checks that the diff is the verified diff before a PR is opened. Backward compatibility was put ahead of this extra check.

Refused move: the state **does not change**, the reason is written to stderr, and a `reason` lands in the `phase.reject` event. Reasons: `not-next unknown-phase no-artifact no-dod no-design tests-pass tests-fail verify-failed no-verdict verdict-block stale-verdict risk-floor agents-pending out-of-phase concurrent` (category: `tests` only for a refusal that comes from the test run, `gate` for the rest). `phase.reject` carries only fixed words: no handoff text, test output or path list is written.

## 4. Contract policy (integration with F02)

`workflow.sh contracts --role R` returns `off | optional | required`. Input: the task's profile, the `CONTRACTS` setting, the role. The execution boundary only decides *how it is enforced*.

| Profile | `CONTRACTS` empty | `CONTRACTS=1` |
|---|---|---|
| (no task) | off | optional |
| small | off | optional (never required) |
| standard | off | optional (F02 behaviour, old handoffs pass) |
| high-assurance | **required** (kit roles), optional (`scout`, `analyst`, non-kit agent) | same |

| Boundary | Enforced by | If required and the marker is missing |
|---|---|---|
| Agent tool (Claude Code `PreToolUse` `Agent`) | `check-contract.sh` → `workflow.sh require` | `strict`: **ask**; `guided`: warning; `off`: silent. The hook's own error never blocks |
| Separate process (`run-role.sh`, all hosts) | `run-role.sh` → `workflow.sh require` | `strict`: exit **2**, the agent does not start; `guided`: warning, runs |
| In-session (the orchestrator does it itself) | — | no boundary, no contract |
| Other hosts' hooks (Codex/OpenCode/Cursor/Gemini) | not enforced | an `Agent`-like PreToolUse was not validated on the host (same as F02 §5). Counterpart: `run-role.sh` and the `advance` gates (`agents-pending`) are the same on every host |

Host limits (examined): Claude's `SubagentStop` hook cannot block, it can only add a message; so the answer side still has "report once" behaviour, and since the hook does not know which handoff it belongs to, `--legacy-ok` stays. The real teeth of the requirement are **before spawn** (ask/exit 2) and the **phase gate** (an unanswered agent stops `green`/`verified`). `workflow.sh` writes nothing; `sdd.sh` does not know the word "contract" used in this file (test: `grep -i contract sdd.sh` is empty): `sdd.sh` only asks `workflow.sh gate` "is an agent in flight?", and the gate is only called in `high-assurance`.

**A valid contract does not replace verification**: `verified` still only passes with a PASS written by `record-verdict.sh`/`parse-verdict.sh` and tied to the current diff. Test: in a high-assurance task a valid, `done` verifier contract is recorded; `advance verified` is still refused, there is no verdict record.

No extra agent call: the policy is a script decision. Extra process: only in high-assurance (section 8).

## 5. Failure and recovery policy

The existing `state.sh retry` (one try per id) and `contract.sh close/pending` were reused; no new state file.

| Situation | Behaviour | Where |
|---|---|---|
| Invalid transition | refused, state unchanged, reason `not-next`/`unknown-phase`; no way back except `abort` | `sdd.sh` |
| Missing artifact (proposal, design, `--test-cmd`) | refused: `no-artifact`/`no-dod`/`no-design`; also `no-artifact` if the proposal disappeared at the moment of `verified` | `sdd.sh` |
| Missing/invalid contract | if required, ask/exit 2 before spawn; invalid answer: **one** retry with `state.sh retry <id>`, the second failure goes to the user | hook, `run-role.sh`, F02 |
| Interrupted agent | the handoff stays `issued` → in high-assurance `green`/`verified` stop with `agents-pending`; `contract.sh close <id> --reason interrupted` + single retry (`RETRY-OF:`) | `workflow.sh gate` |
| Retry limit | one per id; a second BLOCK/failure stops the automatic loop and goes to the user | `state.sh`, `references/workflow.md` |
| Blocked verification | `verified` is refused with `verdict-block`; message: single retry if the try is unused, "stop, ask the user" if it is used | `sdd.sh` |
| Stale evidence | `stale-verdict` if the verdict belongs to another diff; edit after `verified`/`pr`: `status` → `evidence=stale`, `gate push` refuses, `advance verified` allows re-verification | `sdd.sh` |
| Concurrent state change | `start`: locked check; `advance`: the phase is compared at write time (`concurrent`) | `sdd.sh` |

Out of scope (F04): redesign of checkpoint/resume. Only the existing `state.sh`/`sdd.sh status` were used here.

## 6. Telemetry (an addition to the F01 ledger, no second ledger)

| Event / field | When |
|---|---|
| `task.start` + `profile` | profile choice (every task; no new event, the event count in the default flow is unchanged) |
| `workflow.decision` (`source=contract-policy`, `outcome=required|optional`, `profile`) | only if the profile is not `standard`, once at the start of the task |
| `workflow.decision` (`outcome=missing-marker`, `role`, `note=boundary=agent|process`, `reason=missing-field`) | if a handoff with a required contract has no marker |
| `phase.enter` | every transition (unchanged) |
| `phase.reject` + `reason` (+ `category`, `phase`, `source`) | every refused transition and gate |
| `retry`, `failure` (`verdict-block`, `contract`, ...) | `state.sh`, F02 (unchanged) |

A `workflow` section was added to the `telemetry.sh summary` output: profile, decisions, `rejections_by_reason`. `validate` rejects an unknown profile and reason. No sensitive data: the fields are fixed vocabulary words and ids.

## 7. Tests (`tests/slow/workflow.test.sh`)

135 cases, all passed: the transition table and every invalid target **from every phase** (state unchanged), every valid transition, reason codes, `start` validation; risk × profile interaction (small + medium/high refusal, risk floor, high-assurance low, high's design requirement); independent verification gates (no-verdict / BLOCK / stale / re-verification, attestation and `ci-check`); role × profile × `CONTRACTS` matrix, hook (ask/guided/off, scout, non-kit agent, valid/invalid handoff), `run-role.sh --dry-run` (exit 2 / warning / old behaviour); a valid contract not passing verification; interrupted agent (`agents-pending`, `close`, single retry, does not block in standard); concurrency (4 simultaneous `start`s → 1, 6 simultaneous `advance`s → 1 event, `_verdict` is not lost); telemetry; old state file (no profile) and partial install without `workflow.sh`.

Run: the `tests/slow/run.sh`, `sdd`, `shared`, `sdkit-dir`, `risk-floor`, `hardening`, `budget`, `memory`, `telemetry`, `contract`, `workflow` suites and `bin/build-adapters.sh --check`: all passed: run.sh 109, budget 45, contract 197, hardening 53, memory 38, risk-floor 76, sdd 52, sdkit-dir 64, shared 29, telemetry 118, workflow 135; adapter consistency up to date.

## 8. Benchmark

`bench/run.sh workflow` (new; F01 fixtures, simulated, no paid LLM call) runs each scenario twice: `standard` and `high-assurance` + contracted handoffs. Script launches are counted by script name with a `BASH_ENV` counter (`bench/call-counter.sh`) (subshells and `jq`/`git` are not counted).

```
scenario                   variant         result   events launches  wf.sh ctr.sh tele.sh sdd.sh
high-independent-verify    standard        done         24       76      0      0     46      9
high-independent-verify    high-assurance  done         35      102      3     12     57      9
low-single-file            standard        done         13       41      0      0     23      7
low-single-file            high-assurance  refused      14       44      3      4     24      6
medium-multi-file          standard        done         15       50      0      0     28      8
medium-multi-file          high-assurance  done         20       64      3      6     33      8
multi-agent-handoff        standard        done         25       86      0      0     53      8
multi-agent-handoff        high-assurance  done         40      120      3     16     68      8
```
Reading:
- **Fit with existing scenarios / default path:** the event counts of the `standard` runs match the pre/post-F02 baseline (24/13/15/25, F02 `overhead` table) and `workflow.sh` is never called (0). The F03 additions on the default path add no script launches: the lock (`mkdir`), the phase comparison at write time (inside the same `jq` call), the `reason` field (same event). All 4 scenarios reach `done`.
- **Extra workload, high-assurance only:** **3** `workflow.sh` launches per task (one `announce`, the `green` and `verified` gates), +1 `workflow.decision` event. The rest of the difference (events +5…+15, `contract.sh` 4…16 calls) is F02's contract cost, not F03's; it shows in these scenarios because high-assurance makes it *mandatory*.
- `low-single-file` is **refused** in high-assurance: the scenario has no verifier step, `verified` stops with `no-verdict`. This is not a bug, it is the designed behaviour (independent verification is mandatory even at low).
- Baseline limit: no copy of the pre-F03 code was kept to run separately; the comparison relies on F02's recorded event counts and on the measurement "0 `workflow.sh` calls on the default path". Wall-clock duration was not reported because it is noisy. No token/cost claim; no `--real` run was done (needs approval).


## 9. Remaining risks

1. **Were reviewer/security-auditor run?** At high risk this is still prose: the results of these roles are not recorded in the state file, and the `verified` gate does not look for them. A record (e.g. a `record-review` similar to the verifier hook) and making it mandatory in high-assurance are F04 candidates.
2. **Profile choice is a human/orchestrator decision.** The code prevents going below the chosen profile but does not conclude "this work should have been high-assurance". Projects can tie risk to paths with `RISK_FLOOR_GLOBS`; a floor tying the profile to paths was not added (complexity). There is no fixed default profile setting for a team (`SDD_PROFILE`): if `small` were the default, medium tasks would fail at start.
3. **No pre-spawn enforcement on other hosts** (Codex/OpenCode/Cursor/Gemini hooks not validated); outside `run-role.sh` and the phase gates the requirement is prose only.
4. **`SubagentStop` cannot block**: on the required-contract side a missing answer is reported to the orchestrator, not stopped; stopping happens at the `agents-pending` gate and only exists if the handoff is recorded.
5. **`pr` entry**: no extra condition (section 3); the `done` entry is left to the user.
6. The benchmark is a simulation: no token or cost claim; a real run (`--real`) was not done, it needs approval.

## 10. Recommendations for F04

- A record that stores reviewer/security-auditor results in the `sdd.sh` state and looks for them before `verified` at high risk (section 9, risk 1).
- Checkpoint/resume: `state.sh` (`work/<slug>/state.json`) and `sdd.sh` (`.sdd/state.json`) are two files; resume could be combined into a single `resume` command (`sdd.sh status` + `contract.sh pending` + `state.sh show`). This document did not merge them.
- Adding the `workflow.sh policy --json` output to the SessionStart context (`session-context.sh`): the model takes the rule from code instead of reading it every session (one process and ~200 bytes).
- An optional floor tying the profile to a path/label (`PROFILE_FLOOR_GLOBS`), only if a real need arises.
