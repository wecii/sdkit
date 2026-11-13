# Stage 4: decisions

Same discipline as `../../generate-specs/references/triage.md`: the person answers questions, not lists.

1. Group the judge output by decision: one question per decision, never one per finding. Items the evidence settles (identical text, a plain citation that still holds) are not asked: record them as resolutions with `by: "merge-specs"` and say so in the summary.
2. At most 4 questions per round. Each question names the item(s) it closes (`AC-login-social-3`), shows both sides in two lines, offers the options with the recommended safe default FIRST: keep both / A wins / B wins / write a combined AC (propose the text) / supersede through a new ADR / needs a business answer. In `ANALYST_LANGUAGE`.
3. "Needs a business answer": mark the AC `blocked by OQ-n` with an owner (as `generate-specs` does for an open question) and continue the merge.
4. Each answer becomes content: the decided text in the delta, plus one `resolutions` entry `{item, decision, why, by}` per item in every change that touched it. `by` is the person's name (`JIRA_USER` when they did not give one; if empty, ask them to set it in `sdkit.local.env`, never invent one).
5. A decision that reverses or weakens an approved AC or ADR is a new ADR, not an edit of the old one.
6. Repeat until no item is open. When the deltas share nothing, ask nothing: stage 3 and the review still run.
