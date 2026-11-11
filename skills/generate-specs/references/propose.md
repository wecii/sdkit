# Producing the OpenSpec change

The published output of `generate-specs` is an OpenSpec change, not loose markdown. The reviewed draft (`<project-dir>/work/spec-draft/<id>/`) is the input; `openspec-propose` writes the files.

1. Invoke the `openspec-propose` skill (host-specific invocation: `spec-driven-dev/references/hosts.md`) with change name `<id>` and the reviewed draft as the whole description. Tell it the prose language (`ANALYST_LANGUAGE`, default `tr`) and that OpenSpec keywords stay English. It creates `openspec/changes/<id>/`.
2. Move the result to the spec directory: `mkdir -p specs/<id>` and move the content of `openspec/changes/<id>/` into it (`proposal.md`, `design.md`, `tasks.md`, `specs/`, `.openspec.yaml` if present), then remove the empty `openspec/changes/<id>/`. `specs/<id>/` must hold exactly the change; no `prd.md` / `adr/` / `features/` loose files remain (a leftover draft file is a bug, not output). `SPECS_DIR` overrides `specs`.
3. Mapping, so nothing is lost:
   - PRD (problem, goals, non-goals, success criteria) -> `proposal.md` (Why, What Changes, Impact).
   - ADRs and design decisions with alternatives -> `design.md` (Context, Goals/Non-Goals, Decisions, Risks, Open Questions). Keep each decision's rationale.
   - Feature specs -> `specs/<capability>/spec.md`: one `### Requirement:` per behaviour, `#### Scenario:` per acceptance criterion, the `AC-<feature>-<n>` id kept in the scenario title. Ids are never renumbered; a withdrawn criterion stays, marked `withdrawn`.
   - `tasks.md`: numbered checklist, grouped by area, covering every AC (cite the AC ids). It is the implementation breakdown for the developer, not the Jira tasks.
4. Check with `openspec validate <id>` when the CLI offers it, and fix what it reports. Do not edit the OpenSpec skill's output beyond the move, validation fixes and the AC-id carry-over; content changes go back to the draft loop.
5. The draft directory is kept under `work/` (git-ignored) until the PR is open; it is never published.
