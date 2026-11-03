# Architecture and capability audit (F00)

Status: **done, on 1.1.0** (`7919e82`). F00.5 fixed B1, B2, B3, B4, D1, D2, D4 and R1 (see the "Status after F00.5" section); the body of this document describes the state at audit time. Scope: read and measure only; production behaviour was not touched. Source code was the reference; where it contradicts the docs, the code is what is written down.
Each finding carries its **evidence** type: `read` (source line), `executed` (the experiment below) or `unverified` (needs a live host).

Classes: **Implemented** (in the code, tested), **Partial** (present, but with a gap under some condition), **Missing**, **Needs Verification** (cannot be stated without a live install).
Each recommendation is also labelled **Real gap** (behaviour is wrong or the guarantee is empty) or **Optional** (absent, but nobody is harmed).

## 1. Architecture and component map

The kit is not an application; it consists of bash scripts, plain files and generated host adapters. There is no long-lived process at runtime: every hook and script is a short-lived process, and state lives in files.

```
 user      ──► host (Claude/Codex/OpenCode/Cursor/Gemini)
                 │  skill: skills/spec-driven-dev (131 lines) ─ reads ─► references/*.md (256 lines, per step)
                 │  role:  core/roles/*.md ──build-adapters──► agents/, adapters/<host>/agents/
                 ▼
   ┌──────────── decision layer (same rule, 4 entry paths) ────────────┐
   │ hooks/*.sh (Claude) · hooks/adapt.sh (Cursor, Gemini)             │
   │ adapters/opencode/plugins · adapters/git/{pre-commit,pre-push}    │──► scripts/sdd.sh gate  (single decision point)
   │ CI: templates/ci ──► scripts/sdd.sh ci-check                      │
   └───────────────────────────────────────────────────────────────────┘
   state:  .sdkit/.sdd/state.json (phase machine)   .sdkit/work/<slug>/ (state.json, usage.jsonl, notes.md, lookups/, out/)
           .sdkit/attestations/<task>.json (committed evidence)   .sdkit/memory/ (committed)   .sdkit/.verify-cache/
   setup:   bin/{sdkit,init,doctor,sync,upgrade,migrate,install,shared,lib}.sh, templates/, stacks/<stack>/
```

| Component | Files | Role |
|---|---|---|
| Entry / CLI | `bin/sdkit` (dispatcher), `bin/init.sh` 316 lines, `doctor.sh`, `sync.sh`, `upgrade.sh`, `migrate.sh`, `install.sh`, `shared.sh` (the marked block in shared files), `lib.sh` | Sets the repo up, reports drift; does not overwrite project-side files |
| Phase machine | `scripts/sdd.sh` (234) | `start/advance/gate/ci-check`, fingerprint, evidence |
| Task record | `scripts/state.sh` | Orchestrator resume record, single retry, spawn counter |
| Role execution | `scripts/run-role.sh`, `core/roles/`, `core/tiers.env`, `core/hosts.env`, `bin/build-adapters.sh` + `bin/emit/*` | Headless role in a separate process; host/tier/model selection |
| Verification | `scripts/verify-core.sh` + `stacks/*/scripts/steps.sh`, `verify.d`, `parse-verdict.sh`, `check-plan-parity.sh`, `check-writes.sh` | Green-result cache, policy scripts, verdict format |
| Parallelism | `plan-waves.sh` (awk), `worktree.sh` | Waves, write-set conflicts, isolated worktree |
| Guards | `hooks/guard-*.sh`, `frozen-tests.sh`, `scripts/guard.sh` | Regex safety nets |
| Token economy | `usage.sh`, `hooks/usage-log.sh`, `guard-budget.sh`, `result-size.sh`, `lookup-cache.sh`, `core/rules/token-economy.md` | Ledger, budget, output size, scout cache |
| Memory | `scripts/memory.sh`, `hooks/session-context.sh` | Index-based project memory |
| Packaging | `.claude-plugin/`, `Formula/sdkit.rb`, `packaging/` | Plugin + Homebrew |

Dependencies: `bash` (written to be 3.2 compatible), `git`, `jq`, `node`+`openspec` (spec engine), the stack toolchain, `shasum` or `sha1sum`, `column` (`usage.sh report`). No new runtime dependency; the recommendations add none either.
External integrations: OpenSpec skills (`opsx:*`), Bitbucket (`open-pr.sh`, CI template), GitHub Actions template, five host CLIs (`run-role.sh`), Homebrew tap.

Size: 242 tracked files, 16 hooks, 16 scripts, 10 roles, 4 skills, 7 stacks; the counts in the docs match the code (counted).

## 2. Capability inventory

| # | Capability | Class | Actual implementation | Limitation |
|---|---|---|---|---|
| 1 | Architecture, entry points | Implemented | `bin/sdkit` dispatcher; roles single-sourced in `core/roles/`, `build-adapters.sh --check` in sync (10 role files) | Project dir resolver copied in 12 files (§6 D1) |
| 2 | CLI: init/doctor/sync/upgrade/migrate | Implemented | `bin/*.sh`; `tests/shared.test.sh` (29), `sdkit-dir.test.sh` (64) | `doctor` checks statically only; no live host |
| 3 | Phase machine `intake→…→done` | Implemented (after `start`) / **Partial** (before) | `sdd.sh advance` checks every gate itself; the red test must actually **fail**, DoD present, race section at high, diff fingerprint | Analyst, risk confirmation and plan gate exist only in the skill text; the agent can run `start --risk low` itself (§6 R3) |
| 4 | Roles, handoff, orchestration | Implemented | `references/handoff.md`, `delegation.md`, `parallel.md`; the "roles never call roles" rule; independent roles are `read-only` | Orchestration is prose: the machine does not catch a breach of the rules (the no-role-calls rule is unverified on OpenCode/Codex) |
| 5 | Model selection/routing | **Partial** | Tier single source `core/tiers.env`; `run-role.sh` resolves host/tier/model in a script (`--dry-run` tested) | On the Claude path, passing the `model` parameter to the `Agent` tool depends on the orchestrator model remembering it (`model-routing.md`); the `tierenv` logic lives only in `run-role.sh`, no other caller |
| 6 | Token economy, ledger, budget | **Partial** | `usage.sh` (log/report/budget), `guard-budget` (before spawn), `run-role.sh` (spawn point); `tests/budget.test.sh` 45 cases | Only Claude + Gemini write tokens; the unit is tokens (no tier price); checked only before a spawn; race (§6 D4); the ledger is deleted at closeout (§6 D6) |
| 7 | Context loading | Implemented | SKILL.md is short; `references/` are read only at their step; the memory index is trimmed by `MEMORY_INDEX_MAX=100`; `session-context.sh` sends one message | The memory index is injected into every session (bounded and configurable) |
| 8 | Memory, cache, persistent state | Implemented, **one bug** | `memory.sh` (38 tests), `verify-core.sh` green cache (tree key: HEAD+diff+untracked files+settings+policies), `lookup-cache.sh` | The `lookup-cache` key does not see untracked files → stale answer (§6 B3, executed) |
| 9 | Verification, tests, quality gates | Implemented, **one weakness** | The verifier format is strictly validated by `parse-verdict.sh`; attestation + `ci-check`; frozen tests; stack `verify.sh`; `verify.d` | The `record-verdict` hook on Claude does **not** do this validation (§6 B2, executed) |
| 10 | Security, permissions, isolation, Git | **Partial, by design** | Regex guards (`guard-secrets/-prod/-git/-pr/-protected/-readonly`), git hooks, CI gate, worktree isolation, `check-writes.sh` | Documented limits (guide §13) aside; new: the env file executes code (§6 R1), `run-role --host claude` lets a read-only role use Bash (§6 R4) |
| 11 | Error handling, retry, continuity | **Partial** | Resume via `state.sh`; the single automatic retry is scripted (`retry`); hooks are silent on their own errors (`exit 0`); `.sdd/state.json` persists across sessions | `run-role.sh` has no timeout and no retry on transient errors; state file writes are unlocked (§6 D4) |
| 12 | Observability, diagnostics | **Partial** | `usage.sh report` (role/tier/cache rate), `doctor.sh`, `sync --check`, `sdd.sh status`, `last-test.log`/`last-verify.log` | No event log of phase transitions/refusals; `history` and the ledger are deleted when the task closes; hook decisions leave no trace |

Test suite: 6 files, 773 lines, **all pass** (§10 below). Gap: the live host adapters (Codex, OpenCode, Cursor, Gemini) were not tested; the docs already say "not verified".

## 3. Workflow and agent execution lifecycle

```
Step 0 intake      analyst→NEEDS-INFO rounds→user confirms the risk label           [prose]
                   sdd.sh start --risk R --proposal P  ──► phase intake             [machine]
Step 1 explore     openspec-explore (scout + lookup-cache)                          [prose]
Step 2 plan gate   engineer draft→plan.md→user "Approve and propose"                [prose]
Step 3 propose     openspec-propose + DoD;  advance proposed (DoD item, high:race)  [machine]
Step 4 implement   advance red (test FAILS) → implement → advance green             [machine]
                   high: test-writer→.frozen→developer (separate role runs)
Step 5 verify      verifier(-deep) → SubagentStop hook/parse-verdict --record
                   advance verified → write attestation                             [machine]
Step 6 BLOCK       state.sh retry <id> (once) → stop at the 2nd BLOCK, ask the user [script+prose]
Step 7 PR          gate push (hook+git hook+CI) → advance pr                        [machine]
Step 8 closeout    advance done (.sdd deleted) → sync-specs, archive, work/<slug> deleted [machine+prose]
```

Every `Edit/Write`, `push` and `gh pr create` call goes to `sdd.sh gate`: through the hook on Claude, `adapt.sh` on Cursor/Gemini, the plugin on OpenCode, `pre-commit`/`pre-push` elsewhere, and `ci-check` on the server. **The single-decision-point design is sound** and there is no duplicated logic.

Agent execution: on Claude, the `Agent` tool + `guard-budget` (PreToolUse) + `record-verdict`/`usage-log`/`result-size` (SubagentStop). On other hosts, `run-role.sh`: role text + handoff → headless CLI → answer + token line → `usage.sh log`.
The machine enforces independence in only two places: binding the verdict to the diff fingerprint and (on Claude) the read-only tool list/`guard-readonly`.

## 4. State, artifact and memory lifecycle

| Data | Location | Git | Writer | Lifetime / deletion |
|---|---|---|---|---|
| Phase state | `.sdkit/.sdd/state.json` (one file = one open task) | no | only `sdd.sh` (hook `_verdict`) | `rm -rf` on `done`/`abort`; `history` is lost |
| Orchestrator record | `.sdkit/work/<slug>/state.json` | no | `state.sh` | deleted by hand at closeout |
| Ledger | `work/<slug>/usage.jsonl` | no | `usage.sh log` | **deleted** at closeout |
| Notes, plan, outputs, scout answers | `work/<slug>/{notes.md,plan.md,out/,lookups/}` | no | agents | closeout; `lookups/` drop out when the code state changes |
| Evidence | `.sdkit/attestations/<task>.json` | **yes** | only `advance verified` | permanent; protecting it with CODEOWNERS is recommended |
| Memory | `.sdkit/memory/*.md` + `INDEX.md` | yes (no with `MEMORY_VCS=ignore`) | `memory.sh` | `stale` reports, does not delete |
| Verify cache | `.sdkit/.verify-cache/` | no | `verify-core.sh` | last 20 entries |
| Frozen tests | `.sdkit/.frozen` | no | test-writer | `done`/`abort` |

There are two "task states" (`.sdd/state.json`, `work/<slug>/state.json`); `risk` and `verdict` appear in both, and which one is authoritative is written only in the docs (`SKILL.md`: "`state.sh` stays the resume record; `<sdd>` is the gate"). The problem is on the budget side: `guard-budget.sh` and `run-role.sh` answer the question "whose `<slug>` budget counts" with `ls -t work/*/state.json | head -1` ("most recently updated"); the `.task` that `sdd.sh` knows is not used.

## 5. Compatibility constraints

The following constrain the recommendations; no recommendation may break them.

1. **Bash 3.2 (macOS), `set -u`**: expanding an empty array is an error (noted in the code); no `declare -A`, `mapfile` or `${!ref}` array tricks. `${!var}` indirect expansion works in 3.2.
2. **Multiple hosts**: a hook change must be reflected in 4 places (`hooks.json`, the `adapt.sh` tables, the OpenCode plugin, `guard.sh`), and the `sdd.sh gate` interface (exit 0/1 + reason on stdout) must stay stable.
3. **Project-side files are not overwritten** (`project.md`, `sdkit.env` append only, `rules/`, `settings.json`); setting key names and the `KEY=VALUE` + `: "${X:=v}"` format exist in current repos (`templates/sdkit.env` line 25 uses shell syntax).
4. **Legacy layouts**: the `.agentkit/.claude/.codex` + `project.env` resolver must stay until `upgrade --migrate` removes them.
5. **Versioning**: `plugin.json` and `marketplace.json` together; a `docs/upgrading.md` section for behaviour changes. Counts are kept equal in `README`, `core/roles/README.md`, `guide.md` §2/6/7/10/15, `cheatsheet.md` and `CONTRIBUTING.md`.
6. **Guards default to off/silent**: a hook does not block on its own error; recommendations must not break this.
7. **The attestation format** is in use in repos with CI: if the `fingerprint` computation changes, the evidence of every open PR goes stale (major version).
8. **Adapters are not verified live**: a change that affects non-Claude hosts is tested with `--dry-run`/fixtures and is not called "verified".

## 6. Findings: technical debt and architectural risk

### Bugs and code/doc contradictions (Real gap)

**B1. `guard-pr` refuses the command the skill recommends** (`executed`).
`skills/spec-driven-dev/SKILL.md` §5 tells the orchestrator to run `parse-verdict.sh - --proposal <proposal.md> --record`. `hooks/guard-pr.sh` `deny`s the same command on Claude (pattern `parse-verdict\.sh[^;&|]*--record`).
Experiment: passing the command to `guard-pr.sh` returned `permissionDecision: deny`. On Claude the flow still works because the verdict already comes from the `record-verdict` hook, but the text misdirects and pushes the agent toward "work around the refusal" behaviour. Fix: in SKILL.md, "Claude: do not use `--record`, validate only"; `--record` on other hosts.

**B2. The verdict format is not validated on the Claude path** (`executed`).
`hooks/record-verdict.sh` only takes the `VERDICT: (PASS|BLOCK)` line by regex and writes `sdd.sh _verdict`. `parse-verdict.sh`, by contrast, checks the PASS/FAIL of the DoD lines, the CONFIRMED/PLAUSIBLE of the findings and verdict-vs-findings consistency (and `--record` records only a consistent block).
Experiment: a SubagentStop input containing `DOD - D1 | FAIL | … VERDICT: PASS` passed through the hook and `verdict.result = PASS` was written to the state file; `parse-verdict.sh` answered the same text with `MALFORMED … require BLOCK` (exit 2).
So on Claude, the path of the strongest independent-verification guarantee is weaker than the host-neutral path. Fix: the hook calls `parse-verdict.sh --record` (one decision code). See ADR-0003.

**B3. `lookup-cache` does not see a new untracked file** (`executed`).
`state()` = `HEAD` + a digest of `git diff HEAD`; untracked files are not in `git diff HEAD`. `verify-core.sh`, by contrast, adds untracked file contents to its key. Experiment: after a `put`, adding a new file still gives a **HIT** on `get`.
Impact: a "where is this symbol" answer goes stale when a new file is added; the scout answer stays wrong. Fix: add the output of `git ls-files -o --exclude-standard` (with a content digest) to the key; move it, together with the matching part of `verify-core.sh`, into a shared helper.

**B4. The `STACK` default is inconsistent** (`read`).
`sdd.sh` uses `${STACK:-generic}`; `stop-verify.sh`, `guard.sh`, `check-tools.sh`, `post-edit-fmt.sh`, `doctor.sh`, `verify-core.sh`, `upgrade.sh`, `migrate.sh`, `shared.sh` and `lib.sh` use `${STACK:-go}` (10 files). If `STACK` is empty, Go verification runs. This is rare because `templates/sdkit.env` normally writes `STACK`, but in a repo where it was deleted by hand, or an old repo, the wrong stack is picked silently. Fix: one default (`generic`), in one place.

### Duplication and fragile design (Real gap, low risk)

**D1. The project dir resolver and env loader are copied in 12 files** (`read`): `hooks/lib.sh` and `scripts/{sdd,state,usage,guard,memory,lookup-cache,open-pr,plan-waves,resolve-base,run-role,verify-core}.sh` carry the same two lines; `plan-waves.sh` is a different variant (reads the env with `sed`, local file first). The design record knows this (`design-sdkit-dir.md` §2: "12 scripts"). `matches_glob_list` also has 3 copies (`hooks/lib.sh`, `guard.sh`, `sdd.sh`); one carries the empty-array guard, one does not.
Maintenance risk: a rule (e.g. a new env file, a new legacy-layout name) changes in 12 places. Fix: one `scripts/env.sh` (sourced), and scripts do `. "$here/env.sh"`. See ADR-0001.

**D2. Two task states** (§4): `risk`/`verdict` are duplicated. Budget and spawn counting depend on the "most recently updated state.json" assumption; with two tasks open in parallel it writes to the wrong task; with no `work/<slug>/state.json` at all the budget is **silently disabled** (hook `exit 0`). Fix: use `.task` from `.sdd/state.json`. See ADR-0002.

**D3. Domain copy**: `tierenv` (`run-role.sh`) and the parsing of `core/tiers.env` exist only there; on the Claude path no script does the same resolution, i.e. the deterministic table exists but there is no command to call. Fix (optional): `run-role.sh --print-model` or a small `tier-model.sh <host> <tier>`; the orchestrator takes the `model` parameter from it.

**D4. Race conditions** (`executed`). Given the parallel wave feature (`MAX_PARALLEL=3`, several `Agent` calls in one message):
- `state.sh spawn` does an unlocked read-modify-write: after 20 concurrent calls the counter is **3** (expected 20). The `MAX_SPAWNS` limit can be exceeded.
- `usage.sh log --id` rewrites the line with `grep -vF` + `mv`: after 20 concurrent calls the ledger has **3** lines (expected 20). Parallel SubagentStops delete lines from the ledger, and the budget reads low.
- `sdd.sh put` follows the same pattern (single writer: hook + orchestrator, low risk).
Whether Claude really runs PreToolUse/SubagentStop hooks concurrently is **Needs Verification**; the script-level race is certain. Fix: a small `mkdir`-based lock (portable, dependency-free) or, instead of rewriting by `--id` in the ledger, append-only + dedupe by `id` at report time. See ADR-0004.

**D5. `${…}` indirect field**: `run-role.sh` does `eval "model=\${RUN_ROLE_MODEL_$T:-}"`; `T` is validated when it comes from `--tier`, but not when it comes from the role file's `tier:` field (`<project-dir>/roles/<role>.md`, repo content). Low risk (the role file is trusted repo content); `${!var}` removes the `eval`.

**D6. History lost at closeout**: SKILL.md §8 deletes `work/<slug>/` → `usage.jsonl` is gone. `usage.sh report` (all slugs) only sums open tasks; "does this kit really save tokens" cannot be measured once the task ends. Likewise, `sdd.sh`'s `history` list is deleted at `done`. (Optional §7 O1.)

### Security and independence (Real gap)

**R1. Settings files run as code** (`executed`). All scripts and hooks *source* `sdkit.env` and `sdkit.local.env` with `.`. Experiment: adding a `touch PWNED` line to `.sdkit/sdkit.env` and running `session-context.sh` created the file.
`sdkit.env` is a file the team commits; a malicious PR or an untrusted clone can execute commands as soon as the SessionStart hook runs (Claude's workspace trust prompt is the first defence, but the kit opens a second channel). This is the kit's own surface, outside the "guards are not a security boundary" warning. Fix: **parse** settings as `KEY=VALUE` (no execution); the `: "${PR_HOST:=bitbucket}"` form leaves the template. Done in one place once D1 is reduced to a single loader. See ADR-0001. Compatibility: §5.3.

**R2. Fingerprint and evidence trust** (documented, `read`): anyone with write access can produce an evidence file; `ci-check` looks only at fingerprint equality and the `verdict` field, not at the verifier's identity. This is documented. Extra note: for `low` risk `verdict` is empty; CI accepts `low` evidence on the fingerprint alone, i.e. **lowering the risk label** (R3) removes the verifier requirement in CI.

**R3. The agent can lower the risk label** (`read`). Nothing stops `sdd.sh start --risk low` (`guard-pr` refuses only touching the `.sdd/` path and `_verdict`). The "user confirms" rule is prose. `ci-check` accepts the label without question. This is the weakest link in the design: since the risk rule is not hard, the verifier requirement can be skipped.
Fix (optional, user decision): a "a diff touching these paths is at least medium" mapping, such as `RISK_FLOOR_GLOBS`, in the project's `sdkit.env`; `ci-check` compares the evidence's risk with the mapping. Empty = current behaviour. See ADR-0005.

**R4. On `run-role.sh --host claude` a read-only role can run Bash** (`read`): only `--disallowedTools "Edit Write NotebookEdit"` is passed. A headless session has no `agent_type`, so `guard-readonly` stays silent (stated in its own header), i.e. the verifier can run `rm`/`sed -i`. Codex (`--sandbox read-only`) and Gemini (`plan`) use a real sandbox; the Claude path is weaker. Fix: read + an allowed shell list via `--allowedTools` (`READONLY_SHELL_ALLOW`, already in `core/hosts.env`). Needs a live CLI: **Needs Verification**.

**R5. Resilience**: `run-role.sh` sets no timeout on the host CLI; a hung verifier blocks the session. No retry on a transient error (rc≠0) (by design: the single retry is for BLOCK). Fix (optional): `RUN_ROLE_TIMEOUT` (empty = off), if a portable `timeout`/`gtimeout` is found. Note: the prompt is passed via argv (`ARG_MAX` for a large handoff, visible with `ps`); moving to stdin must be verified per host.

### Portability (Needs Verification)

**P1.** `shasum` is called directly (`sdd.sh`, `verify-core.sh`); `lookup-cache.sh` carries a `sha1sum` fallback. The CI template installs `alpine/git` + `coreutils`; `shasum` may not ship in that package (unverified) → `ci-check` may not work. Must be verified with a real Bitbucket run; falling back to `sha256sum` is one line.
**P2.** The Cursor/Gemini hooks do not wire `guard-readonly`, `guard-budget`, `usage-log` or `record-verdict` (by design: Claude-specific fields). On these hosts the budget exists only on the `run-role.sh` path, and independent verification relies on `parse-verdict --record`; this is documented.

## 7. Prioritized improvement list

Labels: **G** = real gap, **O** = optional. Effort: S (<1 hour), M (half a day), L (a day+). All dependency-free bash/jq.

| Priority | ID | Type | Work | Effort | Why now |
|---|---|---|---|---|---|
| P0 | B2 | G | `record-verdict.sh` → `parse-verdict.sh --record` (single validation code); test: an inconsistent block is not recorded | S | Gap in the strongest guarantee, on the Claude path |
| P0 | B1 | G | SKILL.md §5 / `hosts.md`: no `--record` on Claude (the hook records); present on other hosts | S | The skill gives a command the hook forbids |
| P0 | D4 | G | `mkdir` lock or append-only for `state.sh spawn` and `usage.sh log`; parallel race test (20 processes) | M | Parallel waves are a core feature; the counter and ledger are wrong |
| P1 | R1+D1 | G | One `scripts/env.sh` + `KEY=VALUE` parser (no execution); replace the `plan-waves.sh` variant with it too; the `: "${…:=…}"` line in the template gets simpler | L | Security surface + 12 copies in one place; ADR-0001, an `upgrade` note for compatibility |
| P1 | D2 | G | Budget/spawn slug from `.sdd/state.json .task`; otherwise the current heuristic | S | Wrong budget with two parallel tasks |
| P1 | B3 | G | Untracked files in the `lookup-cache` key | S | Wrong scout answer |
| P1 | B4 | G | One `STACK` default (`generic`) | S | Silently wrong stack |
| P2 | R3 | O* | `RISK_FLOOR_GLOBS` (empty by default) + `ci-check` comparison | M | *User decision (ADR-0005); hardens against lowering the risk |
| P2 | D6 | O | At closeout, summarize `usage.jsonl` and archive one line outside `.sdkit/work`/next to `attestations`, or `usage.sh report --archive` | S-M | Without cost history a savings claim cannot be measured |
| P2 | R4 | G? | Allowed shell list for `run-role --host claude` | S | Once verified with a live CLI |
| P2 | P1 | G? | `sha256sum` fallback for `ci-check` + a real CI run | S | Alpine template |
| P3 | D3 | O | `tier-model.sh` / `--print-model` | S | On the Claude path the script does model selection (the agent does not have to remember) |
| P3 | R5 | O | `RUN_ROLE_TIMEOUT` | S | Hung CLI |
| P3 | D5 | O | `eval` → `${!var}` | S | Hardening |
| P3 | — | O | Event log of phase transitions/refusals (`.sdkit/work/<slug>/events.jsonl`, one line per event) | M | Diagnostics: today "why was it refused" is only the reason given at that moment |

**Deliberately not recommended** (not a real gap, or benefit < cost): a multi-task `.sdd/` (already separate per worktree), a money budget instead of tokens (tier prices change between releases, and the kit does not invent model names), moving to Node/Python (bash 3.2 + a dependency-free design is an advantage), a new orchestration framework, signed evidence (CODEOWNERS is enough; documented in R2), putting the analyst/plan gate into the phase machine (user approval cannot be proven by the machine; only the label floor in R3 makes sense).

**Simplification opportunity:** D1 + D2 + B4 together reduce about 12 resolver copies, 3 `matches_glob_list`s, 10 `STACK` defaults and two budget-slug heuristics to one place each; behaviour does not change, and it is not a new abstraction, just merging copies that already exist.

## 8. Architecture decision records (proposed)

Format: `templates/adr/TEMPLATE.md`. ADR-0001..0005 were implemented in F00.5. The kit's own decision records are kept under `docs/` as design documents (like `design-sdkit-dir.md`); once accepted, these move to a separate design document.

### ADR-0001. Settings are read as data, not as shell
- Status: accepted, implemented (F00.5) · Date: 2026-10-29 · Ticket: F00 (R1, D1)
- **Context.** 12 files source `sdkit.env`/`sdkit.local.env` with `.`; a committed file can run commands at hook time (executed, §6 R1). The same loading code is copied 12 times.
- **Decision.** `scripts/env.sh`: resolver + `KEY=VALUE` (quoted or plain) parser; it `export`s and executes nothing. Scripts source it. Old `: "${X:=v}"` lines and lines containing `$(…)` raise a warning in `doctor`, and `upgrade` converts them to `KEY=VALUE`.
- **Alternatives.** Leave it as is and document it: the surface stays. Move settings to JSON: breaking for every existing repo, and `jq` adds a process to every hook.
- **Consequences.** The security surface closes, and 12 copies become one. Shell expansion in settings (`$HOME`, concatenation) no longer works: this needs a major/minor decision and an `upgrading.md` section. Command settings like `VERIFY_CMD` are still values that get **executed** (when invoked, not when the env is loaded); this is intentional.

### ADR-0002. The active task ID comes from `.sdd/state.json`
- Status: accepted, implemented (F00.5) · Date: 2026-10-29 · Ticket: F00 (D2)
- **Context.** Budget and spawn counting rely on the "most recently updated `work/*/state.json`" heuristic; with two open tasks the record goes to the wrong one, with none it silently turns off.
- **Decision.** `sdd.sh status --slug` (or `.task`) is the single source; `guard-budget.sh` and `run-role.sh` ask it and fall back to today's heuristic if it has no answer. The two state files are not merged (one is the out-of-git phase gate, the other the orchestrator's resume record; their lifetimes differ).
- **Alternatives.** Merge the files: `state.sh`'s fields (`step`, `tasks`, `retries`) are too different, and it would not be backward compatible. Keep the heuristic: wrong with parallel tasks.
- **Consequences.** Small, reversible change; `sdd.sh` returns empty when there is no task, and the old behaviour is kept.

### ADR-0003. The verdict is recorded only through `parse-verdict.sh`
- Status: accepted, implemented (F00.5) · Date: 2026-10-29 · Ticket: F00 (B2)
- **Context.** The Claude hook takes the `VERDICT:` line by regex; an inconsistent block was recorded as PASS (executed).
- **Decision.** `record-verdict.sh` passes the text to `parse-verdict.sh - --record`; an invalid block is not recorded, and the orchestrator is told via `systemMessage` to "ask for the format once".
- **Alternatives.** Write a second validator in the hook: duplicated logic. Trust only the orchestrator: violates the independence principle.
- **Consequences.** One validation path, the same on every host; the hook is still silent on its own error (`exit 0`). If the verifier output is malformed there is no PASS record, and `advance verified` refuses (the correct behaviour).

### ADR-0004. Shared state writes use a lock or append-only
- Status: accepted, implemented (F00.5): lock chosen · Date: 2026-10-29 · Ticket: F00 (D4)
- **Context.** Concurrent `state.sh spawn` and `usage.sh log --id` lose updates (20 calls → 3; executed).
- **Decision.** Ledger: append-only, the `--id` rewrite goes away, and `report`/`budget` take the last line per `id` (`jq group_by`). Counter: a short critical section with `mkdir <file>.lock`.
- **Alternatives.** `flock`: not available on macOS. A single writer process: an architecture change.
- **Consequences.** The file grows a little (snapshot lines), the report result stays the same, and the budget reads correctly.

### ADR-0005. Risk floor (optional, off by default)
- Status: accepted, implemented (F00.5 closeout) · Date: 2026-10-29 · Ticket: F00 (R3)
- **Context.** The risk label is set by the agent's `sdd.sh start --risk` call; "the user confirms" is prose; `ci-check` does not question the label.
- **Decision.** `RISK_FLOOR_GLOBS` in `sdkit.env` (e.g. `high:services/payments/*;medium:migrations/*`); empty means today's behaviour. `sdd.sh start` refuses if the label is below the floor (according to `SDD_MODE`), and `ci-check` compares the evidence's risk with the floor by path.
- **Alternatives.** Ignore it (R3 stays open). Sign the label: approval cannot be proven by the machine.
- **Consequences.** No project-specific knowledge enters the kit (the setting comes from the project; "the kit stays generic" holds). A wrong glob produces false BLOCKs; this needs `guided` mode and a `doctor` preview.

## 9. Summary of what is missing / partial / good

Good: a single decision point (`sdd.sh gate`) across four entry paths; the machine checks red-green tests; the verdict goes stale through the diff fingerprint; independent roles have narrow access; roles are generated from a single source and kept in sync with `--check`; dependency-free bash; hooks that are off by default and silent on their own errors; a short SKILL.md + per-step references; a solid test suite (773 lines, 337 cases).
Partial: model routing (the Claude path depends on the agent), token economy (host coverage, race, no history), errors/continuity (timeout, lock), observability (no event log), security (R1, R3, R4).
Missing (really): an event log of phase transitions, cost history after closeout, a run timeout. None of these is P0.

## 10. Checks run during the audit

| Check | Result |
|---|---|
| `tests/smoke.test.sh` | 109 passed, 0 failed |
| `tests/sdd.test.sh` / `shared` / `memory` / `budget` / `sdkit-dir` | 52 / 29 / 38 / 45 / 64 passed, 0 failed |
| `bin/build-adapters.sh --check` | adapters up to date (10 role files) |
| Experiment B1: `guard-pr.sh` ← `parse-verdict.sh … --record` | `deny` |
| Experiment B2: `record-verdict.sh` ← DoD `FAIL` + `VERDICT: PASS` | `PASS` written to the state file; `parse-verdict.sh` exit 2 |
| Experiment B3: `lookup-cache` put → new untracked file → get | HIT (stale answer) |
| Experiment D4: 20 concurrent `state.sh spawn` / `usage.sh log --id` | counter 3 / ledger 3 lines |
| Experiment R1: `touch` line in `sdkit.env` → `session-context.sh` | the command ran |
| Count equality (hooks 16, scripts 16, roles 10, skills 4) | matches the docs |

The experiments were run in temporary `git init` directories; kit files were not changed. Not run: live Codex/OpenCode/Cursor/Gemini, real Bitbucket/GitHub CI, Claude's hook concurrency, `shellcheck` (if not installed).

## 11. Open questions

1. Is **ADR-0005 (risk floor)** wanted? It is the only recommendation that hardens behaviour, and it needs per-project configuration.
2. **ADR-0001** narrows the `sdkit.env` format: is "shell expansion is not supported in the settings file" acceptable, and in which release (minor/major)?
3. Do Claude's PreToolUse/SubagentStop hooks run concurrently for parallel `Agent` calls? The answer decides how urgent D4 is.
4. Who is the cost history (D6) for: personal (stays next to `work/`) or a team report (committed summary)?

## 12. Status after F00.5

| Finding | Status | How | Regression test (`tests/hardening.test.sh`) |
|---|---|---|---|
| B2 | fixed | `record-verdict.sh` passes the text to `parse-verdict.sh --record` (with the task's `proposal.md`: a skipped DoD item is refused too); an invalid block is not recorded and a `systemMessage` goes to the orchestrator; the transcript fallback now extracts the last assistant text with `jq`; the hook still does `exit 0` in every case | inconsistent PASS, bare `VERDICT` line, skipped DoD, a broken block arriving later, transcript fallback |
| B1 | fixed | SKILL.md §5 and `hosts.md`: no `--record` on Claude, present on other hosts. A second contradiction the audit missed was also resolved: on Cursor/Gemini/OpenCode, `guard-pr` also refused the only recording path (`--record`); `adapt.sh` and the OpenCode plugin pass `SDKIT_HOST`, and `guard-pr` refuses only when `SDKIT_HOST` is empty (Claude). `_verdict` and `.sdd/` are refused on every host | decision per host, gemini through adapt.sh, SKILL text |
| D4 | fixed | `sdkit_lock` (`mkdir`, dependency-free, Bash 3.2): all writing commands of `state.sh`, `usage.sh log`, `sdd.sh put`. A lock whose owner is dead is broken after 3 s, a stuck lock after 10 s. Append-only was not chosen over the lock: the `--id` rewrite semantics and old readers are kept | 30 parallel `spawn` (5 before), 30 `task`, 30 `log --id` (3 before), same `id`, 20 `_verdict`, stale lock |
| R1+D1 | fixed | `scripts/env.sh`: single resolver + parser; the 12 copies are gone (including the `plan-waves.sh` variant; `bin/*` through `lib.sh`). Migration: `upgrading.md`. `doctor` reports ignored lines as FAIL with `file:line` | `$(...)`, backtick, `;`, value with spaces, bare command, `PATH=` do not execute; supported syntax keeps its meaning; all entry points; source-usage scan |
| D2 | fixed | `sdkit_active_slug`: the open SDD task (if `work/<slug>/state.json` exists), otherwise the old heuristic. `sdd.sh task` added. Used by `guard-budget`, `run-role`, `usage.sh` | two tasks, ledger slug, both fallback paths |
| B3 | fixed | The `lookup-cache` key includes untracked file names+contents; the kit's own `work/`, `.sdd`, `.verify-cache` paths are excluded | new file, edit, own file, tracked edit |
| B4 | fixed, **differently from the audit's recommendation** | Single default `go` (`SDKIT_DEFAULT_STACK`, `scripts/env.sh`). `generic` had been recommended, but `go` is the documented default (`guide.md` §10) and the silent assumption of Go-only repos from before stacks existed; switching to `generic` would break them. The one place that deviated (`sdd.sh`) was aligned; `doctor` warns on an empty `STACK` | source scan, default, explicit value, doctor |
| R3 | fixed (optional feature) | ADR-0005: `RISK_FLOOR_GLOBS=level:glob,...`, off when empty. Uses the existing `matches_glob_list` and `changed_files` (the fingerprint's file set, untracked files included); checked by `advance green`/`verified` and `ci-check`. CI recomputes the floor itself (it does not trust the `floor` field in the attestation), a low-risk attestation does not satisfy a high floor, `RISK_FLOOR_GLOBS` and `SDD_MODE` in the base branch's `sdkit.env` cannot be loosened by the PR, a file that matches the floor needs an attestation even under free globs, and a malformed value is refused. Details and limits: `upgrading.md` | 76 cases, `tests/risk-floor.test.sh` |

Unchanged: the phase machine, the hook contract (`exit 0`, silent on its own error), the role and host architecture, the `sdd.sh gate` interface, the attestation format. Still open: the P2/P3 items in §7 (R3 was closed by the row below).

Deviations from the decision text of ADR-0005: `sdd.sh start` does not refuse the label (there is no diff at start; the floor check happens at `green` and `verified`, and `start` refuses only a broken configuration); the format separates with `,`, not `;` (same as the other glob lists), and every entry carries a `level:` prefix.
