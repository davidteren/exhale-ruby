# Revision

Revision is everything exhale asks git: the merge base, the base tree, touched lines and line ages.

## Obligations

- **V1** Touched lines are the lines the working tree adds or changes relative to the merge base. The user's diff settings don't move them (inter-hunk context included), git output is read as UTF-8 whatever the locale, and paths with spaces, special characters or newlines are read correctly.
- **V2** The base tree is read as raw blobs. `export-ignore` and `export-subst` attributes don't change it, and its symlinks and submodules aren't read, the same as at the head.
- **V3** Line ages ignore the user's ignore-revs settings and work in SHA-1 and SHA-256 repositories. Uncommitted lines are newer than anything committed.
- **V4** An app in a subdirectory of its repository works: exports, diffs and blame are scoped to the app.

```covers
Exhale::Git
```
