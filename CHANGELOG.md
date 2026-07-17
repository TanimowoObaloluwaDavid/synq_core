## 0.1.0

- Initial release.
- Hybrid Logical Clock (`HLCTimestamp`, `HybridLogicalClock`).
- Nested last-writer-wins map CRDT with lazy container creation.
- RGA (Replicated Growable Array) list CRDT with deterministic
  concurrent-insert ordering.
- `ChangeBuffer` for causal buffering of out-of-order op delivery.
- `SynqStorage` interface + `InMemorySynqStorage` reference implementation.
- `SyncEngine` / `SynqPeer` for computing and applying bidirectional deltas
  between two replicas.
