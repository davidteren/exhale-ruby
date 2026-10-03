# Changelog

## 0.1.0

First release. `exhale dry` sweeps the whole codebase for duplicated Ruby and HTML ERB and fails while any copy isn't kept by the Contract.

- Units from Prism (methods, Rails DSL bodies, concerns) and Herb (HTML ERB templates), normalized so the names of operations survive and the names of things become markers.
- Rarity-weighted Jaccard over subtree fingerprints, with exact prefix filtering for whole units, exact subtree digests for copied fragments, and statement-run seeds for code lifted out of the middle of a method.
- The verdict depends only on the commit. The merge base labels each finding introduced, shifted, already there, kept or contracted, and `--introduced-only` is the on-ramp for codebases that don't sweep clean yet.
- The Contract under `contract/<primitive>/` keeps deliberate duplication (`parallel`), maps primitives to code (`covers`) and holds settings (`settings`). Stale clauses and unknown references fail the gate.
- Text, JSON and EDN reports. EDN uses the shape Uncle Bob's dryer writes.
- exhale ships with its own Contract (64 obligations, all executable), a clean run on itself, and a mutation gate where every Mutineer mutant is killed or listed with a reason.
