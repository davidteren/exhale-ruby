# Report

The report is written for the agent doing the exhale, and for tools.

## Obligations

- **R1** Text names both sides of every finding with path, lines and identity, marks which side is the copy, and gives one hint.
- **R2** The header counts every label and every Contract error, and says clean only when the run exits 0.
- **R3** JSON carries the exhale and normalizer versions and the same findings as data. EDN uses dryer's candidate shape.
- **R4** The same result renders byte for byte the same.

```covers
Exhale::Report
```
