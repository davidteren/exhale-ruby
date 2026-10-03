# Matcher

The matcher finds every pair of locations over the threshold.

## Obligations

- **M1** Every pair of whole units that scores at the threshold or above ends up in the same finding, and no match below the threshold is reported, whatever settings each unit's primitive gives it. Identical units join their group as a star, so the pairs among them are connected rather than listed.
- **M2** A fragment copied whole is found however many times it was copied.
- **M3** A run with at least three identical consecutive statements, copied into another sequence, is found however many times it was copied. Around that exact core the run extends across at most one mismatched statement, and when the extended run scores under the threshold, the exact core is judged on its own.
- **M4** A match lying inside a larger match between the same two units is dropped.
- **M5** Two copies of one fragment inside the same unit have different keys.
- **M6** Each pair is judged by the lower threshold and the lower size floors of its two sides, the settings that flag more.
- **M7** Cost stays close to linear in the number of identical copies of a unit.
- **M8** The two sides of a match never share a line of the same file, whole units included, so code can't be reported as a copy of itself.

```covers
Exhale::Dry::Matcher
Exhale::Dry::Location
Exhale::Dry::Match
```
