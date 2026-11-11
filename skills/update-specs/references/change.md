# Applying a change

- Start from `spec.sh changed <id>` and `git diff <last published sha> -- specs/<id>`. Treat the diff as the instruction; do not re-derive documents from the pre-spec.
- Map each change to dependents: a changed AC touches its feature spec, any PRD requirement and ADR that cite its id; a changed ADR touches the features it constrains.
- Edit minimally. Keep AC ids stable: a changed criterion keeps its id; a new one gets the next free number; a removed one is marked `withdrawn`, never reused.
- Inconsistency (two documents disagree): the document the analyst edited wins; fix the other, and say so in the PR body.
- Approved decisions: if the spec was approved (status approved, version 1.x), a change that reverses or weakens an ADR or AC is raised with the user first; when agreed, supersede through a new ADR rather than editing history.
- Tech Lead change requests: answer each one (done, rejected with reason, needs the analyst), reflect it in the files, and list them in the PR body file passed to `publish`. Do not resolve review threads on the host.
- The PR body file: summary of the change, version, review result, list of change-request answers.
