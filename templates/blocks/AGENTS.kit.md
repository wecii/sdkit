Spec-driven development with spec-driven-kit. This block is a map and the non-negotiable rules; details live in the linked files.

## Start here
- New task: use the `spec-driven-dev` skill (`$spec-driven-dev` in Codex, `/spec-driven-dev` in Claude Code). If your tool has no skills, read `.agents/skills/spec-driven-dev/SKILL.md` and follow it.
- After fixing a bug: `incident-to-rule`. Setup check: `scaffold-doctor`.
- Project facts, release flow, **risk rubric**: `__KIT_DIR__/project.md`. Machine config: `__KIT_DIR__/__KIT_ENV__`. Conventions: `__KIT_DIR__/rules/`. Past bug classes: `__KIT_DIR__/known-pitfalls.md`. Decisions: `__KIT_DIR__/adr/`.
- Verify any change: `__KIT_DIR__/scripts/verify.sh` (`--fast` = vet+build). Project checks: `__KIT_DIR__/verify.d/`.
- Where things live: everything shared is in `__KIT_DIR__/` (committed, including the team's settings in `__KIT_DIR__/__KIT_ENV__`); `__KIT_DIR__/sdkit.local.env` and `__KIT_DIR__/work/` are personal. New project knowledge goes there (`memory.sh add`, `incident-to-rule` for pitfalls, `adr/` for decisions), never into host folders such as `.claude/` or `.codex/`.
- Project memory (only if `MEMORY=1` in `__KIT_DIR__/__KIT_ENV__`): read `__KIT_DIR__/memory/INDEX.md` at the start, open an entry only when its line is relevant. Details: `spec-driven-dev` `references/memory.md`.

## Rules that hold even without hooks
1. Confirm the risk label (`low`/`medium`/`high`) with the user; never assign it silently.
2. No proposal before the user approved the plan. Every Definition of Done item names how it is verified (test-first mindset: `__KIT_DIR__/rules/test-first.md`).
3. The role that implements never declares the work verified. `medium`/`high` get an independent `verifier` that sees only artifacts.
4. Never read or write secrets (`SECRET_GLOBS` in `sdkit.env`). Never edit tests listed in `__KIT_DIR__/.frozen`. Ask before touching `PROTECTED_PATHS`.
5. Never run state-changing commands against production. Never force-push or reset hard.
6. Token economy (`__KIT_DIR__/rules/token-economy.md`): cheap checks first, hand over paths not conversation, trim output, parallelize only disjoint work.

## Roles (subagents live in the host's agents directory: `.codex/agents/`, `.opencode/agents/`, `.cursor/agents/`, `.gemini/agents/`, Claude `agents/`)
`analyst` completeness of the task prompt · `scout` cheap lookups · `engineer` design and test strategy · `developer` implements · `test-writer` tests only · `devsecops` pipeline/infra/supply chain · `reviewer`, `security-auditor`, `spec-reviewer` (spec documents, analyst environment), `verifier` (`verifier-deep` for high risk) independent and read-only. Roles never call roles. The main session is the `orchestrator`. Task state: `__KIT_DIR__/scripts/state.sh`; a role as a separate process: `__KIT_DIR__/scripts/run-role.sh`.

## Guards
Git hooks enforce the spec-driven phase gate (no code before a proposal and a failing test, no push or PR before verification; `SDD_MODE` in `__KIT_DIR__/__KIT_ENV__`, default strict), secrets, frozen tests, protected paths and protected-branch pushes for every tool. Enable once per clone: `git config core.hooksPath .githooks`.
