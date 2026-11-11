---
name: generate-specs
description: Analyst environment. Turns a named pre-spec (raw input in the git-ignored pre-spec directory) into reviewed, versioned specs - PRD, ADRs where a decision is made, feature specs with testable acceptance criteria and stable AC ids - runs an independent EGM review, then outputs an OpenSpec change (proposal.md, design.md, tasks.md, specs/) via openspec-propose, and publishes branch spec/<id> plus one PR to main for the Tech Lead. Use when an analyst has a pre-spec and wants specs ready for approval.
license: MIT
metadata:
  author: spec-driven-kit
  version: "1.1"
---

Drives the analyst from a pre-spec to a reviewed spec PR whose content is an OpenSpec change (proposal, design, tasks, specs). Mechanics (hash, branch, PR, version, metadata) are `<kit>/scripts/spec.sh`; the review evidence is `<kit>/scripts/review.sh`. Never write `spec.meta.json` or the review state by hand. `<kit>`, how to ask the user and how to start a fresh subagent: `spec-driven-dev/references/hosts.md`. Read a reference only at the step that names it.

**Two rules that never bend.** (1) PASS from the review is not approval: the Tech Lead approves by merging the PR; you never approve, merge or push to `main`. (2) The pre-spec directory (`PRESPEC_DIR`) is input only; nothing from it is committed or pasted verbatim into a published file without the analyst having seen it.

## Language

Everything written for people (questions to the analyst, the documents, the PR body, the final report) is in `ANALYST_LANGUAGE` (`sdkit.env`, default `tr` = Turkish; `sdkit.local.env` wins). Machine-read parts stay English: step banners, AC ids, review verdicts and severities, file names, OpenSpec section keywords (`## Why`, `## What Changes`, `### Requirement:`, `#### Scenario:`, `WHEN`/`THEN`). Pass the language to the generator and to the reviewers.

## Steps

Print `[sdkit] generate-specs - Step <n>/8: <name> - started|done` per step.

1. **Validate the input.** `sdkit prespec check <name>` must pass (exists, not empty, git-ignored, untracked). Pick the spec `<id>` (plain name, default the pre-spec name). If `specs/<id>/` already has a published version, stop and use `update-specs`. The `openspec` CLI and `openspec/` must exist (`sdkit doctor`); if not, stop and say so.
2. **Gaps.** Read the pre-spec and `<project-dir>/project.md`. Put unresolved questions to the user (host question tool, at most 4 per round, a default first). Do not invent requirements.
3. **Draft** (`references/generate.md`): PRD, ADR only where a real decision is made, feature specs with acceptance criteria that carry stable ids (`AC-<feature>-<n>`, never renumbered). Each criterion is testable: given/when/then with an observable result. Generation runs in its own subagent with only the pre-spec and the templates as input. The draft lives in `<project-dir>/work/spec-draft/<id>/`, never in `specs/<id>/`.
4. **Review the draft** (`references/review.md`, part 1): follow EGM `egm-review-loop` in this thread, per artifact, under the review id `<id>-draft` (`review.sh begin <id>-draft --target <draft dir>`, `plan`, `record`). Reviewers run in FRESH subagents, never the generator. A host that cannot start a fresh subagent records `NOT_RUN` and stops; it never records PASS.
5. **Analyse, ask, correct** (`references/triage.md`). You are the orchestrator: do not hand raw findings to the human. Triage every finding into one of three classes and act on each:
   - **Fixable from what you have** (pre-spec, `project.md`, code, a clear review standard): fix it in the draft.
   - **Needs a decision or a fact only a person has** (a term's meaning, a security or scope choice, a missing owner/date/number): collect it. Ask the user in batches with the host question tool (at most 4 per round, the safest default first and marked), each question saying which finding it closes. Never guess it and never leave it as an open question just to turn the review green.
   - **Reject** with a written reason (the finding is wrong or out of scope).
   Then write the answers into the draft as decisions (a decision/ADR entry or the requirement itself, with the rejected alternatives), fix the rest, and open the next review round for the artifacts that changed. Asking questions does not use up a review round; only `review.sh begin` does. Repeat triage, ask, correct until PASS or the round cap (`review.sh begin` refuses past `SPEC_REVIEW_MAX_ROUNDS`). Only then, for a BLOCKER still open, give the human the finding text plus the options (fix by hand and raise the cap, or accept it as a visible exception); `review.sh accept` and the cap are theirs to run, never yours.
6. **Propose (the output).** Only after the draft review is PASS: invoke `openspec-propose` with the reviewed draft as its only input, so the result is an OpenSpec change, not loose markdown: `proposal.md`, `design.md`, `tasks.md` and `specs/<capability>/spec.md`. Place it at `specs/<id>/` (`references/propose.md`). The `AC-` ids, ADR decisions and traceability must survive unchanged. `tasks.md` is the implementation breakdown and must cover every AC; it is not the Jira task list (`generate-tasks` makes that later).
7. **Review the output and publish.** Run a fidelity round on `specs/<id>/` under the review id `<id>` (`references/review.md`, part 2): nothing lost, invented or renumbered against the reviewed draft, tasks cover every AC. Then `spec.sh init-meta <id>` and `spec.sh publish <id> --title "<title>" --body-file <file>` (version 0.1, branch `spec/<id>`, one PR to `main`, reused on a re-run). It refuses without a fresh PASS bound to the current content. Never force-push.
8. **Present the outcome**: PR URL, version, review verdicts and rounds (draft and output), accepted exceptions, open questions. State plainly that review PASS is not approval and the Tech Lead decides.

If `spec.sh publish` fails, the version is untouched; fix the cause and run it again.
