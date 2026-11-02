# Known pitfalls

Bug classes that have already cost this project an incident. The independent verifier checks every diff
against this list. Add entries with the `incident-to-rule` skill. Each entry: symptom, root cause, how to spot it in a diff.

Format (one `##` section per bug class):

```
## <short name>
- **Symptom:** what went wrong, as a user or an operator saw it.
- **Root cause:** why it happened.
- **Spot it:** what it looks like in a diff, and the fix.
```
