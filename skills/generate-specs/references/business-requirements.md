# business-requirements.md

One document in `specs/<id>/` that puts the developer, the analyst, the customer and the PM in front of the same page. It is the detailed, readable form of `proposal.md` and `design.md`, with the acceptance criteria and the task split on top. It is a **view**: nothing in it is new, and when it disagrees with a spec file the spec file wins (the single source of truth is the spec). Written by the `requirements-writer` role in a fresh subagent; the reviewers of the output (`review.md`, part 2) read it with the rest.

The first line, unchanged, is the marker `sdkit review lint` looks for:

```
<!-- sdkit: derived view of proposal.md, design.md, specs/ and tasks.md; the spec files win on a conflict -->
```

## Sections (in this order; the prose in `ANALYST_LANGUAGE`)

1. **Title and summary.** One paragraph a customer or a PM can stop reading after: what is built, for whom, why it matters, what is not part of it.
2. **Purpose and goals** (from `proposal.md`: why, what changes).
3. **Scope.** In scope, and out of scope (the non-goals), as two short lists.
4. **Stakeholders and roles.** Who is affected or decides, and the roles that build it (from `roles.json` and `design.md`'s `## Roles`: what each does, in a line).
5. **Business context and problem.** Today's situation and what is missing.
6. **Business requirements.** A table: `R<n>` | requirement | why it matters | the ACs that verify it. Every active AC is in some row.
7. **The process in words.** The main flow, then the alternative and failure flows, in the order a person meets them. A short Mermaid diagram only when it makes a flow clearer.
8. **Rules and constraints.** Limits, security, privacy, performance and compliance statements the spec makes, each with its AC.
9. **Decisions.** `D<n>` | the decision | why | the alternatives that were rejected (from `design.md` and `decisions.md`), in plain language.
10. **Assumptions, dependencies and risks.**
11. **Open questions.** `Q<n>` | the question | who answers | the ACs it gates (a gated AC keeps its `(pending Qn)` marker where it is listed).
12. **Acceptance summary.** Every AC grouped by capability: id, the scenario title and its outcome in one line. A withdrawn AC stays, marked withdrawn.
13. **Work by role.** For each picked role, what it delivers for this spec (from `tasks.md`'s role sections), in two or three lines, without the task numbers.
14. **Glossary.** The terms a non-engineer would stop at.

## Rules

- **Derived, not invented.** A section the spec has nothing for holds one line saying so ("Not specified in the spec", in the output language). A gap the writer sees is reported to the analyst, never filled in.
- **Ids exactly as the spec writes them** (`AC-`, `R`, `D`, `Q`), never renumbered; every active AC appears; a withdrawn one is marked.
- **Short sentences, business meaning first.** It may be long, but each section opens with its point.
- **Language.** Prose in `ANALYST_LANGUAGE`; ids, markers, keywords and file names English.
- **Mechanical check.** `sdkit review lint <id> --target specs/<id>` fails when the marker is missing, an AC it cites is not defined, or an active AC does not appear.

## When the spec changes

The file is regenerated from the spec, not patched by hand, whenever the spec changes (`update-specs` before approval; after approval `sdkit spec apply` first, then the refresh): the writer runs in **refresh** mode on the file and the changed spec, keeps every other sentence and id, and the revision's review covers it.
