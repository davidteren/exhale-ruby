# Fingerprint

A fingerprint is the digest of one subtree of a shape. Its weight says how rare that subtree is in the tree being checked.

## Obligations

- **F1** Equal structure gives equal digests in every process and on every platform: the first 8 bytes of SHA-256 over the node's kind, label and child digests.
- **F2** A fingerprint's weight is ln(1 + 1000 / count), stored as a fixed-point integer computed with BigDecimal. It depends on nothing but its own count.
- **F3** A score is an exact rational, and a pair meets a threshold by exact comparison.

```covers
Exhale::Dry::Fingerprints
Exhale::Dry::FNode
Exhale::Dry::Weights
Exhale::Dry::Index
```
