# Stages 2 and 3: judgement and sweep

Run in ONE fresh subagent (a different one from whoever wrote the deltas). Give it only: `plan.json`, the base text of every capability named in `plan.json.changes[].capabilities`, every delta (`changes/<slug>/specs/**`), every `intent.md`. No chat history.

`plan.json` holds facts only (no interpretation): per change the ACs added/modified/removed, `expectsMoved` (ACs whose base text changed since the change was written), cited ACs and ADRs, capabilities; top level `collisions` (same new id in several changes) and `shared` (an AC touched by several). Do not compute "shared values" yourself from message text with scripts; compare by reading.

## Stage 2: per pair of changes, one relation

| Relation | Look for |
|---|---|
| independent | nothing in common |
| complementary | different ACs that fit together |
| overlapping | same AC edited by both, or same requirement/capability with overlapping behaviour |
| contradicting | different ACs that cannot both hold (also through a citation: B cites an AC that A changed; a precondition (`GIVEN`) that A removed; an unchanged base message, state or rule both depend on that one of them changes) |
| superseding | A replaces a decision (ADR) that B relies on |

For each non-independent pair: the items involved (AC ids), what each side says in one sentence, a proposed resolution and the alternatives, with reasons. Resolutions: keep both / A wins / B wins / a combined AC (give the text) / supersede through a new ADR / needs a business answer.

## Stage 3: sweep

Read the merged AC list of every touched capability once, as if both deltas were already applied. Report each AC of the base (touched or not) that is now inconsistent with a new or modified one, even if stage 2 saw no relation. A missed candidate in stage 2 must still be found here.

## Output

A list, one block per item: `item`, `relation`, `evidence` (quote the lines), `proposal`, `alternatives`. Nothing outside the files you were given is invented. An approved AC that the merged result reverses or weakens is flagged `needs ADR` (supersede, do not edit history).
