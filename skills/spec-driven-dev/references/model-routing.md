# Model routing by task size

Read this when you write the execution plan (plan section 5) and again at each spawn. Models are chosen per task, not only per role:
a one-file rename and a new locking scheme should not run on the same model.

## Size field
`tasks.md` and plan section 5 carry an optional `size:` per task (format in `parallel.md`):
```
- [ ] T3 Add retry to the importer | role: developer | size: medium | writes: services/importer/ | after: T1
```
| size | tier | typical task |
|---|---|---|
| `small` | `light` | mechanical and local: rename, move, config or docs edit, adding a test case to a known pattern; 1 to 2 files, nothing to decide |
| `medium` | `standard` | new logic inside a known design: a handler, a query, a table-driven test set; a few files in one area |
| `large` | `strong` | needs judgement: a design decision, a race/ordering or concurrency problem, a security-sensitive path, a cross-module change |

No `size:` means no override: the role's own tier applies (`AGENT_<ROLE>_TIER` in `sdkit.env`, else `core/roles/`), the behaviour before this field existed. With `ROUTING=on` and `ROUTE_POLICY=tiered` the size is required: `sdd.sh advance proposed` refuses a `tasks.md` line that names a `role:` and has no `size:` (`ROUTE_REQUIRE_SIZE=0` opts out).

## Role tiers
A role's own tier is `AGENT_<ROLE>_TIER` in `<project-dir>/sdkit.env` (`AGENT_ENGINEER_TIER=standard`; the file lists every role with its default). On Claude Code a role whose tier differs from the one in its agent file must be spawned with the `model` of that tier: the session start tells you which, and the `Agent` hook refuses a spawn with another model. `run-role.sh` and `route.sh` apply it themselves. The independent roles can go up, never below their own tier.

## How to size
Take the highest size any of these points to:
- **Files touched**: 1 to 2 small; a handful in one area medium; many files or several modules large.
- **Mechanical or new logic**: copy-a-pattern work is small; new behaviour is medium; behaviour whose shape is not settled is large.
- **Risk**: a `high` risk label raises every task touching the risky path to `large`; `low` risk rarely needs more than medium.
- **Design decision left open**: if the plan does not already fix the interface and the approach, the task is `large`.
- **Race or ordering**: shared state, concurrent writers, migration order, retries with side effects: `large`.

When in doubt between two sizes, take the larger. A wrong `small` costs a retry; a wrong `large` costs tokens.

## Floors
- Independent roles (`verifier`, `reviewer`, `security-auditor`) never run below their own tier, whatever the size says; a larger size raises them.
- `high` risk verification is always `strong` (`verifier-deep`).
- Everything else follows the size: `small` may lower a `standard` role to `light`, `large` raises it to `strong`.

## Show it in the plan
List the size of every task in plan section 5 and the resulting tier mix in section 6 (for example "2 light, 3 standard, 1 strong").
The user can change any size at the plan gate like any other plan item; apply it and log it in section 8. Do not change sizes silently
after approval; if a task turns out larger, tell the user and ask.

## Applying it per host
- **Handoff**: put `TIER: light|standard|strong` in the brief (`handoff.md`); omit it when the task has no `size:`.
- **Claude Code**: pass the `model` parameter of the `Agent` tool on every spawn, taken from `CLAUDE_MODEL_<TIER>` in `core/tiers.env`
  (`haiku`, `sonnet`, `opus` by default). The role file's own `model:` is only the default.
- **Codex, OpenCode, Cursor, Gemini**: the model in the role file is fixed, so a task that needs another model runs as its own process:
  `<kit>/scripts/run-role.sh <role> --handoff F --cwd D --host H --tier <light|standard|strong>`. The model is `--model`, else
  `RUN_ROLE_MODEL_<TIER>` (`sdkit.env`), else `<HOST>_MODEL_<TIER>` (`core/tiers.env`). Codex changes reasoning effort (`CODEX_EFFORT_<TIER>`) instead.
- **Cursor and Gemini** have empty tier models in `core/tiers.env` (the kit does not guess model names); until you fill them in, `--tier` leaves the session's model in place.
- Sizing only chooses the model. How many tasks run at once is `MAX_PARALLEL` (`parallel.md`).

## Deterministic routing (opt-in)
With `ROUTING=on` (`sdkit.env`), `run-role.sh` takes host, model, tier, budget and retry/escalation from `scripts/route.sh` instead of the rules above, and `route.sh explain --role <role>` shows
the decision without running anything. The floors above are enforced in code there. Exit 7 from `run-role.sh` means valid evidence already exists (success-like, nothing to retry); exit 8 means routing declined to run and no valid result exists (duplicate, a BLOCK that stands, retries exhausted, optional role skipped). Neither means verified by itself: the phase gate (`sdd.sh evidence`) decides. See `docs/design-routing.md`.
