# Lattice Library Review Contract

A checklist for contributors and reviewers. A change to the Lattice library
preserves its [architecture](foundational-architecture.md) only if all of
these remain true:

1. One `ChainTree` owns one path and never recursively runs another chain.
2. Securing work depends on a content-bound directory commitment and target
   hit, not carrier validity or canonicity.
3. Work is joined by grind identity before quantities are totaled.
4. Non-genesis parent-state movement is forward through the immediate
   parent's executed set, and equality is no exemption.
5. Fork choice compares effective `trueCumWork`, then same-chain child block CID.
6. External ingress uses one import boundary; recovery replays durable facts.
7. Durable facts precede visible mutation.
8. Lattice retains consensus inputs; the node owns payload pruning.
9. Cross-chain interfaces carry proofs and exact parent facts, never trusted
   work totals or canonical-tip commands.

The rules behind each item are in the
[protocol specification](spec.md#12-invariants).
