# Contracts inventory

Every string, shape, file name and exit code that a skill, role, doc, template or hook quotes or parses, and that the Go program must reproduce. Source list: [02-contracts.md](02-contracts.md). Package names: [01-architecture.md](01-architecture.md). Line numbers are those of the tree at the time of writing (P0-01 merged).

Columns: **Golden** = `y` means a captured file in `testdata/golden/<pkg>/` is required. `W` means the contract is on stdout, `E` on stderr.

## 1. Files and layout

| # | String / shape | Quoted where | Go package | Golden |
|---|---|---|---|---|
| 1.1 | `<project-dir>` = `.sdkit/`, resolver needs `sdkit.env`; `$KIT_DIR` first | `skills/spec-driven-dev/references/hosts.md:19`; `scripts/env.sh` | `project` | n |
| 1.2 | Settings files `sdkit.env` then `sdkit.local.env`; line forms `KEY=v`, `export`, `: "${K:=d}"`; ignored-line message `file:line: ignored (unsupported syntax)` | `templates/sdkit.env`, `templates/sdkit.local.env`; `scripts/env.sh` | `envfile` | y |
| 1.3 | Keys the templates declare (names are the contract): `SDD_MODE`, `STACK`, `VERIFY_CMD`, `DIFF_BASE_CMD`, `ROUTING`, `PARALLEL`, `MAX_PARALLEL`, `MEMORY`, `MEMORY_DIR`, `MEMORY_PROMOTE`, `CONTRACTS`, `TELEMETRY`, `USAGE_LINE`, `RUN_ROLE_HOST`, `VERIFIER_HOST`, `AGENT_<ROLE>_TIER`, `SPEC_REVIEW_MAX_ROUNDS`, `SPECS_DIR`, `PRESPEC_DIR`, `BASE_BRANCH`, `PROTECTED_BRANCHES`, `PROTECTED_PATHS`, `SECRET_GLOBS`, `RISK_FLOOR_GLOBS`, `SUBAGENT_RESULT_MAX_LINES`, `CAPPED_LINES`, `NOISY_CMD_PATTERNS`, `MAX_SPAWNS`, `SDD_MANAGED`, `SDKIT_ENV`, `ANALYST_LANGUAGE`, `JIRA_*`, `TRACKER`, `LINT_CONFIG` | `templates/sdkit.env` (whole file); `skills/spec-driven-dev/references/{delegation.md:18,model-routing.md:20,parallel.md:46-49}`; `skills/generate-specs/SKILL.md:18` | `envfile` | y (key list test against the template) |
| 1.4 | Phase names `intake proposed red green verified pr done` (+ `aborted`); transitions `verified\|pr > verified`, `any > (aborted)` | `skills/spec-driven-dev/SKILL.md:38`; `scripts/sdd.sh:208-212` | `sdd` | y |
| 1.5 | State paths `<project-dir>/.sdd/state.json`, `.sdd/last-test.log`, `.sdd/last-verify.log`, `.frozen`, `attestations/`, `work/<slug>/{state.json,plan.md,notes.md,out/,contracts/}`, `work/spec-draft/<id>/`, `work/spec-merge/<id>/plan.json`, `work/review/<id>/state.json` | `skills/spec-driven-dev/SKILL.md:18,94`; `references/{handoff.md:15-17,delegation.md:16,memory.md:5}`; `skills/generate-specs/references/{generate.md:3,review.md:4}`; `scripts/spec.sh:34`; `scripts/review.sh` | `state`, `store`, `sdd` | n |
| 1.6 | Block markers `<!-- spec-driven-kit:begin v<ver>. Managed by the kit: do not edit between the markers; write your own text outside them. -->` (md) and `# spec-driven-kit:begin v<ver>. ... settings outside them.` (hash); matching `end` | `bin/shared.sh:18-20`; `bin/doctor.sh:166` | `setup` | y |
| 1.7 | Kit blocks content `templates/blocks/AGENTS.kit.md`, `CLAUDE.kit.md`; `.git/info/exclude` hiding | `templates/blocks/*` | `setup`, `emit` | y |
| 1.8 | Pre-spec check `usage: sdkit prespec check <name>` (exit 2); passes when exists, non-empty, git-ignored, untracked | `skills/generate-specs/SKILL.md:24`; `bin/sdkit:11,21-24` | `spec` (or `setup`) | y |
| 1.9 | `known-pitfalls.md`, `adr/TEMPLATE.md`, `verify.d/`, `golangci.yml`, `rules/`, `roles.d/` file names | `skills/incident-to-rule/SKILL.md:12,23-32` | `setup` | n |

## 2. verify.d policies

| # | String / shape | Quoted where | Go package | Golden |
|---|---|---|---|---|
| 2.1 | Env `VERIFY_ROOT`, `VERIFY_MERGE_BASE`, `VERIFY_CHANGED`, `VERIFY_CHANGED_GO` (Go stack only). **Also exported: `VERIFY_CHANGED_SRC`, not named in 02-contracts** | `scripts/verify-lib.sh:2`; `scripts/verify-core.sh:60-61` | `verify` | y |
| 2.2 | `VERIFY_POLICY_DIR` override; name order, `_` prefix skipped, `*.example` ignored | `scripts/verify-core.sh:12`; `bin/doctor.sh:135` | `verify` | y |
| 2.3 | Policy output protocol: lines `FAIL: ...` / `WARN: ...`; non-zero exit fails | `skills/incident-to-rule/SKILL.md:24` | `verify` | y |
| 2.4 | `verify.sh --fast --since-head` flags; Stop hook shows `tail -30` of output | `hooks/stop-verify.sh:8-10`; `skills/spec-driven-dev/SKILL.md:36` | `verify`, `hook` | y |

## 3. Hook protocol

| # | String / shape | Quoted where | Go package | Golden |
|---|---|---|---|---|
| 3.1 | In: `tool_name`, `tool_input.file_path`, `tool_input.command`, `agent_type`, `hook_event_name`, `stop_hook_active` | `hooks/lib.sh:24`; `hooks/stop-verify.sh:5`; `hooks/adapt.sh:19-22` | `hook` | y |
| 3.2 | Out Claude: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow\|ask\|deny","permissionDecisionReason":"..."}}`; exit 0 | `hooks/lib.sh:27-31` | `hook` | y |
| 3.3 | Out SessionStart: `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}`. **Not listed in 02-contracts** | `hooks/session-context.sh:42`; `hooks/check-tools.sh:18` | `hook` | y |
| 3.4 | Out advisory: `{"systemMessage":"..."}` (guided mode, contract, verdict, size, usage, budget warnings). **Not listed in 02-contracts** | `hooks/check-contract.sh:24,33,44`; `hooks/record-verdict.sh:35-36`; `hooks/result-size.sh:15`; `hooks/guard-budget.sh:23,37,45,61,64`; `hooks/usage-log.sh:20` | `hook` | y |
| 3.5 | Out Stop: `{"decision":"block","reason":"verify failed, fix before finishing:\n<tail>"}`. **Not listed in 02-contracts** | `hooks/stop-verify.sh:10-11` | `hook` | y |
| 3.6 | Gemini: deny = exit 2 + reason on stderr; tool map `read_file read_many_files write_file replace run_shell_command`; `unknown host '<h>'` (E, exit 0) | `hooks/adapt.sh:4-6,17-31,40` | `hook` (gemini) | y |
| 3.7 | Cursor: `{"permission":...}`; events `beforeShellExecution beforeReadFile afterFileEdit`; tool map `Shell Read Write Delete`; no-ask host gets deny saying explicit approval is needed | `hooks/adapt.sh:4-7,32-39` | `hook` (cursor) | y |
| 3.8 | OpenCode: deny/ask becomes a thrown error in the plugin (plugin template to be listed by P2) | `docs/go-port/02-contracts.md` (hook protocol) | `hook` (opencode), `emit` | y |
| 3.9 | Env honoured `CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT`, `CURSOR_PROJECT_DIR`, `GEMINI_PROJECT_DIR`, `SDKIT_HOST` | `hooks/lib.sh`; `hooks/guard-pr.sh:24` | `hook`, `project` | n |
| 3.10 | `hooks/hooks.json` event/matcher table: SessionStart (`session-context check-tools value-report`), PreToolUse `Agent\|Task` (`guard-budget check-contract`), `Bash` (`guard-prod guard-git guard-pr ...`), command form `"${CLAUDE_PLUGIN_ROOT}"/hooks/<x>.sh` | `hooks/hooks.json:1-50` | `emit`, `hook` | y |
| 3.11 | Session context sentence `Workflow: <status\|no active task> (SDD_MODE=<m>); code edits, push and PR are gated by phase; start with the spec-driven-dev skill.` | `hooks/session-context.sh:25`; `docs/developer-workflow.md:433` | `hook` | y |
| 3.12 | Hook deny/ask reasons (texts the model sees; quoted by docs as "the refusal text itself"): phase `guard-phase.sh:11`; frozen `frozen-tests.sh:10` (`'<rel>' is frozen by spec-driven-dev. Fix the implementation, not the test.`); protected `guard-protected.sh:10`; secrets `guard-secrets.sh:7`; read-only `guard-readonly.sh:16-38` (`'<name>' is a read-only role: ...`); git `guard-git.sh:24,36,42`; prod `guard-prod.sh:20`; noisy `guard-noisy.sh:16`; pr `guard-pr.sh:12,17,21,25,29,34` | `docs/developer-workflow.md:399` ("the refusal text itself") | `hook` | y (reasons not quoted by a skill may be reworded; tests assert decision, not text) |
| 3.13 | Guard-pr denies model calls to `_verdict`, `_evidence`, `_spawn`, `_spawn-close`, writes under `.sdd/`, `attestations/`, `parse-verdict.sh --record` on Claude, `--no-verify`, `core.hooksPath`, `SDD_SKIP=`, `GUARD_SKIP_VERIFY=` | `hooks/guard-pr.sh:11-29` | `hook` | y |

## 4. Phase gate and `sdd`

| # | String / shape | Quoted where | Go package | Golden |
|---|---|---|---|---|
| 4.1 | `sdd status` W: `task=<slug> risk=<r> phase=<p>` then optional ` profile=<p>` (when not `standard`), ` verdict=<R>`, ` evidence=stale` (phase verified/pr), ` ticket=<K> spec=<id>@<sha12>`, ` blocked=<kind>:<ref>`; none: `no active task`. **02-contracts shows only the base fields** | `docs/developer-workflow.md:393,412`; `scripts/sdd.sh:870-878`; `references/managed.md:27`; `references/workflow.md:17` | `sdd` | y |
| 4.2 | `sdd phase` prints phase only; `sdd task` slug; `sdd mode` prints `strict\|guided\|off` | `docs/developer-workflow.md:393`; `scripts/sdd.sh:885-890` | `sdd` | y |
| 4.3 | `sdd start` W: `task '<slug>' opened (risk=<r>, profile=<p>, phase=intake). Write the proposal with a Definition of Done, then: sdd.sh advance proposed`; managed variant `task '<slug>' opened (managed: spec <id> v<ver> at <sha12>, risk=..., profile=..., phase=intake). The DoD is seeded ...` | `docs/developer-workflow.md:184`; `scripts/sdd.sh:157,776` | `sdd` | y |
| 4.4 | `sdd advance` W: `phase: <new>`; on `done`: `task closed`; refusal E: `sdd: <reason>` exit 1; `sdd (warning): <msg>` in guided | `docs/developer-workflow.md:406`; `scripts/sdd.sh:63,302,543` | `sdd` | y |
| 4.5 | Refusal reason codes (telemetry `--reason`, named in workflow.md): `no-artifact no-dod no-design no-task-size tests-pass tests-fail test-cmd-changed verify-failed no-verdict verdict-block stale-verdict no-evidence evidence-block task-mismatch untrusted-evidence stale-evidence role-conflict risk-floor not-next unknown-phase out-of-phase agents-pending concurrent no-fingerprint missing-artifact missing-field inconsistent` | `skills/spec-driven-dev/references/workflow.md:13`; `docs/developer-workflow.md:399,444,759`; `scripts/sdd.sh:184-294,445-451` | `sdd`, `telemetry` | y |
| 4.6 | Refusal texts quoted verbatim by docs: `sdd: medium risk needs an independent verifier PASS (current: none). Run the verifier agent on a clean context; its verdict is recorded automatically.`; `no Definition of Done section with a list item` (`<proposal> has no 'Definition of Done' section with at least one list item. ...`); `the tests PASS, so they prove nothing yet...`; `the diff changed after verification. Re-run the verifier, then 'sdd.sh advance verified'.` | `docs/developer-workflow.md:415,759`; `scripts/sdd.sh:238,246,276,578` | `sdd` | y |
| 4.7 | `no active task. Start one: sdd.sh start <slug> --risk <low\|medium\|high> --proposal <path>` (E, exit 1); evidence/other: `no active task` (E, exit 4) | `scripts/sdd.sh:67,362,397` | `sdd` | y |
| 4.8 | `sdd evidence` W, one row per role `verifier reviewer security-auditor`: `%-18s %-10s verdict=%-5s trust=%-12s run=%s%s` (state `valid missing block wrong-task untrusted stale conflict`; `-` for empty) | `docs/developer-workflow.md:415-418`; `scripts/sdd.sh:457-469` | `sdd` | y |
| 4.9 | `sdd _evidence` result lines: `evidence: <role> <R> trust=<t>`, `evidence: <role> <R> ignored (a trusted PASS ...)`, `evidence refused (<reason>): <role> <R>`; trust `spawned unregistered manual`; reasons `task-mismatch role-conflict duplicate unknown-run stale-at-record kept-trusted` | `scripts/sdd.sh:176-190,399-408` | `sdd` | y |
| 4.10 | `sdd transitions` W: `%-18s %s` rows `<from> > <to>`, `  managed: <p>`, `verified\|pr > verified`, `blocked > intake`, `any > (aborted)` | `references/workflow.md:3`; `scripts/sdd.sh:206-213` | `sdd` | y |
| 4.11 | `sdd policy` W: `task=<t\|-> risk=<r\|-> profile=<p> verifier=<verify-command\|independent-verifier> contracts=<lvl> (scout/analyst: <lvl>) automatic-retries=1`; `--json` keys `task risk profile verifier contracts{writing_and_deciding_roles,lookup_roles} automatic_retries evidence_roles[]`; profile list lines `small`, `standard`, `high-assurance` | `docs/developer-workflow.md:186`; `scripts/workflow.sh:90-102`; `references/workflow.md` | `workflow` | y |
| 4.12 | `workflow capabilities` W: four rows (`claude-code`, `run-role.sh (any host)`, `host-native subagents (codex, opencode, cursor, gemini)`, `git hooks / CI (all hosts)`), 8 pipe fields, values `enforced detected manual none auto ask`; text form `%-52s contract=%s \| parse=%s \| identity=%s \| record=%s \| stale=%s \| gate=%s \| failure=%s`; `--json` keys `path spawn_contract verdict_parse trusted_identity evidence_record stale_detection completion_gate failure_report` | `scripts/workflow.sh:76-86`; `references/hosts.md:28` | `workflow` | y |
| 4.13 | `workflow` helper messages: `profile <p> requires a contract for role <r>: add CONTRACT: 1, ID: and REPLY-END: ...`; `agents still in flight or interrupted: ...` | `scripts/workflow.sh:61,71` | `workflow` | y |
| 4.14 | Gate `edit` / `push` W reason, exit 1; texts: `The workflow state and attestations are written only by sdd.sh and the verifier hook.`; `Task '<t>' is blocked by a <kind> request (<ref>): ...`; `Task is in phase '<p>'; push and PR come after 'verified' (tests green, then verification).`; phase table: none/intake docs+specs+project only, proposed tests only, red+ anything | `scripts/sdd.sh:561-579`, comment `:528-534` | `sdd` | y |
| 4.15 | `sdd floor [--validate]`: `<level> <file>`; invalid: `RISK_FLOOR_GLOBS is invalid: <why> (expected level:glob,level:glob with level low\|medium\|high)` exit 2 | `scripts/sdd.sh:538,888` | `sdd` | y |
| 4.16 | `sdd abort [failed\|blocked\|partial]` W `task aborted`; Value Report terminal words `COMPLETED FAILED BLOCKED PARTIAL` | `scripts/sdd.sh:896`; `docs/developer-workflow.md:404` | `sdd`, `report` | y |
| 4.17 | Managed: `sdd start --ticket`, `block --spec-change --reason --section --proposal`, `revalidate --sha`, `done --merged`, `evidence-sync`; messages `revalidated: '<t>' is pinned to <id> v<ver> at <sha12>; ...`, `evidence-sync: <t> already has this evidence...`, `evidence-sync: <t> has the evidence...` | `references/managed.md:11,17,23-27`; `scripts/sdd.sh:797,836,854,866` | `sdd`, `jira` | y |
| 4.18 | `usage: orchestrator: ... \| task total: ...` on E when `USAGE_LINE=1`; step line extension `· orchestrator: in 41k (fresh 3k, cache read 36k, cache write 2k), out 6.2k, hit 88% \| task total: ...` | `references/progress.md:16-17`; `scripts/sdd.sh:301` | `sdd`, `usage` | y |
| 4.19 | Attestation file under `<project-dir>/attestations/`, written only by `sdd`; CI gate `sdd ci-check` | `scripts/sdd.sh:15,168`; `docs/developer-workflow.md:502`; `templates/ci/*` | `sdd`, `guard` | y |
| 4.20 | `state.sh` verbs: `<slug> init show get set task retry spawn path`; `retry` exit 0 first time, 1 spent; `spawn` exit 1 over `MAX_SPAWNS`; `show` prints state.json (keys step risk branch tasks retries verdict) | `skills/spec-driven-dev/SKILL.md:18,111`; `references/{workflow.md:16,delegation.md:47}`; `scripts/state.sh:5-12` | `state` | y |

## 5. Text that skills and roles quote

| # | String / shape | Quoted where | Go package | Golden |
|---|---|---|---|---|
| 5.1 | Step line (orchestrator): `[sdkit] orchestrator · Step <n>/<total>: <name> — started\|done` (U+00B7 middle dot, U+2014 em dash); other outcomes `skipped`, `stopped: <short reason>`; total 7 (low), 8 (medium, high); step names in the table | `skills/spec-driven-dev/SKILL.md:14`; `references/progress.md:9-13,21-39` | emitted by the model, text shipped in `kit` (embedded); `sdd` only for the `usage:` suffix | n (doc string test) |
| 5.2 | Step line (analysts): `[sdkit] generate-specs - Step <n>/10: ...`, `update-specs ... /6`, `merge-specs ... /6`, plain hyphen `-`, `started\|done`. **02-contracts describes only the orchestrator form** | `skills/generate-specs/SKILL.md:22`; `skills/update-specs/SKILL.md:21`; `skills/merge-specs/SKILL.md:18` | embedded skill text | n |
| 5.3 | Subagent line `[sdkit] <role> done — in: 12.4k, out: 1.8k, cache hit: 71%` | `templates/sdkit.local.env:25`; `hooks/usage-log.sh:10-20`; `references/progress.md:13` | `hook`, `usage` | y |
| 5.4 | Verifier block `DOD:` / `FINDINGS:` / `VERIFY:` / `VERDICT: PASS\|BLOCK`; DoD line `- <item text> \| PASS\|FAIL \| <evidence>`; finding tags `CONFIRMED`, `PLAUSIBLE`; BLOCK iff any FAIL or CONFIRMED | `core/roles/verifier.md:20-40`; `docs/developer-workflow.md:466-482` | `verdict` | y |
| 5.5 | Reviewer / spec-reviewer / security-auditor: `SUMMARY: <n> blockers, <n> major, <n> minor`, `SUMMARY: <n> critical, <n> high, <n> medium, <n> low`, `NO FINDINGS`, `VERDICT: PASS\|BLOCK`; severities BLOCKER MAJOR MINOR / CRITICAL HIGH MEDIUM LOW | `core/roles/reviewer.md:22`; `spec-reviewer.md:22`; `security-auditor.md:26` | `verdict` | y |
| 5.6 | `parse-verdict` exit 0 PASS, 1 BLOCK, 2 malformed, 3 well-formed but refused to record (reason on second line); one summary line; flags `--proposal --record --role --source --run --task`; normalisation rules (CR, emphasis, case, bullets), `PARSE_NORMALIZE=0` | `scripts/parse-verdict.sh:2-27`; `docs/developer-workflow.md:482`; `skills/spec-driven-dev/SKILL.md:104` | `verdict` | y |
| 5.7 | Hook messages after parse: `<role> verdict NOT recorded: <summary>. Ask the <role> once for the exact <fmt> format.`; `<role> verdict NOT recorded as evidence: <summary>. It does not count: run the <role> again on the current diff.` | `hooks/record-verdict.sh:35-36` | `hook` | y |
| 5.8 | Handoff fields `ROLE TASK READ WRITE TESTS OUT TIER CONTRACT ID RETRY-OF REPLY-END`; reply line `HANDOFF-RESULT/1 \| id: <ID> \| role: <ROLE> \| status: done\|partial\|blocked\|failed \| artifacts: <paths\|none> \| blockers: <text\|none> \| next: <text\|->` | `references/handoff.md:5-24`; `references/contract.md:10-17`; `scripts/contract.sh:5-10` | `contract` | y |
| 5.9 | `contract` one-line output `CONTRACT=valid\|invalid stage=handoff id=.. role=.. [reason=..]` (+ `status=..`); reasons `no-result malformed unsupported-version missing-field bad-value inconsistent id-mismatch role-mismatch task-mismatch unknown-id duplicate stale unsafe-path missing-artifact out-of-scope`; exit 0/1/2 | `scripts/contract.sh:17-20`; `references/contract.md:25` | `contract` | y |
| 5.10 | Hook message `Agent contract NOT accepted: <summary>. Ask the agent once for the HANDOFF-RESULT line (state.sh <slug> retry <id> first); a contract never replaces the verifier.` | `hooks/check-contract.sh:44` | `hook` | y |
| 5.11 | `ENVELOPE/1 role=<r> decision=<d> dod_pass=<n> dod_fail=<n> confirmed=<n> plausible=<n> blocking_severity=<s> evidence=<ref>` (keeps every FAIL / CONFIRMED / BLOCKER line) | `docs/developer-workflow.md:372`; `scripts/digest.sh:9,55`; `scripts/run-role.sh:14` | `digest` | y |
| 5.12 | `capped` prints exit code, failure lines, tail; full log `<project-dir>/work/<slug>/out/cmd-<time>.log`; exit = command's; `--lines N --slug S --` | `references/delegation.md:24`; `scripts/capped.sh:2-6` | `capped` | y |
| 5.13 | `dod-check` W `dod ok: N item(s) automated=a static=s manual=m post-deploy=p none=n` (+ reminder line); DoD line grammar `D<n>: <condition> \| Verified by: <unit test\|integration test\|manual check\|none: reason>` | `docs/developer-workflow.md:297`; `scripts/dod-check.sh:13,76`; `references/plan-gate.md:14` | `plan` | y |
| 5.14 | `check-plan-parity plan.md proposal.md tasks.md` compares DoD (id, text, Verified-by) and tasks; `plan-waves`, `check-writes`, `dispatch claim <id> tasks.md` | `references/plan-gate.md:52`; `references/parallel.md:43-49` | `plan`, `dispatch` | y |
| 5.15 | tasks.md line `- [ ] T<n> <title> \| role: <r> \| size: small\|medium\|large \| writes: <paths> \| after: T<m>` | `references/parallel.md:11-14`; `references/model-routing.md:9` | `plan` | y |
| 5.16 | `plan.md` section layout (section 3 DoD, section 5 tasks) | `references/plan-gate.md:4-14` | `plan` | y |
| 5.17 | `MEMORY: fact\|howto\|decision \| <slug> \| <title> \| <text>` lines in `notes.md`; `memory.sh candidates <slug>`, `promote <slug> <n...\|all>`; `knowledge.sh put\|get <slug> <key> --files "a b"`; `lookup-cache.sh get\|put <slug> "<q>"` | `references/memory.md:5-30`; `references/delegation.md:19` | `memory`, `knowledge`, `lookup` | y |
| 5.18 | `run-role` flags `--handoff --cwd --host --tier --model --dry-run --envelope --out --ignore-budget`; host values `claude codex opencode cursor gemini ext:<adapter>` | `references/hosts.md:15-17`; `references/model-routing.md:47`; `scripts/run-role.sh:14,186` | `runrole`, `adapter` | y (dry-run command lines) |
| 5.19 | `run-role` messages: `run-role: exit 7 = NOT A FAILURE: valid evidence for this diff already exists, nothing was run and nothing should be retried (read it: sdd.sh evidence)` and `run-role: exit 8 = NOT RUN: routing declined ...` | `references/hosts.md:17-18`; `scripts/run-role.sh:115-116` | `runrole`, `route` | y |
| 5.20 | Tier names `light standard strong` (aliases `small medium large`); message `--tier must be light\|standard\|strong (or small\|medium\|large), got '<x>'`; `core/tiers.env` `CLAUDE_MODEL_<TIER>` | `references/model-routing.md:17-20`; `references/hosts.md`; `scripts/run-role.sh:94` | `route`, `emit` | y |
| 5.21 | `route` decision actions `reuse`, `stop`, run; reasons `DUPLICATE_COMPLETED DUPLICATE_IN_FLIGHT`; Value Report status `skipped_redundant` | `scripts/run-role.sh:110-116`; `scripts/report.sh:68`; `docs/developer-workflow.md:258-262` | `route`, `report` | y |
| 5.22 | `recover scan [slug]` read-only listing: stale handoffs, spawns, claims, reservations plus one safe action each | `docs/developer-workflow.md:405` | `recover` | y |
| 5.23 | `telemetry summary <slug>` layout (lines `task ... run ... mode ... risk`, `status ... verified ... wall ... events`, `phases`, `agents:`, `tests:`, `retries ... failures ... gate rejections`, `workflow: profile ... decisions ... rejections <reason>=<n>`) | `docs/developer-workflow.md:419-431` | `telemetry` | y |
| 5.24 | `usage budget` line `Budget: 156,700 / 1,000,000 tokens (usage.sh budget)    Blockers: none (last refusal: no-verdict)` | `docs/developer-workflow.md:444` | `usage`, `report` | y |
| 5.25 | `sdkit where` prints the install location (Go: embedded data is not a directory, see `06-release.md`) | `docs/go-port/02-contracts.md`; **no skill in this tree quotes `sdkit where` today** | `project` | y |

## 6. `doctor`, `init`, `sync`

| # | String / shape | Quoted where | Go package | Golden |
|---|---|---|---|---|
| 6.1 | Line prefixes `  ok    `, `  FAIL  `, `  warn  `; final `doctor: <n> failure(s), <m> warning(s)`; exit 0 when no FAIL, else 1 | `bin/doctor.sh:9-12,312-313`; `docs/developer-workflow.md:123-129` | `setup` | y |
| 6.2 | Warning texts quoted by docs: `no active verify.d policy (rename .example files to enable the ones you want)`; `no server-side gate in CI: local hooks can be skipped with --no-verify (init.sh --ci bitbucket\|github\|gitlab)`; FAIL `project.md still has TODO placeholders` | `docs/developer-workflow.md:123-125`; `bin/doctor.sh:135,227` | `setup` | y |
| 6.3 | Other doctor checks (names of what is checked; text may be reworded unless a skill quotes it): STACK unset, VERIFY_CMD, memory status, settings lacking, `sdkit.local.env` ignored/committed, legacy layout, spec submodule, `TRACKER=jira`, role tier override, pricing, hosts, git hooks `core.hooksPath .githooks`, version drift `.scaffold-version`, `.scaffold-shared`, CI gate, openspec CLI and skills, Jira credential check (HTTP code) | `bin/doctor.sh:19-304` | `setup` | y (statuses per scenario) |
| 6.4 | Skill instruction: for each `FAIL` say what to change; do not edit `project.md` | `skills/scaffold-doctor/SKILL.md:12` | `setup` | n |
| 6.5 | `init` flags `--ci github\|bitbucket\|gitlab`, `--memory`, `--tools`, hosts list `claude codex opencode cursor gemini`, stacks `go spring-boot jvm python nextjs react-native generic` | `docs/developer-workflow.md:502`; `skills/scaffold-init/SKILL.md:12`; `bin/doctor.sh:29` | `setup`, `stack` | y |

## 7. Jira, spec, tasks, review

| # | String / shape | Quoted where | Go package | Golden |
|---|---|---|---|---|
| 7.1 | Task contract: description with fenced block ` ```sdkit-task ` ... ` ``` ` holding the task JSON; written as `<text>\n\n```sdkit-task\n<json>\n```\n` | `scripts/jira.sh:5,46-50,79`; `scripts/tasks.sh:12,104`; `skills/generate-tasks/references/task-format.md` | `jira`, `tasks` | y |
| 7.2 | `jira` verbs `validate-task [FILE\|-]`, `fetch KEY`, `deps-ready KEY`, `upsert EXTERNAL_ID JSON`, `comment`, `transition`, `change-request KEY JSON`; exit 0, 1 (not ready), 2 usage, 3 egress/auth, 4 contract invalid, 5 not found / external failure; failed call prints no success output | `scripts/jira.sh:5-12`; `skills/generate-tasks/references/jira-write.md:5`; `references/managed.md:11,23` | `jira` | y |
| 7.3 | `deps-ready` JSON `{"ready":bool,"pending":[...]}`; `fetch` JSON = task + `key status statusCategory`; idempotency label `sdkit-ext-<externalId>`; `JIRA_EGRESS=allow` | `scripts/jira.sh:7-8`; `skills/generate-tasks/references/jira-write.md:5` | `jira` | y |
| 7.4 | Errors `<KEY>: no sdkit-task block in the description`, `sdkit-task block is not a JSON object`, `no sdkit-task block and not JSON` (exit 4); `sdd: warning: <t> could not be moved to '<Blocked>' ...` | `scripts/jira.sh:62-63,87-88`; `scripts/sdd.sh:797` | `jira` | y |
| 7.5 | `tasks.json` `{specId, specVersion, specSha, parent, tasks:[{ref,title,summary?,slug?,change?,risk,acceptanceCriteria[],dependsOn[],scope[]}]}`; `ids` adds `key`, `externalId` (`<specId>:<taskKey>`); map file `{"<externalId>":"PROJ-12"}`; results `results.jsonl` | `scripts/tasks.sh:3-19`; `skills/generate-tasks/SKILL.md:16-23` | `tasks` | y |
| 7.6 | `tasks` verbs `acs [--revision] changes trace <ac-list\|-> cycles ids order render <ref> [--keys] [--json] report --out`; exit 0, 1, 2, 3 (not approved), 4; cycle printed `ref -> ref`; report says `NOT a success` when a task has no result | `scripts/tasks.sh:4-19`; `skills/generate-tasks/SKILL.md:16-23` | `tasks` | y |
| 7.7 | AC token `AC-<feature>-<n>` (stable, never renumbered); spec layout `specs/<id>/{proposal.md,design.md,tasks.md,specs/<cap>/spec.md,.openspec.yaml}`; `### Requirement:`, `#### Scenario:`; deltas `## ADDED Requirements`, `## MODIFIED Requirements`, removed | `skills/generate-specs/SKILL.md:26`; `references/propose.md:6,10`; `skills/update-specs/references/change.md:14` | `spec` | y |
| 7.8 | `spec` verbs: `init-meta hash status changed branch publish promote approved-sha change(new\|refresh\|status) drift check apply`; exit 0, 1, 2, 3 (drift, apply needs resolutions); branches `spec/<id>`, `spec/<id>--<slug>`; flags `--title --body-file --breaking --sha --kind fix\|feature` | `scripts/spec.sh:4-47`; `skills/update-specs/SKILL.md:23-27`; `skills/merge-specs/SKILL.md:20-25` | `spec` | y |
| 7.9 | `spec.meta.json` `{version,status,branch,contentHash,history:[{version,sha,at,contentHash}]}` (0.0 draft; 0.1 first; +0.1; 1.N after approval; `--breaking` N+1.0); `status` approved/draft | `scripts/spec.sh:4,12-15,17` | `spec` | y |
| 7.10 | `change.json` (base, label, expects, touches, createdAt, resolutions) plus `intent.md`; `plan.json` facts (changes[].capabilities, `expectsMoved`) | `skills/update-specs/references/change.md:13`; `skills/merge-specs/references/judge.md:3-5`; `scripts/spec.sh:21,31-34` | `spec` | y |
| 7.11 | PR body status line `SIBLINGS: ...: do not merge alone, merge-specs first` or `applied against base <hash>` | `scripts/spec.sh:46-47` | `spec`, `pr` | y |
| 7.12 | `review` verbs `plan [--json] hash begin [--target] [--final] record --verdict PASS\|BLOCK\|PARTIAL\|NOT_RUN --isolation fresh\|none [--findings] check accept <id> <finding> [--who] --why`; exit 0, 1, 2, 3 (round cap); `check` prints reason on stdout | `scripts/review.sh:3-30`; `skills/generate-specs/references/{review.md:4-10,triage.md:21-22}` | `review` | y |
| 7.13 | Findings file lines `- <id> \| BLOCKER\|MAJOR\|MINOR \| <where> \| <text>` or JSON `[{id,severity,evidence,disposition: open\|fixed\|accepted}]`; `acceptances.jsonl`; `review.d/<artifact>.env` keys `REVIEWERS STANDARDS CONTEXT` (`prd adr feature-spec`) | `scripts/review.sh:6-22`; `skills/generate-specs/references/review.md:10`; `templates/review.d/*` | `review` | y |
| 7.14 | `templates/change-request.md` and `jira.sh change-request` JSON `{reason, section?, proposal?, specId?, specSha?}` | `skills/generate-tasks/references/change-request.md:3`; `scripts/jira.sh:10` | `jira`, `setup` | y |
| 7.15 | `open-pr` / `pr-check`: `pr-check.sh --base --list --milestone`; lines `ok    <l> (<n>s)` / `FAIL  <l> (<n>s)`; `PR_HOST` | `scripts/pr-check.sh:14-31`; `skills/spec-driven-dev/SKILL.md:118` | `pr` | y |

## 8. Exit codes

| # | Command | Codes | Quoted where | Go package | Golden |
|---|---|---|---|---|---|
| 8.1 | `sdd gate` | 0 allowed, 1 refused (reason W) | `scripts/sdd.sh:528-579` | `sdd` | y |
| 8.2 | `sdd advance`, other refusals | 1 (reason E); 4 on `no active task` in evidence paths | `scripts/sdd.sh:362,397`; `docs/developer-workflow.md:406` | `sdd` | y |
| 8.3 | `run-role` | 0 ran; 2 policy/config/usage; 3 budget; 4 contract broken; 5 contract valid but partial\|blocked\|failed; **6 evidence role's answer could not be recorded as a verdict (missing from 02-contracts)**; 7 reuse; 8 declined; 127 host CLI missing; else the host CLI's status | `scripts/run-role.sh:31-33`; `references/hosts.md:17-18`; `docs/developer-workflow.md:517-525,762` | `runrole` | y |
| 8.4 | `parse-verdict` | 0 PASS, 1 BLOCK, 2 malformed, 3 not recorded | `scripts/parse-verdict.sh:15-16` | `verdict` | y |
| 8.5 | `doctor` | 0 no FAIL, 1 otherwise | `bin/doctor.sh:313` | `setup` | y |
| 8.6 | `jira` | 0,1,2,3,4,5 as 7.2 | `scripts/jira.sh:12` | `jira` | y |
| 8.7 | `tasks` / `spec` / `review` / `contract` | as 7.6, 7.8, 7.12, 5.9 | script headers | `tasks spec review contract` | y |
| 8.8 | `state retry` | 0 granted, 1 spent | `scripts/state.sh:10` | `state` | y |
| 8.9 | Usage errors | 2 | all headers | `cli` | n |

## 9. Bash-only snippets in skills and references that P5-01 must rewrite

Pattern sweep over `skills/**` for `mkdir -p`, `mv`, `cp`, `cat`, `jq`, `$(...)`, `KIT=`, `tail`, `grep`, `sed`, `awk`, `xargs`. The skills hold almost no shell; the host-neutral rule works. Items by severity:

| # | File:line | Snippet | Rewrite as |
|---|---|---|---|
| B1 | `skills/generate-specs/references/propose.md:6` | `mkdir -p specs/<id>` then "move the content of `openspec/changes/<id>/`" into it | `sdkit spec adopt <id>` (or one portable instruction without `mkdir`/`mv`) |
| B2 | `skills/spec-driven-dev/SKILL.md:36` | "Pipe its output through `tail -40`" (verify command) | `sdkit capped -- <verify>` (no pipe, works in cmd and PowerShell) |
| B3 | `skills/scaffold-doctor/SKILL.md:11` | `"<kit>/bin/doctor.sh" "$PWD"` (`$PWD`, quoted path to a script) | `sdkit doctor` |
| B4 | `skills/scaffold-doctor/SKILL.md:14` | `bin/upgrade.sh`, `"<kit>/bin/sync.sh" "$PWD"` | `sdkit upgrade`, `sdkit sync` |
| B5 | `skills/spec-driven-dev/SKILL.md:35,36,37,38,104,118` and `references/{delegation.md:19,24,27, hosts.md:7,15, model-routing.md:47, plan-gate.md:52, memory.md:5, workflow.md:19}`, `skills/generate-tasks/SKILL.md:10`, `skills/update-specs/SKILL.md:10` | `<kit>/scripts/<x>.sh` placeholder and `<sdd>` = `<kit>/scripts/sdd.sh` (every script call goes through `<kit>`); `hosts.md:7` maps `<kit>` to `${CLAUDE_PLUGIN_ROOT}` or `<project-dir>/scripts/` | `sdkit <cmd>`; drop the `<kit>` row of `hosts.md` |
| B6 | `skills/spec-driven-dev/SKILL.md:36` | `<kit>/stacks/<STACK>/scripts/verify.sh` default verify command | `sdkit verify` |
| B7 | `skills/spec-driven-dev/SKILL.md:37` | `<diff-base>` = output of `DIFF_BASE_CMD` else `<kit>/scripts/resolve-base.sh` (a `$(...)` consumer) | `sdkit base` |
| B8 | `skills/spec-driven-dev/references/managed.md:25` | `git -C <SPECS_DIR> fetch && git ...` (`&&` chain, `-C`) | one `sdkit sdd revalidate` step or two plain `git` lines |
| B9 | `skills/merge-specs/SKILL.md:20` | `git merge --no-edit origin/spec/<id>--<other>` per sibling | keep `git` (portable), no change |
| B10 | `skills/generate-tasks/SKILL.md:17,22` | `git show <SHA>:specs/<id>/...`; `tasks.sh render ... --keys map.json --json` | keep `git show`; `sdkit tasks render` |
| B11 | `skills/spec-driven-dev/references/hosts.md:15` | `<kit>/scripts/run-role.sh <role> --handoff F --cwd D --host H` | `sdkit run-role ...` |
| B12 | `skills/update-specs/references/change.md:3` | `git diff <last published sha> -- specs/<id>` | keep `git` |
| B13 | `skills/generate-specs/references/review.md:9` | `~/.claude/plugins/cache/egm/egm/<version>/skills/egm-review-loop/SKILL.md` (`~`, POSIX path) | a host-neutral wording (path is Claude-only) |
| B14 | `skills/spec-driven-dev/references/memory.md:5` | `<project-dir>/$MEMORY_DIR` (shell variable syntax in prose) | `<project-dir>/<MEMORY_DIR>` |
| B15 | `skills/spec-driven-dev/SKILL.md:18,111,118,124`; `references/progress.md:39` | `state.sh <slug> show`, `retry`, `sdd.sh advance done`, `gh pr create`, `glab mr create`, `open-pr.sh` named as commands | `sdkit state ...`, `sdkit sdd ...`, `sdkit open-pr` (the `gh`/`glab` names stay) |
| B16 | `skills/spec-driven-dev/references/handoff.md:15-17`; `references/memory.md:21` | `MEMORY:`/`TESTS:`/`OUT:` templates with `|` inside code fences (data, not shell): keep | none |

Count: 16 rows (B1 to B4 and B11 are the literal shell snippets; B5 to B8, B10, B13 to B15 are path or command spellings; B9, B12, B16 stay).

`mkdir -p` / `mv` appear once (B1). `cp`, `cat` and `jq` appear in no skill or reference. `KIT="$(sdkit where)"` appears nowhere in this tree: skills use the `<kit>` placeholder (B5) instead, so P5-01 replaces the placeholder, not a variable assignment.

## 10. Gaps and mismatches against 02-contracts.md

| # | Finding |
|---|---|
| G1 | `run-role` exit **6** (evidence answer could not be recorded) is missing from "Exit codes". |
| G2 | `sdd status` also prints ` profile=`, ` verdict=`, ` evidence=stale`, ` ticket= spec=`, ` blocked=`; the contract names only three fields. |
| G3 | The analyst skills use a different step line (`[sdkit] <skill> - Step <n>/<6\|8>: <name> - started\|done`, plain hyphen, totals 6 and 8); the contract has only the orchestrator line. |
| G4 | Hook outputs `hookSpecificOutput` for SessionStart, `{systemMessage}` and the Stop `{decision:block}` are real contracts not in "Hook protocol". |
| G5 | `VERIFY_CHANGED_SRC` is exported next to the four named variables. |
| G6 | `advance` refusals go to **stderr** (`sdd: ...`), `gate` refusals to **stdout**; the contract states only the second. |
| G7 | `sdd` exits 4 with `no active task` on `evidence` paths; 02-contracts lists only 0 and 1. |
| G8 | `sdkit where` is named in 02-contracts but no skill here quotes it; the skills use `<kit>`. |
