# CLI

The command line is the only way CI meets exhale, so a typo there must never pass for a clean run.

## Obligations

- **L1** `exhale` and `exhale dry` run the duplication check. `exhale dry explain A B` scores two units with the same file list and weights the gate uses.
- **L2** An unknown option, an unknown format, or a positional argument that isn't an existing path exits 2.
- **L3** A `--base` that resolves to no commit exits 2, including a value that looks like a git option, and so does `explain` given an unknown format or base.
- **L4** Settings come from the Contract. Flags override them for a local run only.

```covers
Exhale::CLI
```
