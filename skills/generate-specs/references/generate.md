# Generating the documents

Layout of the DRAFT under `<project-dir>/work/spec-draft/<id>/` (not `specs/<id>/`; the published layout is made at the propose step, `propose.md`): `prd.md`, `adr/NNNN-<title>.md` (only when a decision between real alternatives is made), `features/<feature>.md`. Use the project's templates when `<project-dir>` provides them; otherwise the section headings the review rubric (`sdkit review plan <artifact>`: `prd`, `adr`, `feature-spec`) checks.

- Every feature spec: purpose, scope and non-goals, behaviour, acceptance criteria, open questions.
- Acceptance criterion: `AC-<feature>-<n>`, one observable behaviour in given/when/then form. Ids are stable: once published they are never renumbered or reused; a removed criterion keeps its id marked `withdrawn`.
- **Roles section.** The analyst picked the roles for this spec (`roles.json`). Write a `## Roles` section in the design part (it becomes `design.md`): per picked role, what that role does for this spec in a few lines, and per AC the roles it needs (`AC-<feature>-<n>: backend, frontend, qa`). Name the contracts between roles (an API shape, an event, a migration) once, with the role that provides it and the roles that use it. A role with nothing to do is dropped from `roles.json`, not padded; an AC that needs a role not picked is a question for the analyst. This section is what `generate-tasks` splits the work by, so it is as exact as the ACs; the role sections of `tasks.md` (`propose.md`) are written from it and must agree with it (an AC lists the roles that have a task citing it).
- Link ADRs and PRD requirements to the ACs that verify them, so a change is traceable.
- Write what the analyst's pre-spec says; mark anything you inferred as an assumption and list it under open questions.
- Hand the generator subagent only: the pre-spec, the templates, `project.md`. It returns files, not a verdict on its own work.
- Write the prose in `ANALYST_LANGUAGE` (default `tr`); keep AC ids, headings' machine keywords and file names English. Tell the generator the language explicitly.

## Keep the numbering small and the document short

- Only four kinds of id: `AC-<feature>-<n>` (acceptance criteria), `R<n>` (PRD requirements, one list), `D<n>` (decisions, one list in the ADR) and `Q<n>` (open questions). Do not invent more tables (`V`, `M`, `C`, `A`, `N` ...): a message text or rule goes inside the AC or requirement that uses it. Every `R<n>` names its ACs and every AC names its `R<n>` and (when a decision shaped it) its `D<n>`, each once.
- A gated criterion carries the marker `(pending Qn)` or `(conditional Qn)` in its scenario title, and the question's row lists it. `sdkit review lint` checks that both ways.
- Write what the pre-spec asks for. A reviewer's "add this case" is a new requirement: the scope-growth warning of `review begin` and `triage.md` ask the analyst. Prefer a finding that removes, merges or shortens over one that adds.
