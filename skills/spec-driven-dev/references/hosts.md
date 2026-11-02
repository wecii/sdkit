# Host mapping

The workflow is written host-neutral. This table says how each primitive is done in each host.

| Primitive | Claude Code | Codex | OpenCode | Cursor | Gemini CLI | Anything else |
|---|---|---|---|---|---|---|
| Kit scripts (`<kit>`) | plugin: `${CLAUDE_PLUGIN_ROOT}`; copy: `<project-dir>/scripts/` | `<project-dir>/scripts/` | same | same | same | same |
| Ask the user | `AskUserQuestion` (max 4 per call) | numbered question, wait for the reply | same as Codex | same | same | same |
| Run a role | `Agent` tool, `subagent_type: "spec-driven-kit:<role>"` (plugin) or `"<role>"` (copy). Never `fork` | ask Codex to spawn the subagent role `<role>` (`.codex/config.toml`) | `@<role>` or the task tool; agents in `.opencode/agents` | subagent `<role>` from `.cursor/agents` | `@<role>`; agents in `.gemini/agents` | play the role in the main session using only the handoff inputs |
| Parallel roles | several `Agent` calls in one message | spawn several subagents | several task calls | several subagents | several `@` calls | sequential, or separate processes in worktrees |
| Guards | hooks (`hooks/hooks.json`) | git hooks (`.githooks`) | plugin `.opencode/plugins` + git hooks | `.cursor/hooks.json` via `hooks/adapt.sh` + git hooks | `.gemini/settings.json` via `hooks/adapt.sh` + git hooks | git hooks and CI |
| Skills | plugin or `.claude/skills/` | `.agents/skills/` | `.agents/skills/` | `.agents/skills/` | `.agents/skills/` | `AGENTS.md` points at the workflow |

Any host, any role, as a separate headless process (fresh context, pinned to a directory, read-only when the role is):
`<kit>/scripts/run-role.sh <role> --handoff F --cwd D --host H`. Default host: `VERIFIER_HOST` for verifier roles, else `RUN_ROLE_HOST`
(`sdkit.env`); a verifier on another vendor gives the most independent check. Use `--dry-run` to see the command.
Exit codes with `ROUTING=on` (opt-in, `design-routing.md`): 0 ran; **exit 7 = valid evidence for this diff already exists, nothing was run: success-like, do not retry and do not call `state.sh retry`** (read it with `sdd.sh evidence`);
**exit 8 = routing declined to run and no valid result exists** (duplicate, standing BLOCK, retries exhausted, optional role skipped): never treat it as a pass, read the printed reason; exit 3 budget, exit 2 refused by policy/config.

`<project-dir>` is `.sdkit/` for every host (a repo set up before 1.0 may still use `.claude/`, `.codex/` or `.agentkit/`). Claude Code's own files (`CLAUDE.md`, `settings.local.json`, copy-mode `agents/ skills/ hooks/`) stay under `.claude/`; the kit generates them per machine and hides them from git, only `AGENTS.md` and the kit block in `CLAUDE.md` are committed.

Model per task (`TIER` in the handoff, `references/model-routing.md`): Claude Code passes the `Agent` tool's `model` parameter on every spawn (`CLAUDE_MODEL_<TIER>` in `core/tiers.env`); the other hosts run the role as a separate process with `run-role.sh --tier light|standard|strong` (Codex: reasoning effort). Cursor and Gemini have no tier models until you set them in `core/tiers.env`.

Output cap (`delegation.md`, "Keep this session thin"): `scripts/capped.sh` works on every host. The `guard-noisy` hook (asks when a command matches `NOISY_CMD_PATTERNS`) runs where the host has hooks: Claude Code, Cursor, Gemini and the OpenCode plugin; on Codex only the rule applies. `usage.sh context` reads a Claude Code transcript only.

Spawn and token budgets (`delegation.md`): Claude Code counts every `Agent` call in the `guard-budget` hook; the other hosts count at `run-role.sh` (exit 3 when over, `--ignore-budget` after the user agreed). A host that reports no tokens leaves the token budget silent; the spawn limit works everywhere.

Verdict recording (SKILL.md §5): Claude Code records in the `SubagentStop` hook, which runs `parse-verdict.sh --record` itself, so do not pass `--record` there; every other host passes `--record` to `parse-verdict.sh`. At `high` risk only a registered run counts (F04): Claude Code via its hooks, any host via `run-role.sh`, which registers the spawn and records the verdict itself; `workflow.sh capabilities` lists what each path really enforces.

Agent contracts (`references/contract.md`, `CONTRACTS=1`): Claude Code validates a contracted spawn and its answer in the `check-contract` hook (advisory: it never blocks, an invalid handoff asks first in `strict`); every other host gets the same checks from `run-role.sh` (exit 4 / 5) or by calling `scripts/contract.sh` by hand. Codex, OpenCode, Cursor and Gemini have no subagent-result hook in the kit, so a subagent they start inside their own session is not checked. The OpenCode plugin and `adapt.sh` (Cursor, Gemini) do not carry the contract hook.

Role instructions are identical on every host (generated from `core/roles/`). Read-only roles are enforced per host (tools list, sandbox, permissions or `readonly`). When a host cannot isolate a role, the orchestrator still follows the independence rule: the verifying pass reads only the handoff artifacts, in a fresh subagent, process or session.
