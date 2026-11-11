---
name: generate-specs
description: Analyst environment. Turns a named pre-spec (raw input in the git-ignored pre-spec directory) into reviewed, versioned specs - PRD, ADRs where a decision is made, feature specs with testable acceptance criteria and stable AC ids - runs an independent EGM review as an internal step, and publishes branch spec/<id> plus one PR to main for the Tech Lead. Use when an analyst has a pre-spec and wants specs ready for approval.
license: MIT
metadata:
  author: spec-driven-kit
  version: "1.0"
---

Drives the analyst from a pre-spec to a reviewed spec PR. Mechanics (hash, branch, PR, version, metadata) are `<kit>/scripts/spec.sh`; the review evidence is `<kit>/scripts/review.sh`. Never write `spec.meta.json` or the review state by hand. `<kit>`, how to ask the user and how to start a fresh subagent: `spec-driven-dev/references/hosts.md`. Read a reference only at the step that names it.

**Two rules that never bend.** (1) PASS from the review is not approval: the Tech Lead approves by merging the PR; you never approve, merge or push to `main`. (2) The pre-spec directory (`PRESPEC_DIR`) is input only; nothing from it is committed or pasted verbatim into a published file without the analyst having seen it.

## Steps

Print `[sdkit] generate-specs - Step <n>/7: <name> - started|done` per step.

1. **Validate the input.** `sdkit prespec check <name>` must pass (exists, not empty, git-ignored, untracked). Pick the spec `<id>` (plain name, default the pre-spec name) and run `spec.sh init-meta <id>`. If `specs/<id>/` already has a published version, stop and use `update-specs`.
2. **Gaps.** Read the pre-spec and `<project-dir>/project.md`. Put unresolved questions to the user (host question tool, at most 4 per round, a default first). Do not invent requirements.
3. **Generate** (`references/generate.md`): PRD, ADR only where a real decision is made, feature specs with acceptance criteria that carry stable ids (`AC-<feature>-<n>`, never renumbered). Each criterion is testable: given/when/then with an observable result. Generation runs in its own subagent with only the pre-spec and the templates as input.
4. **Review as an internal step** (`references/review.md`): follow EGM `egm-review-loop` in this thread, per artifact, with `review.sh plan/begin/record`. Reviewers run in FRESH subagents, never the generator. A host that cannot start a fresh subagent records `NOT_RUN` and stops; it never records PASS.
5. **Analyse and correct.** Triage every finding (fix, reject with reason, escalate). Fix within the round cap (`review.sh begin` refuses past `SPEC_REVIEW_MAX_ROUNDS`); re-review only the artifacts that changed. An unresolved BLOCKER goes to the human with the finding text; `review.sh accept` is theirs to run, never yours.
6. **Publish.** `spec.sh publish <id> --title "<title>" --body-file <file>` (version 0.1, branch `spec/<id>`, one PR to `main`, reused on a re-run). It refuses without a fresh PASS bound to the current content. Never force-push.
7. **Present the outcome**: PR URL, version, review verdict and round, accepted exceptions, open questions. State plainly that review PASS is not approval and the Tech Lead decides.

If `spec.sh publish` fails, the version is untouched; fix the cause and run it again.
