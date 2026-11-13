# Applying a change

- Start from `spec.sh changed <id>` and `git diff <last published sha> -- specs/<id>`. Treat the diff as the instruction; do not re-derive documents from the pre-spec.
- Map each change to dependents: a changed AC touches its feature spec, any PRD requirement and ADR that cite its id; a changed ADR touches the features it constrains.
- Edit minimally. Keep AC ids stable: a changed criterion keeps its id; a new one gets the next free number; a removed one is marked `withdrawn`, never reused.
- Inconsistency (two documents disagree): the document the analyst edited wins; fix the other, and say so in the PR body.
- Approved decisions: if the spec was approved (status approved, version 1.x), a change that reverses or weakens an ADR or AC is raised with the user first; when agreed, supersede through a new ADR rather than editing history.
- Tech Lead change requests: answer each one (done, rejected with reason, needs the analyst), reflect it in the files, and list them in the PR body file passed to `publish`. Do not resolve review threads on the host.
- The PR body file: summary of the change, version, review result, list of change-request answers.

# After approval: writing a change

- `spec.sh change new` made `changes/<slug>/{change.json,intent.md}`; `change.json` is the kit's (base, label, expects, touches), never edited by hand. Do not touch any base file: the branch writes only under `changes/<slug>/`.
- `specs/<capability>/spec.md` in the change is an OpenSpec delta: `## ADDED Requirements`, `## MODIFIED Requirements` (the whole requirement with all its scenarios, changed ACs inside), `## REMOVED Requirements` (the scenarios, or a bare requirement title). New AC ids take the next free number of their prefix (a sibling may pick the same one: the merge renumbers the later change, you do not).
- A removed AC is listed under REMOVED (the base keeps its id as `(withdrawn)`); a MODIFIED requirement must carry every active AC of the base requirement it replaces.
- `intent.md`: why, and what the author meant, in the analyst's words (merge-specs reads it). `tasks.md`: only the tasks this change brings, each naming the AC ids it covers; a modified AC always gets its own new task.
- `spec.sh change refresh <id> <slug>` computes `expects`/`touches` and refuses a delta with problems (it prints them: reused withdrawn id, MODIFIED of a missing AC, a dropped AC). Fix and run it again.
- A change that reverses or weakens an approved AC or ADR is raised with the user first; when agreed, supersede through a new ADR instead of editing history (every MODIFIED/REMOVED of an approved AC counts).
- The PR body file: summary, label, review result, answers to change requests. The status block is added by `publish`.
