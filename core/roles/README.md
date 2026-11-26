# Roles

One neutral definition per role. `sdkit dev adapters` turns them into the Claude Code agent files (`agents/`) and the role files
for Codex, OpenCode, Cursor and Gemini CLI (`adapters/<host>/`), the emitters are in `internal/emit`. Edit roles here, never the generated files.

## File format

```
---
name: <slug>
description: <when to use it; shown to the host's router, keep it one sentence>
kind: subagent | session     # session = played by the main conversation, no agent file is generated
access: read-only | docs | tests | code | infra
tier: light | standard | strong
independent: true | false    # true = must never review its own work
deep: strong                 # optional: also generate <name>-deep, the same role at this tier (verifier only today)
---
<instructions, host-neutral>
```

| Field | Meaning |
|---|---|
| `access` read-only | reads and runs read-only commands |
| `access` docs / tests / code / infra | also edits the named class of files (the body says which) |
| `tier` | model cost class, the default for the role; a task's `size:` can override it per spawn (never below it for independent roles, see `skills/spec-driven-dev/references/model-routing.md`). `core/tiers.env` maps it per host (`CLAUDE_MODEL_*`, `CODEX_EFFORT_*` / `CODEX_MODEL_*`, `OPENCODE_MODEL_*`, `CURSOR_MODEL_*`, `GEMINI_MODEL_*`; empty = inherit the session's model) |
| `independent` | documented in the generated header; `spec-driven-dev` never gives it the implementer's reasoning |
| `deep` | generates an extra file `<name>-deep` at the given tier; `high` risk uses `verifier-deep` |

How `access` becomes a host setting (shell allow-list and tool names: `core/hosts.env`):

| Host | Output | read-only | other access |
|---|---|---|---|
| Claude Code | `agents/<role>.md` | tools `Read, Grep, Glob, Bash`, plus the `guard-readonly` hook | adds `Edit, Write` |
| Codex | `adapters/codex/agents/<role>.toml` | `sandbox_mode = "read-only"` | `workspace-write` |
| OpenCode | `adapters/opencode/agents/<role>.md` | `edit: deny` and a shell allow-list | `edit: allow` |
| Cursor | `adapters/cursor/agents/<role>.md` | `readonly: true` | `readonly: false` |
| Gemini CLI | `adapters/gemini/agents/<role>.md` | `tools:` list without write tools | adds write tools |

The Codex, OpenCode, Cursor and Gemini formats follow each tool's documentation and are not validated on live installs.

Edit scope is enforced by the instructions, by `frozen-tests` and `guard-protected` where the host supports hooks, and by the
git hooks in `adapters/git/` everywhere else.

`<project-dir>` in role text is the project-side directory (`.sdkit/`, the directory that holds `sdkit.env`). `sdkit dev adapters` adds that explanation to every generated role, so source files just use the placeholder.

## The roster

| Role | Access | Tier | Job |
|---|---|---|---|
| `orchestrator` | session | strong | Runs the workflow, splits work, owns the plan and the final summary |
| `analyst` | read-only | standard | Judges whether the task prompt is complete; lists gaps and questions |
| `scout` | read-only | light | Cheap codebase lookups: where is X, who calls Y |
| `engineer` | docs | strong | Technical design, options and trade-offs, ADRs, race/ordering scenarios, test strategy |
| `developer` | code | standard | Implements to the agreed tests and design |
| `test-writer` | tests | standard | Writes tests, never production code |
| `devsecops` | infra | standard | CI/CD, container, IaC, dependency and secret hygiene, least privilege |
| `reviewer` | read-only | standard | Rule and pitfall review of a diff |
| `security-auditor` | read-only | standard | Attack-oriented review of a diff |
| `verifier` | read-only | standard | Independent Definition-of-Done gate |
| `requirements-writer` | docs | standard | Writes and refreshes `specs/<id>/business-requirements.md`, a derived view of the spec for developers, analysts, customers and PMs; that one file only; analyst environment |
| `flow-modeler` | docs | standard | Models a published spec as a process (lanes, steps, decisions, screen candidates) for `sdkit design build`; its one model file only; analyst environment |
| `prespec-gaps` | read-only | light | Scans a pre-spec before the draft and classes every open point as decision, fact or default (`sdkit prespec gaps`); analyst environment |
| `spec-reviewer` | read-only | standard | Independent review of a spec document (PRD, feature spec, ADR) against a `review.d/` checklist; analyst environment |

Fourteen roles are defined; `orchestrator` is a session role, so thirteen subagent roles plus the generated `verifier-deep` (strong tier, used for `high` risk) give fourteen files per host.
Roles never call other roles: they end with `NEEDS-LOOKUP: <question>` and the orchestrator runs `scout`. `sdkit run-role` can run any role as a separate process on any host.
Every subagent keeps its answer to 15 lines plus its structured block. A writing role puts its long form at the handoff's `OUT:` path; a read-only role cannot, so the orchestrator stores its answer (`sdkit run-role --out`).

Independence rule: the role that implements (`developer`, `devsecops`) is never the role that verifies (`verifier`, `reviewer`,
`security-auditor`), and an independent role never receives the implementer's reasoning, only artifacts.
