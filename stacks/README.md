# Stacks

A stack = the language/framework part of the kit: how to verify, format and detect a project, plus default rules and example
policies. Everything else (roles, workflow, guards) is stack-independent. One `STACK` per repo (`STACK=` in `sdkit.env`).

```
stacks/<stack>/
  detect.sh              exit 0 when <dir> ($1) is a project of this stack (init.sh probes stacks in order)
  scripts/verify.sh      thin entry: finds scripts/verify-core.sh, sources steps.sh, calls verify_main "$@"
  scripts/steps.sh       STACK_SOURCE_RE and stack_run (the stack's checks); see scripts/verify-core.sh
  scripts/fmt.sh         format one file ($1); always exit 0 (used by the post-edit hook; no-op if the tool is missing)
  scripts/tools.sh       tools the stack needs, one per line:  required|<command>|<install hint>   or   optional|<command>|<hint>
                         ($1 = the repo root, passed by doctor and the check-tools hook; a stack may ignore it)
  scripts/verify-lib.sh  (go only today) helpers for verify.d policies; shared by all stacks via scripts/verify-lib.sh when absent
  permissions.txt        Claude Code permission patterns (one per line) added to settings.json "allow" for this stack
  rules/*.md             default conventions copied into <project-dir>/rules/ (project-owned afterwards)
  verify.d.example/*.example   example project policies (FAIL:/WARN: protocol, see verify-lib.sh)
  <config files>         e.g. golangci.yml, copied to <project-dir>/
  known-pitfalls.md      optional seed for <project-dir>/known-pitfalls.md (stack-specific bug classes); init uses
                         templates/known-pitfalls.md (header and format, no entries) when absent
```

## stack_run contract (steps.sh)
Variables from the core: `ROOT`, `KIT_DIR`, `FAST` (1 = cheap checks only), `CHANGED` (all changed files, one per line),
`CHANGED_SRC` (those matching `STACK_SOURCE_RE`), `MERGE_BASE`, `BASE_REF`; project settings from `sdkit.env`.
Helpers: `step "<title>"`, `fail "<msg>"`, `warn "<msg>"`. Rules:
- verify only what changed (nearest build file / package of each changed source file), not the whole repo;
- `FAST=1` must be cheap: typecheck/compile only, no tests, no lint, no full build;
- a missing tool is a `warn` (skipped), never a `fail`, unless the check cannot run without it;
- print little: the core appends the summary line, callers `tail -40`.
