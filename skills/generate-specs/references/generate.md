# Generating the documents

Layout of the DRAFT under `<project-dir>/work/spec-draft/<id>/` (not `specs/<id>/`; the published layout is made at the propose step, `propose.md`): `prd.md`, `adr/NNNN-<title>.md` (only when a decision between real alternatives is made), `features/<feature>.md`. Use the project's templates when `<project-dir>` provides them; otherwise the section headings the review rubric (`review.sh plan <artifact>`: `prd`, `adr`, `feature-spec`) checks.

- Every feature spec: purpose, scope and non-goals, behaviour, acceptance criteria, open questions.
- Acceptance criterion: `AC-<feature>-<n>`, one observable behaviour in given/when/then form. Ids are stable: once published they are never renumbered or reused; a removed criterion keeps its id marked `withdrawn`.
- Link ADRs and PRD requirements to the ACs that verify them, so a change is traceable.
- Write what the analyst's pre-spec says; mark anything you inferred as an assumption and list it under open questions.
- Hand the generator subagent only: the pre-spec, the templates, `project.md`. It returns files, not a verdict on its own work.
- Write the prose in `ANALYST_LANGUAGE` (default `tr`); keep AC ids, headings' machine keywords and file names English. Tell the generator the language explicitly.
