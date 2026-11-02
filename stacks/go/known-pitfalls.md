# Known pitfalls

Bug classes that have already cost this project an incident. The independent verifier checks every diff
against this list. Add entries with the `incident-to-rule` skill. Each entry: symptom, root cause, how to spot it in a diff.

## typed-nil interface
- **Root cause:** a possibly-nil concrete pointer assigned to an interface-typed field or parameter is a non-nil interface, so `== nil` guards downstream never fire.
- **Spot it:** `var x SomeInterface = concretePtr`, or a constructor returning an interface where the concrete value can be nil. Fix: constructors return the concrete type; wire conditionally in `main`.
