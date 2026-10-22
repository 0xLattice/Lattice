# Lattice Protocol Specification

Version 0.1.0

This document is the normative consensus definition. For an intuitive reading
order, start with the [documentation index](index.md),
[architecture](foundational-architecture.md), and
[work and fork choice](consensus-fork-choice.md).

## 1. Overview

Lattice is a hierarchical proof-of-work protocol, not a single blockchain. Every chain may commit child blocks, and each child may do the same. One mined root therefore commits a nested block tree. **Nexus** is the single outermost chain and the entry point from outside the hierarchy; every absolute chain path begins with `Nexus`. Descendants inherit identity-bearing work from accepted ancestor graphs: the root CID identifies one grind, the root-most verified accepted-target bound along its proof fixes its quantity, and its sparse proof terminates at exactly one block per chain. Value moves across chains through a three-phase **deposit/receipt/withdrawal** protocol.

Each chain defines its own operations, `ChainSpec`, and chain policies, so chains are heterogeneous; only the organizing protocol -- block structure, proof-of-work, fork choice, and the cross-chain transfer rules -- is shared across the hierarchy.

All state is content-addressed using IPLD/CID. Blocks reference state via Merkle roots, enabling light client verification without full state replication.

The protocol hierarchy is not a recursive runtime topology. One Lattice process
owns one absolute chain path. Node software supervises separate processes and may
obtain evidence from parent or sibling peers, but those peers are availability
sources rather than validity or fork-choice authorities.

## 2. Notation

- `H(x)` -- SHA-256 hash of `x`
- `CID(x)` -- Content Identifier of serialized `x` (IPLD DAG-CBOR + SHA-256)
- `SMT` -- Sparse Merkle Tree
- `B[i]` -- Block at height `i` on a given chain
- `||` -- concatenation
- `>>` -- arithmetic right shift
- `U256` -- 256-bit unsigned integer

Consensus ingress accepts only the unique canonical textual spelling of a CID,
bounded by the child-proof wire's `UInt16` length capacity (65535 bytes) — a
structural encoding bound, not a policy cap. Honest DAG-CBOR + SHA-256 CIDs are
~59 bytes, far below it; the canonical round-trip is the real identity check, and
this bound only limits parse work on untrusted input to what the wire can carry.

## 3. Data Structures

### 3.1 Block

A block `B` is a tuple:

```
B = (
    version:          uint16,
    previousBlock:    CID(Block) | nil,
    transactions:     CID(MerkleDictionary<CID(Transaction)>),
    target:           U256,
    nextTarget:       U256,
    spec:             CID(ChainSpec),
    parentState:      CID(LatticeState),
    prevState:        CID(LatticeState),
    postState:        CID(LatticeState),
    children:         CID({directory: CID(Block)}), // one DAG-CBOR map node
    height:           uint64,
    timestamp:        int64,
    rewardRecipient:  CID(PublicKey) | nil,       // omitted from the encoding when nil
    nonce:            uint64
)
```

`rewardRecipient` is the account credited with the block's coinbase (reward
plus fees, section 8.2). `nil` burns that amount.

`children` is one plain DAG-CBOR map, so its canonical bytes are DAG-CBOR's.
Every key is a directory (visible ASCII, no `/`, within the child-proof wire's
`UInt16` length; the key grammar in section 3.5): a block is built only so, and
a received block whose `children` name anything else is protocol-invalid, as
is any child proof that steps through it. A map holds at most as many entries
as the DAG-CBOR decoder reads, which the encoder enforces.

### 3.2 Transaction

```
Transaction = (
    signatures: Map<PublicKeyHex, SignatureHex>,
    body:       CID(TransactionBody)
)
```

### 3.3 TransactionBody

```
TransactionBody = (
    accountActions:     [AccountAction],
    actions:            [Action],
    depositActions:     [DepositAction],
    receiptActions:     [ReceiptAction],
    withdrawalActions:  [WithdrawalAction],
    signers:            [CID(PublicKey)],
    nonce:              uint64,
    chainPath:          [string]
)
```

### 3.4 LatticeState

The world state is a 4-tuple of Sparse Merkle Tree roots:

```
LatticeState = (
    accountState:      SMT<CID(PublicKey) -> uint64>,
    generalState:      SMT<string -> string>,
    depositState:      SMT<DepositKey -> uint64>,
    receiptState:      SMT<ReceiptKey -> CID(PublicKey)>
)
```

### 3.5 ChainSpec

```
ChainSpec = (
    maxNumberOfTransactionsPerBlock: uint64,
    maxStateGrowth:                 int,
    maxBlockSize:                   int,
    premine:                        uint64,
    targetBlockTime:                uint64,     // milliseconds
    initialReward:                  uint64,
    halvingInterval:                uint64,
    halfLife:                       uint64,     // blocks; the schedule's half-life
    wasmPolicies:                   [WasmPolicyRef]
)
```

`maxBlockSize` bounds the canonical unique content bytes owned by one logical
block. The measured closure is the block root Volume boundary (including its
transaction and child indexes and their reference CIDs) plus every referenced
transaction Volume and transaction body. Each CID's canonical bytes count once.
The contents of the chain spec, wasm modules, parent blocks, all state Volumes,
child blocks, and import evidence are independent Volumes and do not count.

**No retarget clamp.** The absolute schedule of section 5.5 has no
per-retarget step to clamp and no protocol default. The only arithmetic bound
is the integer floor of the representation: a schedule that rounds to zero
yields target 1 (the smallest representable difficulty), never the unmineable
zero target. There is no protocol-imposed difficulty floor and no
protocol-wide difficulty constant. The positive `ChainSpec` values are chain-selected validity. Storage, transport,
bootstrap-spec, and parent-witness ceilings are node-local acquisition policy,
not common consensus constants. A node may decline to operate a chain whose
committed parameters exceed its resources without proving any block invalid.
Bounds required by a serialized field width and the deterministic WASM
execution profile remain protocol rules.

State keys use a small consensus grammar so radix work cannot grow with
attacker-chosen Unicode. Every key is non-empty visible-ASCII (`0x21`...`0x7e`);
directories are additionally separator-free (`/`-banned, to keep ReceiptKey
injectivity) and bounded by the child-proof wire's `UInt16` length. There is no
protocol length cap on account identifiers or general-state keys — key size is a
node storage concern, not a consensus rule. Derived account, deposit, and genesis keys remain
plain text and enumerable. Receipt-state storage alone uses
`SHA256("lattice/receipt-state/v1\0" || ReceiptKey)` as a 64-character lowercase
hex path, because a child may need that proof from a remote same-chain peer.
Withdrawal receipt identities must be unique within a transaction and their
proofs exact. The parent-receipt closure is validation witness data outside
`maxBlockSize` and materialized state growth; each node bounds acquisition
before decoding it.

### 3.6 Action Types

#### AccountAction

```
AccountAction = (owner: CID(PublicKey), delta: int64)
```

**Validity:** `delta != 0` and `delta != Int64.min`

#### Action (Generic Key-Value)

```
Action = (key: string, oldValue: string?, newValue: string?)
```

**Validity:** `key != ""` AND (`oldValue != nil` OR `newValue != nil`)

#### DepositAction

```
DepositAction = (nonce: uint128, demander: CID(PublicKey), amountDemanded: uint64, amountDeposited: uint64)
```

#### WithdrawalAction

```
WithdrawalAction = (withdrawer: CID(PublicKey), nonce: uint128, demander: CID(PublicKey), amountDemanded: uint64, amountWithdrawn: uint64)
```

#### ReceiptAction

```
ReceiptAction = (withdrawer: CID(PublicKey), nonce: uint128, demander: CID(PublicKey), amountDemanded: uint64, directory: string)
```

### 3.7 Keys

#### DepositKey

```
DepositKey = demander || "/" || amountDemanded || "/" || nonce
```

Used to index `depositState`. Uniquely identifies a pending cross-chain deposit by the demander's address, the amount demanded on the parent chain, and a nonce.

#### ReceiptKey

```
ReceiptKey = directory || "/" || demander || "/" || amountDemanded || "/" || nonce
```

Used to index `receiptState`. Associates a receipt on the parent chain with the child chain directory where the deposit originated.

## 4. Chain Hierarchy

### 4.1 Structure

Chains form a rooted tree:

```
    Nexus
   /     \
  A       B
 / \
A1  A2
```

A `directory` — the key under which a parent block's `children` index commits
a child block — is a **relative edge label**: it names the child only with
respect to that parent and is not stored in `ChainSpec`. A chain's canonical identity is its full **path** from Nexus, e.g.
`Nexus/Payments`. Siblings under different parents may reuse a
directory because their full paths differ.

### 4.2 Process Boundary

One validator process owns one absolute chain path, one accepted same-chain
forest, and one canonical projection. It contains no child validators. A target
miss at the current level is not admitted at that level; the grind reaches a
descendant only inside that descendant's `ChildBlockProof`, which the node may
route to a separately supervised descendant process.

## 5. Block Validation

### 5.1 Genesis Block Validation

A genesis block `B` is valid if and only if ALL of the following hold:

1. `B.previousBlock == nil`
2. `B.height == 0`
3. `B.timestamp <= validationContext.now`, where the import attempt captures
   `validationContext.now` once (node-local, retriable import — a future
   timestamp is deferred until real time reaches it, not permanently rejected)
4. `B.prevState == CID(emptyState())` and `B.rewardRecipient == nil` (a
   genesis mints only its premine; there is no reward to pay). A Nexus genesis
   commits `B.parentState == CID(emptyState())`. A child genesis commits its
   carrier's `prevState` and proves it by continuity (§5.3 step 6); that proof
   is the base case of parent continuity along the child chain. A child
   genesis whose `parentState` is `CID(emptyState())` — one carried by a
   genesis — is therefore invalid: it cannot anchor the induction
5. `B.nextTarget == B.target`, and the target `B` commits is met by the hash
   that secures `B` at its own level (§5.4, §9.5): a Nexus genesis by its own
   grind, a child genesis by the root grind of its `ChildBlockProof`, like any
   child block. `target == 0` is therefore invalid. By convention
   `GenesisCeremony` commits the canonical maximum (easiest) target, so the
   chain self-calibrates from block 1.
6. All transactions in `B.transactions` are fully resolvable
7. For each transaction `tx`: `tx.validateTransactionForGenesis()` returns true
   - Account and general actions are structurally valid
   - No deposit, receipt, or withdrawal actions are present
8. Every transaction's `chainPath` equals the runtime's absolute path
9. All transaction bodies pass the chain's policies
10. `|transactions| <= spec.maxNumberOfTransactionsPerBlock`
11. The block's state growth (section 6.6) is at most `spec.maxStateGrowth`
12. **Balance conservation (genesis)**:
    ```
    totalCredits <= premineAmount
    ```
13. **Post-state correctness**: Applying all actions to `prevState` (empty
    state) produces `postState`:
    ```
    proveAndUpdateState(prevState, allActions) == postState
    ```

Genesis authority: the Nexus genesis is the exact content-addressed block of
its configured genesis CID, and the root chain admits no other. A child chain
has no genesis authority: every child genesis carried by a valid
`ChildBlockProof` is a root of its weighed graph, and fork choice decides
among them (§9.4, §9.9). Signature and
declared-signer fields on genesis transactions carry no authority and are not
shape-constrained. All later transactions remain signature-strict. The
configured Nexus genesis CID's source of truth is the reference node's
`NexusGenesis`, pinned at each relaunch.

### 5.2 Nexus Block Validation

A non-genesis nexus block `B` with previous block `P` is valid if and only if:

1. `P` is resolvable
2. `B.spec == P.spec` (chain spec continuity)
3. `B.prevState == P.postState` (state continuity)
4. `B.height == P.height + 1`
5. `P.timestamp < B.timestamp <= validationContext.now`. The strict increase
   over the parent is the sole agreed-state timestamp rule (it makes timestamps
   strictly increasing along the chain, subsuming a MedianTimePast lower bound,
   which is therefore not imposed). The `<= now` bound is node-local, retriable
   import — a future block is deferred until real time reaches its timestamp,
   never permanently rejected. The attempt captures `validationContext.now` once.
6. `B.target <= P.nextTarget` (as hard or harder than scheduled, never easier),
   and `B.nextTarget` equals section 5.5's absolute schedule computed from the
   branch's height-1 anchor and `B`

Rules 2–6 are the header rules; how a failure of each is treated when a block
is admitted from its header — weighed and excluded, a proof-of-work failure,
dropped, or held — is section 9.9's header admission.
7. All transactions pass `validateTransactionForNexus()`:
   - Signatures are valid over the `lattice-tx-v1` envelope
   - Signers match signature public keys
   - Account debits authorized by signers
   - Receipt action withdrawers are signers
   - No deposit or withdrawal actions are present; a root chain has no parent
8. The chain's policies pass
9. Transaction count within limits
10. State growth within limits (section 6.6), measured over the transition
    of rule 12
11. **Fee rule and coinbase (non-genesis)**, section 8.2:
    ```
    totalCredits + totalDeposited <= totalDebits + totalWithdrawn
    ```
    and, when `B.rewardRecipient` is set, it is a canonical address and the
    coinbase amount `M` fits a positive `int64` delta
12. Post-state correctness: the transactions' actions, plus the coinbase credit
    of exactly `M` to `B.rewardRecipient` when it is set and `M > 0`, applied to
    `prevState` produce `postState`

**Nexus validation does not validate child blocks.** The `children` field is
committed by the root hash, but every child is validated by its own chain
process. Root-chain canonical acceptance is not a prerequisite for child proof
verification: a root that misses the nexus target may still be a valid carrier
for a descendant. An invalid child does not affect the root candidate or a
sibling.

### 5.3 Child Chain Block Validation

A child candidate `B` is imported with a `ChildValidationPackage` containing:

- a `ChildBlockProof` for the exact sparse directory path from the mined root to
  `B`;
- when `B.parentState` is not the empty state, one immediate-parent
  `ParentStateContinuityLink` for the exact old and new state CIDs — a genesis
  included.

The node authenticates immediate-parent facts and transports or caches them.
The child process still verifies the proof, transition, and fact fields. These
facts grant no authority over child validity or fork choice.

The vertical relationship is directional: a parent carrier commits the child in
its `children` index, while the child commits only the carrier's `prevState` as
`parentState`. The child does not identify the carrier block. Consequently,
cross-chain acquisition asks the authenticated parent process for a proof or
parent-issued fact keyed by child CID and chain path; it never attempts to invert
`parentState` into a parent block CID. Different valid proofs may contribute
different grinds for the same child.

Let `R` be the proof root and `h = proofOfWorkHash(R)`. Validation proceeds in
this order:

1. Recompute `CID(R)` and its proof-of-work hash.
2. Require the proof path to equal the runtime path below the outer root, consume
   every supplied proof entry, and require its terminal CID to equal `CID(B)`.
3. At every vertical edge, require the nested child's `parentState` to equal the
   carrier's committed `prevState`.
4. Require `h <= B.target`. Credit the target-derived quantity of the
   ROOT-MOST content-bound block on the path whose target is beaten by `h`,
   raised if greater by `B`'s own target (§9.5). Not the strongest such
   quantity: a deeper chain must not price a grind.
5. For genesis, require the complete genesis shape (§5.1), including
   `nextTarget == target`.
6. Require an exact continuity link proving that the immediate parent's
   executed set carried its state forward to `B.parentState` from the
   predecessor's `parentState` (from `emptyHeader`, the parent's own genesis
   pre-state, for a genesis): some block of the executed set produced
   `B.parentState`, and is or descends from a block that produced the
   predecessor's `parentState`. This applies at EVERY height, the genesis
   included (§5.1 rule 4). A non-genesis block may commit `emptyHeader` (no
   parent state) only while its predecessor does too; dropping back to it
   from a real anchor moves backward and is invalid. Step 3's terminal
   binding does not substitute for this — a carrier need not be imported,
   connected, valid or canonical, so it establishes no anchor.

   The link proves the anchor itself, not only its relation to the
   predecessor's: from `emptyHeader`, or between equal states, it proves that
   the executed set produced `B.parentState`. Equality alone is never
   evidence. The weighed tier imports a block without running these checks,
   so a weighed predecessor proved nothing, and a successor matching its
   unchecked claim would otherwise be imported with no evidence at all.

   Anchors therefore advance monotonically along the parent's history and
   never move backward or sideways. That is what makes a parent
   reorganization reorganize the child: a miner on the canonical parent
   anchors at its canonical state, which does not descend from an abandoned
   branch, so it cannot extend a child block anchored there (§8.1, "Receipt
   canonicity"). An ancestry test answers the link in time logarithmic in the
   parent's size, whatever the distance between the two states.
7. Apply the ordinary genesis or non-genesis transition rules to `B`, including
   withdrawal proofs against `B.parentState`.

Intermediate carriers need not satisfy their own target, transition, timing,
target-succession, import, connectivity, or canonicity rules. Their exact
bytes and directory commitments are sufficient for work verification. Parent
or sibling canonicity is not part of these checks. Once this package derives a
valid work fact, a later reorganization or unavailability in another process
cannot revoke it.

### 5.4 Proof-of-Work

The canonical proof-of-work preimage uses a zero byte between variable-width
fields and a fixed-width big-endian nonce:

```text
powPrefix(B) =
    decimal(B.version)       || 0x00 ||
    rawCID(B.previousBlock)? || 0x00 ||
    rawCID(B.transactions)   || 0x00 ||
    hex(B.target)            || 0x00 ||
    hex(B.nextTarget)        || 0x00 ||
    rawCID(B.spec)           || 0x00 ||
    rawCID(B.parentState)    || 0x00 ||
    rawCID(B.prevState)      || 0x00 ||
    rawCID(B.postState)      || 0x00 ||
    rawCID(B.children)       || 0x00 ||
    decimal(B.height)        || 0x00 ||
    decimal(B.timestamp)     || 0x00 ||
    recipientField(B)        || 0x00

recipientField(B) = empty                          if B.rewardRecipient is nil
                  = 0x01 || utf8(B.rewardRecipient) otherwise

proofOfWorkHash(B) = U256(SHA256(powPrefix(B) || uint64BE(B.nonce)))
```

The absent genesis predecessor contributes the empty field between separators.
The recipient's presence is encoded explicitly, so an absent recipient and a
present empty one never share a preimage (they are distinct CIDs, and a shared
preimage would let one grind weigh twice). Binding the recipient here, not only
through the block CID, is what stops a relayer from swapping it while keeping
the nonce. A block whose present `rewardRecipient` is not a canonical address is
structurally invalid: it is refused when its bytes enter admission or serve as
a child-proof root, before it can carry work.

For a nested tree, only the outer root's hash `h` is evaluated:

```text
workForHash(h) = h == 0 ? U256_MAX : h == U256_MAX ? 1 : floor(2^256 / (h + 1))
```

Every level compares the same `h` with its own target. `h <= target(B)` accepts
at that level; a miss leaves the block as a carrier for descendants. A node may
apply its own root-work floor before spending resources on acquisition, but
that is a non-punitive local preference and never changes validity.

Every accepting level establishes the conservative work bound
`workForTarget(target(B))`. Because proof validity is inclusive (`hash <= target`,
so `target + 1` hashes qualify), this is `floor(2^256 / (target + 1))`, computed as
Bitcoin's chainwork `(~target / (target + 1)) + 1` in 256-bit arithmetic (edge
cases: `target 0 -> 0`, `target max -> 1`). The exclusive `U256_MAX / target` form
over-credits by up to ~2x at tiny targets — exploitable now that a miner may
select any `target <= parent.nextTarget` — so it is not used. For one root CID the
root-most verified bound along its proof is credited (§9.5); a larger target is
easier and is less work.

### 5.5 Target Adjustment (Retargeting)

The scheduled target is derived from the parent. A block may meet that schedule
or voluntarily exceed it — **as hard or harder, never easier**:

```
B.target <= parent.nextTarget      // smaller target = harder = more work
```

A larger (easier) target is rejected; there is no minimum-target floor. Mining
harder than scheduled only adds weight at proportional cost and cannot lower
difficulty: `B.nextTarget` is recomputed from the *actual* `B.target` (below), so
overachieving ratchets the schedule harder, never easier — self-penalizing, not
gameable. A miner wanting the easiest future difficulty therefore mines exactly at
the scheduled `parent.nextTarget`.

Genesis has no parent-derived target. The `GenesisCeremony` commits the canonical
maximum (easiest) target by convention — every hash satisfies it, so genesis needs
no grinding, block 1's schedule is `max`, and the chain self-calibrates as early
miners voluntarily mine harder. What a genesis's target must satisfy is §5.1
rule 5. Each non-genesis block's
`nextTarget` is **absolutely scheduled from an anchor (ASERT)**: a pure function
of one anchor block and the block being targeted, with no window and no
intervening history.

```
anchor    = the height-1 ancestor of B on B's own branch
heights   = B.height - anchor.height
scheduled = spec.targetBlockTime · heights          // where the schedule says we are
elapsed   = max(0, B.timestamp - anchor.timestamp)  // where we actually are
drift     = elapsed - scheduled
halfLife  = spec.halfLife · spec.targetBlockTime

nextTarget = anchor.target · 2^(drift / halfLife)
```

Behind schedule (`drift > 0`) eases; ahead hardens; exactly on schedule holds the
anchor's target at any depth. One half-life of drift is exactly one doubling.
The exponential is evaluated in 16.16 fixed point with a cubic approximation over
the fractional part — the same shape Bitcoin Cash's `aserti3-2d` uses — so every
node computes the identical target from identical inputs. No floating point
appears on the path. The result saturates at both ends: it never exceeds the
maximum target and never reaches zero (a zero target would reject every hash).

**There is no window, and that is the point.** A windowed average carries its
last intervals as state, so a stretch of unusual block times
keeps steering difficulty long after it has passed, and a window perturbed at one
end oscillates as it drains. This reads only the anchor and the present block, so
it has nothing to drain: a disturbance stops mattering the moment it stops
happening. A window reaching back to genesis would also read the gap before block 1 as one
colossal solve time. Anchored at block 1, the schedule never reads that gap —
but block 1's own timestamp is the anchor, and the only lower bound on it is
`genesis.timestamp` (it must exceed its parent's, §9.9). A genesis MUST
therefore carry its chain's real launch time (a child deploy: the time of
deployment): a genesis stamped at epoch 0 lets block 1 anchor the schedule
decades in the past and saturate every later target.

`spec.halfLife` is the chain's committed responsiveness, in blocks: one
half-life of block time of drift is one doubling. It is the only difficulty
parameter besides `targetBlockTime`; there is no window and no clamp.

**The anchor is per-branch and inherited, never chain-wide.** A block imported at
height 1 anchors itself; every other block inherits its parent's anchor. Two
branches forking at height 1 therefore carry two anchors and two schedules, each
internally consistent. A single chain-wide anchor would instead change under
every block already built on it, retroactively altering targets that were already
validated. Chain state carries the anchor in O(1); a node without the parent in
memory resolves it by walking the ancestry to height 1.

**Bound on timestamp manipulation.** Import enforces only
`parent.timestamp < B.timestamp` (agreed state) and `B.timestamp <= now`
(node-local and retriable, §5.2 rule 5). There is no MedianTimePast rule, no
lower bound against wall clock, and no future-drift constant. Under an absolute
schedule a timestamp buys much less than it did under a window:

- Moving a timestamp **backwards** reduces `elapsed`, which makes `drift` more
  negative and the target **harder**. Clock manipulation in that direction costs
  difficulty rather than buying any, so it needs no separate defence.
- Moving it **forwards** is capped by `B.timestamp <= now`, and eases only the
  one successor by `2^(Δ / halfLife)`. It does not compound, because the schedule
  is absolute: the next block's target is measured from the anchor, not from this
  block. A miner cannot walk the target up by repeating the trick.
- Mining **harder** than `parent.nextTarget` no longer bends the schedule at all.
  Under the windowed retarget `nextTarget` was recomputed from the block's own
  `B.target`, so the level a miner chose became the chain's new floor. Under ASERT
  the schedule derives from the anchor, so a harder block is simply more work on
  the same schedule.

**The anchor's target is the chain's starting difficulty, and it is whatever
block 1 committed.** Because `nextTarget` moves at most one doubling per
half-life, an anchor far from what the chain can sustain is approached slowly: at
`halfLife = 120` the schedule hardens by one doubling per 120 blocks mined
ahead of schedule. A chain whose block 1 commits the maximum target therefore
spends on the order of `120 · log2(max / sustainable)` blocks at negligible
difficulty before the schedule catches up — for Nexus, roughly 4,900 blocks to
reach `2^215`. Genesis commits the maximum by convention, so block 1's committed
target is the only place a chain states the difficulty it intends to start at,
and a launch that leaves it at the maximum pays that bootstrap.

That cost is bounded by fork choice rather than by a consensus rule. Work is
`(MAX - target) / (target + 1) + 1`, which is **1** at the maximum target, so a
branch anchored at the maximum earns one unit of work per block however fast it
is extended, and any branch whose block 1 committed real work outweighs it
immediately — at `2^215` by a factor of `2^41` per block. The incentive is
therefore to anchor as hard as the miner can sustain.

## 6. State Transitions

### 6.1 State Update Procedure

Given a block's `prevState` and all actions from its transactions:

```
postState = proveAndUpdateState(prevState, actions)
```

This operation:
1. Partitions actions by type into 5 groups (one per sub-state)
2. For each sub-state, concurrently:
   a. Generates Sparse Merkle proofs that current values match `prevState`
   b. Applies mutations (inserts, updates, deletions)
   c. Returns new Merkle root
3. Assembles the 5 new roots into a new `LatticeState`

### 6.2 Account State Transitions

For each `AccountAction(owner, delta)`:
- **Proof**: Verify `prevState.accountState[owner]` exists (or does not, for new accounts)
- **Update**: Apply `delta` to balance. Positive delta = credit, negative = debit.
  - If resulting balance > 0: set `accountState[owner] = newBalance`
  - If resulting balance == 0: delete `accountState[owner]`

Nonces are tracked in the same trie via `_nonce_<signer>` keys. Only a
transaction's first signer, `signers[0]`, has a nonce checked or advanced:
the transactions in a block whose first signer is `S` must carry consecutive
nonces starting at `S`'s next nonce (0 if `_nonce_<S>` is absent, else its
value + 1), and `_nonce_<S>` becomes the last of them. Co-signers' nonces are
neither checked nor advanced; the first signer's nonce already makes the body
every signer signed unique, so it cannot be replayed. No signer may carry the
reserved `_nonce_` prefix. A transaction with no signers has no nonce.

### 6.3 General State Transitions

For each `Action(key, oldValue, newValue)`:
- **Proof**: Verify `prevState.generalState[key] == oldValue`
- **Update**:
  - If `newValue != nil`: set `generalState[key] = newValue`
  - If `newValue == nil`: delete `generalState[key]`

### 6.4 Deposit State Transitions

For each `DepositAction`:
- **Key**: `DepositKey(demander, amountDemanded, nonce)`
- **Proof**: Verify key does NOT exist in `prevState.depositState` (insertion proof -- prevents duplicate deposits)
- **Validation**: `amountDeposited > 0` and `amountDemanded > 0`
- **Update**: `depositState[key] = amountDeposited`

For each `WithdrawalAction`:
- **Key**: `DepositKey(demander, amountDemanded, nonce)`
- **Proof**: Verify key exists in `depositState` with a nonzero value
- **Validation**: Stored `amountDeposited` must equal `amountWithdrawn`
- **Update**: Set `depositState[key] = 0` as a permanent spent marker

Withdrawals are processed before new deposits within the same block. Since
valid deposits are nonzero and insertion requires absence, the spent marker
prevents both replayed withdrawal and recreation of the same deposit identity.

### 6.5 Receipt State Transitions

For each `ReceiptAction`:
- **Key**: `ReceiptKey(directory, demander, amountDemanded, nonce)`
- **Proof**: Verify key does NOT exist in `prevState.receiptState` (insertion proof -- prevents duplicate receipts)
- **Update**: `receiptState[key] = CID(withdrawer's PublicKey)`

Receipt actions also derive account actions: the `withdrawer` is debited `amountDemanded` and the `demander` is credited `amountDemanded`.

### 6.6 State Delta Accounting

Each action type reports a state delta in bytes:

| Action Type | Delta |
|---|---|
| `AccountAction` | `0` (account entries are counted below) |
| `Action` (insert) | `+len(key) + len(newValue)` |
| `Action` (delete) | `-(len(key) + len(oldValue))` |
| `Action` (update) | `len(newValue) - len(oldValue)` |
| `DepositAction` | `+32 + len(demander)` |
| `WithdrawalAction` | `+len(withdrawer) + len(demander) + 32` |
| `ReceiptAction` | `+len(withdrawer) + len(demander) + len(directory) + 24` |

Account entries are counted from the account-state transition, since whether
an owner's entry is created or removed depends on its balance before the
block. Every entry's value counts as 8 bytes (a uint64):

| Account entry | Delta |
|---|---|
| Balance created (0 → positive), the coinbase recipient's included | `+len(owner) + 8` |
| Balance removed (positive → 0) | `-(len(owner) + 8)` |
| Nonce created (`_nonce_<signer>` absent before) | `+len("_nonce_" + signer) + 8` |
| Balance or nonce changed | `0` |

A block's state growth is the sum of its transactions' action deltas plus its
account-entry deltas, and must not exceed `spec.maxStateGrowth`. It is checked
after the transition, because account-entry deltas need it. A node may reject
earlier on a floor known before the transition: the action deltas less
`len(owner) + 8` for every owner whose balance nets to a debit, the most
account removals could free. A floor over the limit is over it from any
starting state.

A chain's `maxStateGrowth` must leave room for these entries. A signer's first
transaction creates its nonce entry, and a credit to a new address creates a
balance entry: for a canonical address each is on the order of 70 bytes. A
limit below a few hundred bytes is valid but admits few or no new accounts per
block.

## 7. Transaction Validation

### 7.1 Signature Verification

Transactions use both an outer `lattice-tx-v1:` signature prefix and an inner
versioned envelope. The inner envelope is the following newline-separated text,
with every length measured in UTF-8 bytes and no trailing newline:

```text
domain:13:lattice-tx-v1
chainPath.count:<component count>
chainPath.component:<byte length>:<component>
nonce:<decimal uint64>
bodyCID:<byte length>:<CID(tx.body)>
```

The `chainPath.component` line is repeated once per component, in order. The
exact Ed25519 message is:

```text
signaturePayload = UTF8("lattice-tx-v1:" || envelope)
```

Both domain markers are consensus bytes; there is no newline between the outer
prefix and the first envelope line.

Signers MUST sign this exact preimage, and it is the only accepted signing
input: a signature over any other message, including the bare body CID under
the same outer domain (`UTF8("lattice-tx-v1:" || CID(tx.body))`), is invalid.
One body therefore has exactly one valid signature form per key, and so one
transaction CID per signer set. Signing keys remain canonical Multikey values.

For each `(publicKeyHex, signatureHex)` in an ordinary transaction's
`tx.signatures`, one accepted Ed25519 verification MUST succeed. At least one
signature is required. The set of addresses derived from the signing public
keys MUST equal the set in `tx.body.signers`; extra and missing signers are both
invalid. Genesis transaction signature fields are non-authoritative as described
in section 5.1.

### 7.2 Authorization

For each `AccountAction` where `delta < 0` (debit):
- `action.owner` MUST be in `tx.body.signers`

Credits (`delta > 0`) do not require signer authorization.

### 7.3 Deposit/Receipt/Withdrawal Authorization

- **DepositAction**: `demander` MUST be in `tx.body.signers`
- **ReceiptAction**: `withdrawer` MUST be in `tx.body.signers`
- **WithdrawalAction**: `withdrawer` MUST be in `tx.body.signers`; requires proof of corresponding deposit in `prevState.depositState` AND proof of receipt in `parentState.receiptState`

### 7.4 WASM Policies

Chain policies are content-addressed validation modules referenced by `ChainSpec.wasmPolicies`. In ABI version 1, policies are implemented as WASM modules. A policy declares a scope (`transaction` or `action`), ABI version, module CID, and exported entrypoint. The host passes a versioned canonical binary policy context containing the height and timestamp of the block being validated, the chain spec, chain path, and the transaction/action under validation. The policy returns `1` to accept and any other value to reject.

Genesis validates every configured policy reference and entrypoint, and every
function body of each module whether or not anything calls it, even when
genesis contains no transaction or Action to exercise that scope. This prevents
an immutable spec from admitting a latent missing, nondeterministic, or
malformed module that would fail only after deployment.

Neither the protocol nor a node limits a policy module's size, memory, or
table. The only bounds are WebAssembly's own: 32-bit linear memory and the
maxima the module declares. A verdict is therefore a function of the module and
the context alone, the same on every node. A node that cannot afford a chain's
policies declines to operate that chain.

A policy's call stack is 512 KiB of engine stack, because exhausting it traps
and a trap is observable in the verdict. The call depth that reaches it also
depends on the engine's frame layout, so nodes agree only while they run the
same engine version: an engine change is a consensus change.

Every outcome of a policy evaluation that is a function of the module and the
context is a completed verdict, the same for a block being validated and for a
transaction being considered for one. A policy rejects — the verdict is
invalidity — when it returns anything but `1`; when it traps (`unreachable`,
an out-of-bounds memory or table access, an integer divide by zero or
overflow, a null or mismatched indirect call, call stack exhaustion); when its
allocator or entrypoint returns something unusable; and when the module or its
reference is defective. Only what depends on the node is availability, never a
verdict: a module the node cannot obtain, or a failure of the node itself.

A policy may grow its memory. `memory.grow` MUST fail (return -1) only when
the growth would exceed the maximum the module declares, or WebAssembly's own
ceiling when it declares none: both are properties of the module. A node MUST
NOT report a growth failure for a reason of its own, such as lacking the
memory, because a policy can branch on that result and nodes would then reach
different verdicts. A node that cannot supply the memory stops; it does not
return a verdict.

Policy modules MUST export:

| Export | Type | Purpose |
|---|---|---|
| `memory` | WebAssembly memory | Host writes the policy context bytes here |
| `lattice_alloc` | `(i32) -> i32` | Allocates `len` bytes and returns the destination pointer |
| entrypoint | `(i32, i32) -> i32` | Receives `(ptr, len)` and returns `1` to accept |

The policy context byte layout is:

| Field | Encoding |
|---|---|
| Magic | ASCII `LWPCTX` |
| Context encoding version | `uint16`, big-endian |
| Policy ABI version | `uint16`, big-endian |
| Scope | `uint8`; `0` = transaction, `1` = action |
| Block height | `uint64`, big-endian (byte offset 11); compare unsigned |
| Block timestamp | `int64` milliseconds, big-endian two's complement (byte offset 19) |
| Chain spec | `uint32` byte length, then DAG-CBOR `ChainSpec` bytes |
| Chain path | `uint32` item count, then each path component as `uint32` byte length + UTF-8 bytes |
| Transaction | `uint8` presence tag; if `1`, `uint32` byte length + DAG-CBOR `TransactionBody` bytes |
| Action | `uint8` presence tag; if `1`, `uint32` byte length + DAG-CBOR `Action` bytes |
| Action index | `uint8` presence tag; if `1`, `uint64` index, big-endian |

The context encoding version is `2`. Height and timestamp are those of the
block that carries the transaction. The timestamp is chosen by the miner:
consensus requires only that it exceed the parent's (and nodes defer blocks
from their own future), so a miner can place it anywhere between the parent's
timestamp and the present. Rules that a miner must not be able to shift, such
as expiry, SHOULD key on height.

A policy verdict therefore depends on the carrying block, not only on the
transaction. Transaction preflight, which has no carrying block, evaluates
policies against the block that would extend the current tip: height
`tip + 1`, timestamp `max(tip.timestamp + 1, now)`. That verdict is advisory:
a block builder MUST re-evaluate policies at the exact height and timestamp of
the block it assembles and omit transactions that fail, or it builds an invalid
block. Preflight rejects a transaction that fails its policies (it is not held
for later), so a transaction valid only from some height or time on, including
one returned to the pool by a reorg, must be resubmitted once it is valid.

### 7.5 Context-Specific Rules

| Context | Deposits | Receipts | Withdrawals |
|---|---|---|---|
| Genesis block | No | No | No |
| Non-genesis Nexus block | No | Yes | No |
| Non-genesis child chain | Yes | Yes | Yes (requires parent receipt proof) |

A non-root chain may be both a child of one chain and a parent of another. Its
deposits and withdrawals relate to its own parent; its receipts may serve its
children.

## 8. Cross-Chain Transfer Protocol

The cross-chain transfer protocol enables trustless value movement between
parent and child chains in the hierarchy. Consensus requires signatures and
Sparse Merkle proofs against state roots committed in blocks. Providers may
relay the required bytes, but no bridge, federation, or relayer has validity
authority.

### 8.1 Protocol Phases

A cross-chain transfer proceeds in three phases across a parent-child chain pair:

**Phase 1 -- Deposit (child chain):**
A signed child transaction includes a `DepositAction`. This locks
`amountDeposited` and records a demand: `demander` should receive
`amountDemanded` on the parent chain. The demander MUST sign. Block-wide balance
conservation funds aggregate deposits; consensus does not require a
transaction-local debit for this deposit. The deposit is stored in the child's
`depositState` via an insertion proof.

**Phase 2 -- Receipt (parent chain):**
A signed parent transaction includes a `ReceiptAction`. The parent validates
only its own authorized payment: the withdrawer MUST sign, the receipt key MUST
be absent, and the derived account actions debit `amountDemanded` from the
`withdrawer` and credit it to the `demander`. The parent does NOT verify the
child deposit when admitting the receipt.

**Phase 3 -- Withdrawal (child chain):**
The child proves both the matching nonzero deposit in
`prevState.depositState` and the matching withdrawer in
`parentState.receiptState`. For a child nested beneath a carrier,
`parentState` MUST equal that carrier's `prevState`; the receipt must therefore
already exist in the carrier's entering state. A `WithdrawalAction` replaces
the deposit value with a permanent zero-valued spent marker and adds
`amountWithdrawn` to the block-wide credit budget. It does not create an account
credit automatically; any recipient credit MUST be an explicit `AccountAction`.
The stored `amountDeposited` MUST exactly match `amountWithdrawn`.

A parent receipt without a matching child deposit cannot authorize child value,
because withdrawal requires both proofs. It is not cost-free: the signed parent
payment and receipt-state insertion still execute.

**Receipt canonicity.** Consensus binds a withdrawal to a parent state the
parent executed, on any branch (§5.3 step 6), and child fork choice does not
read parent canonicity (§9). A receipt that exists only on a parent branch the
parent later abandons can therefore settle a withdrawal in some child block.
It does not stand against honest miners: anchors only move forward (§5.3 step
6), a miner on the canonical parent anchors at a state that does not descend
from the abandoned branch, and so no honest miner can extend that child
block. Only work anchored on the abandoned branch extends it, and once the
honest child branch is heavier the child chain reorganizes and the withdrawal
is undone with it. Keeping the withdrawal takes a majority of the child's
hashrate, as reversing any confirmed child transaction does. The demander
can wait for the withdrawal to be confirmed on the child, as for any payment.

### 8.2 Balance Conservation with Cross-Chain Transfers

For any non-genesis block at index `i`, over its transactions' actions:

```
fee rule:      totalCredits + totalDeposited <= totalDebits + totalWithdrawn
fees:          F = totalDebits + totalWithdrawn - totalCredits - totalDeposited
coinbase:      M = reward(i) + F
```

Where:
- `totalCredits` = sum of all positive account action deltas
- `totalDebits` = sum of all negative account action deltas (absolute values)
- `totalDeposited` = sum of all `DepositAction.amountDeposited` values
- `totalWithdrawn` = sum of all `WithdrawalAction.amountWithdrawn` values

Sums are exact (no wrap). Every account action is nonzero and not `int64.min`.
The block reward funds no transaction: a transaction set that creates value is
invalid.

If `B.rewardRecipient` is `nil`, `M` is burned. Otherwise the recipient MUST be
a canonical address, and the post-state MUST credit it exactly `M` (nothing when
`M == 0`); `M > int64.max` makes the block invalid. The credit is applied with
the transactions' account actions, so a recipient that is also a payer nets
through one balance. There is no under-claim: the only way to burn is a `nil`
recipient.

A recipient without an account is created by the credit. That insertion
counts against `maxStateGrowth` like any other account created by the block
(section 6.6).

Deposits lock value in deposit state and so reduce `F`. Withdrawals return the
matching locked value and so add to `F`; explicit account actions determine any
credited recipients.

Per block, spendable supply (deposit state counts as locked, not spendable)
changes by exactly:

```
with a recipient:     reward(i) + totalWithdrawn - totalDeposited
without a recipient:  totalWithdrawn - totalDeposited - F     (fees burn)
```

With a recipient, fees move from payers to the recipient; receipts net to zero.

### 8.3 Security Properties

**No value creation**: The fee rule guarantees that transaction credits cannot exceed debits plus net withdrawal flow; the only new value is the block reward, paid to `rewardRecipient`.

**No double-deposit**: Deposit keys are unique in deposit state (insertion proof prevents duplicate deposits with the same nonce/demander/amount).

**No double-withdrawal**: Withdrawal leaves a permanent zero-valued marker. A
second withdrawal fails the nonzero amount check, and insertion cannot recreate
the same deposit key.

**No over-withdrawal**: The stored `amountDeposited` must exactly match the
declared `amountWithdrawn`. A larger declaration fails the state proof.

**No forged parent state**: A withdrawal accepts only a receipt proven in the
block's `parentState`, and that state MUST be one the parent chain actually
produced. Two rules establish this, and NEITHER is the proof's terminal
binding — a carrier is content-addressed bytes that need not be imported,
connected, valid, or canonical (§5.3, §9.5), so comparing a child's declared
`parentState` against a carrier's declared `prevState` compares two values the
same party may have chosen:

1. Every child block, its genesis included, proves its `parentState` by §5.3
   step 6.
2. State continuity is attested only across blocks on the parent's
   EXECUTED-FROM-GENESIS FRONTIER: executed, every ancestor executed, and not
   under an excluded block (§9.9). Execution alone is not enough — a block
   executed against a fetched parent state proves nothing about the parent
   having produced that state. The weighed tier records a declared `postState`
   as an unverified claim, so an unverified claim is never attestable.

Receipt admission itself does not assert that a child deposit exists.

**Cross-chain replay protection**: Each transaction declares a `chainPath` targeting the exact chain hierarchy path. Transactions are rejected if the `chainPath` doesn't match the validating chain.

## 9. Consensus

### 9.1 Verified Work Contributions

The root CID identifies one physical grind. Along one proof its quantity is
fixed by the ROOT-MOST carrier whose target that root hash beat, raised if
greater by the terminal child's own target (§9.5):

```text
contribution.id   = rootCID
contribution.work = max(workForTarget(T_rootmost_beaten),
                        workForTarget(target(B_terminal)))
```

This is NOT a maximum over the beaten targets of every level `B_i`; see §9.5.

Grind identity is immutable. Across REPEATED OBSERVATIONS of that identity at
one location, the credited quantity is the strongest verified bound seen, so it
can strengthen but never decrease. That per-location ratchet and the
along-the-proof selection above are different rules: the first chooses among
observations, the second among carriers. Its sparse proof has exactly one terminal block in each chain it
reaches. One block may be secured by many distinct grinds, but one grind MUST NOT
be placed at multiple blocks in the same chain. Same-chain ancestry makes a
descendant's work support its ancestors without creating more locations. The
logical location key is `(blockHash, grindID)`, while the immutable fact ID also
includes the observed work. Weaker or equal replay at the same location is a
duplicate. A stronger observation at that location remains durable. A conflicting
location is rejected atomically.

Consensus ingress stores each CID identity in its unique canonical text spelling.
An alternate multibase spelling is rejected before it can create another map key;
this identity-encoding rule is separate from branch canonicity, which never
determines whether accepted work contributes.

Consensus comparisons use a `WorkMeasure`, conceptually `Map<RootCID, U256>`.
Measure union takes the maximum value per root CID. `total(measure)` is the exact
sum of the resulting distinct values. This deduplicates repeated observations
and recursive inheritance of the same physical grind, while independent grinds
always sum. A disconnected staged location remains durable but is not routed
until its same-chain predecessor attaches.

### 9.2 Chain State and Hierarchical GHOST

Fork-choice state contains only one chain's accepted graph:

```text
accepted blocks + same-chain predecessor edges
local unique grind locations + strongest verified quantities
one derived canonical projection
```

For each block, `own(B)` is the measure formed by every proof-derived grind
located at that block:

```text
prefix(B) = own(B) union prefix(parent(B))

effectiveSubtree(B) = own(B)
                      union each effectiveSubtree(C)
                            for C in sameChainChildren(B)

cumulativeWork(B) = total(prefix(B))
trueCumWork(B)     = total(effectiveSubtree(B))
```

Measure union occurs before totaling. Repeated observations of one grind at the
same location therefore contribute once.
Implementations may cache local totals, but the accepted graph and unique
proof-derived work facts remain authoritative.

`WorkSum` is an exact growable unsigned integer. Individual contributions remain
`U256`, but their sums must not wrap or saturate because either behavior can
erase the strict ordering between two branches.

### 9.3 Import

Every external candidate enters one import procedure:

1. capture of one explicit `ValidationContext` for the attempt;
2. root CID and proof-of-work hash verification before child resolution;
3. targeted resolution of the candidate and required package;
4. complete structural path validation before requesting cross-chain evidence;
5. exact-path, vertical state binding, chain-target, and immediate-parent
   state-continuity checks;
6. deterministic genesis or non-genesis state-transition validation;
7. targeted storage of verified local content and materialized state;
8. atomic durability of one immutable accepted-fact batch; and
9. application of that exact batch through the reducer used by recovery.

Durability MUST precede visible graph mutation. Live import MUST NOT
re-resolve or rebuild the batch after durability, and recovery MUST apply the
same immutable facts through the same reducer. Identical replay is idempotent;
conflicting immutable metadata is rejected. Storage or durability failure leaves
the accepted graph unchanged, and genesis bootstrap exposes no runtime until its
facts are durable and restored.

A current-level target miss is a proof-of-work failure at this level: it is
not executed, inserted, or retained for this chain, and it returns no relay
result — its grind reaches a descendant only inside the descendant's
`ChildBlockProof`. A node may explicitly retain an exact child-link path as
availability policy; Lattice does not enumerate an attacker-sized child index. Unresolved same-chain
predecessors (absent or accepted-but-unconnected) are derived from the accepted
graph, including after recovery, and must enter this same import boundary. A
target miss never triggers predecessor backfill because connectivity cannot make
that grind satisfy the current chain's target. A target-hit accepted, duplicate,
or rejected candidate may expose the exact typed predecessor requirement so the
node can complete ordinary chain import and issuer promotion. This does not
claim a predecessor body is unavailable. Missing cross-chain input instead
identifies the child proof or immediate-parent state-continuity fact that the
node must obtain from an authenticated source. For a non-genesis candidate with predecessor `P`, continuity is
reflexive when `P.parentState == B.parentState`; otherwise the immediate
parent's connected accepted graph must contain a transitive same-chain state
path from `P.parentState` to `B.parentState`. Parent canonicity is irrelevant.
`parentState` is a state CID, not a parent-block lookup key. Consensus derives
no relationship by inversion. A target-hit candidate can likewise be rejected
by its local import rules while still proving real work for a descendant;
carrier validity and securing-work validity are orthogonal.

### 9.4 Fork Choice and Reorganization

At each fork, GHOST compares the competing same-chain child blocks. The child
with greatest effective `trueCumWork` wins. Equal work compares the canonical
CID bytes of those child blocks; the lexicographically smaller CID wins.
`nextTarget` is not a comparator. A chain may hold several genesis roots (§9.9,
genesis admission); the same rule applies to them, so arrival and replay order
cannot change fork choice. The deliberate security tradeoff of
this grindable deterministic tie-break is quantified by the
[consensus simulator's adversarial model](consensus-simulator.md#adversarial-model).

When a branch wins, only this chain's canonical indexes change. The emitted
canonical delta identifies the new tip and exact added and removed blocks. This
is a chain-local reorganization; Lattice sends no commands to parent, child, or
sibling processes.

Adding a grind location or strengthening a verified grind quantity may make a
subtree strictly heavier and trigger this same reorganization procedure.
Neither replays the block's state transition.

### 9.5 Cross-Chain Evidence Independence

Work and parent-state authority are separate.

A `ChildBlockProof` proves work directly from content-addressed bytes. The root
grind must beat the terminal child's target and resolve uniquely to that child
through the sparse directory path. Intermediate carriers need not be imported,
connected, valid, or canonical on their own chains. Along one proof, the
contribution is the target-derived quantity of the ROOT-MOST carrier whose
target that root hash beat — the highest chain the grind legitimately
participated in — raised, if greater, by the terminal child's own target. It is
NOT a maximum over every beaten target. The two differ only where the old rule
credited MORE, so this is the conservative variant: it removes an over-credit
the maximum allowed on an inverted hierarchy. It is not an anti-fabrication
measure — a carrier need not be valid, so a prover who fabricates a ladder
chooses the pricing target as freely under either rule. The two definitions coincide unless some carrier's target is
harder than both the ROOT-MOST beaten target and the terminal's own target.
(Stated against the root-most BEATEN carrier, not the root: when the root's own
target is unmet the selection falls through to the first carrier that was met.) That is NOT an exotic shape: `ChainSpec.targetBlockTime` is a free
per-chain field and retarget drives each chain toward its own block time, so a
chain with far less hashrate than its parent but a much longer block time can
sit at a harder target. An inverted hierarchy is therefore a configuration
choice a chain operator may make without intending it. The terminal
target must be beaten. The terminal child receives that ordinary
work fact only after it is accepted and connected.

The immediate parent authenticates only state continuity and child-genesis
authorization. A continuity fact is bound to the exact parent path and
`(fromStateCID, toStateCID)` pair. It proves that the parent's executed set
produced `toStateCID` at or below a block that produced `fromStateCID` (§5.3
step 6), not parent canonicity and not a work total.

A parent MUST attest continuity only across blocks on its executed-from-genesis
frontier — executed, every ancestor executed, none under an excluded block
(§9.9). Attestation asserts that a state was produced by the parent chain,
which is exactly what an unbroken run of execution from the genesis establishes
and what the weighed tier defers:
a weighed block's declared `postState` is an unverified claim (§9.9), and a
block that never becomes canonical is never validated and so never excluded,
so an unverified claim would otherwise remain attestable permanently. A child
settles cross-chain withdrawals against an attested state (§8.3), so attesting
an unexecuted claim admits a forged `receiptState`. Unavailability of a
validated ancestor makes continuity unprovable-for-now, never invalid (§9.9).
The fact is immutable and may be relayed independently of its original
transport.

Attestation does NOT depend on canonicity, in either direction. A reorg
withdraws nothing: execution is a fact about immutable bytes, ancestry does
not change, and losing a fork-choice contest is not a proof of invalidity, so
a child anchored at a state that later falls off the canonical chain keeps
its anchor. Nor does a parent owe execution to a block merely because a child
anchors there: a parent executes the history it adopts, and attests what lies
on its executed-from-genesis frontier. A child anchoring elsewhere is anchoring at something this parent
has not checked, and the correct answer is the retriable "not proven here",
not a verdict and not an obligation to go and run it.

The parent receives no child topology, validity, work, attachment, recovery
state, or canonical-tip command. Moving only a parent's canonical pointer
changes neither previously verified work nor continuity.

### 9.6 Ingress Equivalence

Gossip, sync, mining, parent extraction, and sibling relay differ only in
acquisition. Every external candidate enters the import procedure in section
9.3. Recovery instead replays already-authenticated durable facts through the
same graph mutation and fork-choice logic; it does not treat a local fact log as
new wire evidence. No ingress path may replace the chain directly or inject a
trusted canonical projection.

### 9.7 Consensus Graph and Node State Lifecycle

Lattice retains the complete accepted consensus graph and every verified local
grind location. It performs no age-, depth-, body-, or state-retention pruning
of consensus inputs.

State execution may derive local lifecycle metadata, but that metadata is not a
block commitment or a second cross-volume relationship index. The node decides
whether to retain it and owns CID counts, pinning, materialized-state pruning,
projections, archival, and garbage collection.

### 9.8 Persistence

The node durably preserves every accepted block's consensus fields, every
distinct location fact and strengthening observation, and a monotone mutation
order. A crash may occur after durable staging and before in-memory mutation;
recovery therefore replays those already-authenticated facts idempotently through
Lattice's graph and fork-choice reducer. The node does not reconstruct weights,
ancestry, or canonical choice itself.

Lattice exposes staged-fact replay as its recovery authority. A serialized
`ChainState` projection is neither a public recovery input nor protocol truth;
diagnostic projections, if retained by tests or tooling, cannot replace replay.

Restoration rejects malformed facts, reconstructs exact measures, and
reprojects canonicality. A persisted tip is a derived cache, not protocol
truth. Filesystem layout, payload pruning, and format migration belong to the
node.

### 9.9 Deferred Execution: Weighed and Validated Tiers

Import (9.3) verifies work independently of executing state. Because the
consensus graph carries only header fields and claimed state CIDs — never the
body or materialized state — a block MAY enter fork choice on its verified work
alone, before its state transition is executed. A candidate is therefore
imported at one of two tiers:

- **Weighed.** Its work is verified (root proof-of-work or a `ChildBlockProof`)
  and it possesses the header. Its declared `postStateCID` is recorded as an
  unverified claim; no transition is executed and no post-state is materialized.
  A weighed block contributes to `trueCumWork` and fork choice (9.4) identically
  to an executed one.
- **Validated.** Its transition (9.3 step 6) has been executed and the derived
  post-state matches the declared `postStateCID`. Validation is a second,
  separate, deterministic judgment recorded on an already-weighed block.

"Accepted" in this section means *weighed*: present in the graph with verified
work. Ranking is defined over weight; being *acted upon* — extended, served as
head, or asserted as the node's state — requires the *validated* tier. A node
MUST NOT act on a merely weighed tip; it acts on its heaviest *validated* tip:
descending from genesis, at each fork it follows the heaviest child that is
validated (heaviest by the whole subtree's work, unvalidated descendants
included), and stops where no child is validated. Missing bodies of a heavier
weighed branch are an availability gap (9.5-style: retried indefinitely, never
a verdict): the branch keeps its weight, is never marked, and takes over at
its fork once its first block there is validated. A block whose body is not
held is weighed and unvalidated, never invalid; weight needs only the header.

Failure to obtain a body is availability, never invalidity. Only a **completed**
deterministic check — a `postState` mismatch or a committed validity rule —
records an **invalidity exclusion** of the block.

**Work weighs; validity selects.** Exclusion removes no weight: the excluded
block's work, and its descendants', stays in every ancestor's `trueCumWork`
exactly as any other verified work does, because proof-of-work is a physical
fact and invalidity is a judgment about state (9.5). What exclusion changes is
selection: the canonical descent (9.4) never steps into an excluded block, so
the tip is the heaviest *selectable* path through pure-work weights, and
nothing at or below an excluded block is ever the tip, extended, or attested
(5.3). A miner who spends work on an invalid block therefore still votes for
that block's valid ancestors — which the same work on a valid block would also
have done — and gains nothing else; an excluded subtree is never resurrected by
later work added beneath it, however heavy. Exclusion is a chain-local
selection decision, not pruning: the excluded block and its work facts remain
in the graph, served and exported unchanged, and are never treated as invalid
by any peer on that account. It is durable and replayed like any other fact:
recovery reconstructs the excluded set and selects identically, independent of
arrival order. Validity is consulted lazily — only where the descent would
step into an unexecuted block — and never retracted. A genesis root may be
excluded only while the chain has ANOTHER executed root to stand on; otherwise
the verdict is not recorded at all and the validated tier stops there — a
stall the node must surface, since a parked verdict is not itself a fact —
because a chain whose every root is invalid has no selectable history, and a
recorded fact recovery could not replay would make restart order-dependent.

Deferral and exclusion are one mechanism: a node MUST NOT let unexecuted weight
be acted upon without the ability to exclude a subtree it later proves invalid.

**Header admission.** A block enters the weighed graph from its header when
its parent is held (excluded or not) and its work verifies: securing work
(9.5) yields a contribution — for a root block, its own hash meets its own
target — and the block is on the schedule: `B.timestamp > P.timestamp`,
`B.target <= P.nextTarget`, and `B.nextTarget` the schedule of 5.5, computed
from the chain's own spec. The schedule is part of the proof of work, and the
timestamp is its input at every height (height 1 anchors it): an old timestamp
would make every descendant's target easy. Of the header rules of 5.2, exactly
two are validity, recorded as an exclusion of that same block the moment it is
weighed: `B.spec != P.spec` and `B.prevState != P.postState`. Such a block
weighs its work, is never selected, and its descendants weigh and are never
selected, exactly as for an execution verdict. Every other outcome records no
fact:

- **Proof-of-work failure** — no contribution, off the schedule, or bytes that
  do not decode or match their CID. The only header failure that blames its
  sender.
- **Dropped** — a wrong version or height (including an unrepresentable one),
  a child index that does not match the block's `children` CID, a malformed
  reward recipient, a genesis, or a child whose `parentState` is not its
  carrier's `prevState`. No weight, no blame.
- **Held** — a timestamp after the node's `now`, an unknown parent, or a
  difficulty anchor not in hand. Retried; never a verdict. The schedule is
  checked before `now`: a header off the schedule is a proof-of-work failure
  even when its timestamp is after `now`.

Weighed headers are never evicted. The exclusion is a separate batch from the
block's own (a batch carries an exclusion alone); the node MUST make both
durable in one transaction, and replay applies them in any order.

**Genesis admission.** A chain's roots enter the weighed graph only as
genesis blocks, never from a header. A genesis is weighed from its bytes — its
CID is computed from them, and its `spec` is held by that CID as its root's
spec, which schedules every header beneath it — and its work: on the root
chain, only the configured Nexus genesis, by its own grind; on a child chain,
any genesis, by a verified `ChildBlockProof` of exactly it, so a child chain
may hold several roots. No parent record authorizes a child genesis: it is
executed like any child block — continuity included (§5.3) — and excluded
under the root rule above if invalid. Execution is never revoked: an
executed block is never later excluded, and a verdict claiming so is a local
fault, recorded nowhere.

### 9.10 Parent-Attributed Run Work

A child block's `parentState` is committed by a block on its parent chain
(§5.3). Every parent-chain block that DESCENDS from that carrier commits to
the child block indirectly, and its work secures the child. Effective
`trueCumWork` therefore counts it — once.

The parent partitions its connected graph into RUNS, one per commitment into
each child directory `d`: a parent block `Q` belongs to the run of the nearest
block at or above it — by parent pointer, never by canonical chain — that
commits into `d`. `nearestCarrier(Q, d)` is inherited from `Q`'s parent at
connection, like `DifficultyAnchor`, so it is reorg-safe and replay-identical;
it is held only for the directories a node hosts, so the bookkeeping per block
is O(#hosted), never O(height). A block's commitments are read from its
PoW-bound `children` index at import and carried on its durable block fact,
so live import and replay see the same commitments. (The index is inside
`maxBlockSize` (§3.5); until the validate tier applies that rule a
not-yet-validated block's map is bounded only by what the boundary store will
fetch, and it is retained through a later exclusion.)

`runWork(P, d)` is the sum of credited work — grinds and attributed runs
alike — over the connected blocks whose nearest carrier into `d` is `P`. Runs
partition the graph: each parent grind is in at most one run per directory,
and a parent fork below `P` places each branch in the run of that branch's
own nearest carrier — no branch missed, none counted twice. A run only grows,
including when a block in it is later excluded: proof-of-work is a physical
fact and exclusion is a judgment about state (§9.5, §9.9).

**The rule.** For every parent block `P` that commits `C = P.children[d]`,
where the child chain holds `C`:

```text
attributed(C, P, d) = runWork(P, d) − grindWork(P)
```

credited at `C` under the contribution ID `CID(AttributedRunIdentity(P, d))`,
separate from any grind, and only ever raised. `grindWork(P)` is the credited
work of `P`'s own grinds — never an attributed run. Subtracting all of it
keeps the value monotone (a stronger grind at `P` raises both terms alike) and
never counts a grind the child may already hold at `C` twice; a run that `P`'s
OWN parent attributed at `P` is in `runWork(P, d)` and not in
`grindWork(P)`, so it reaches the child, and the recursion Nexus → A → B
holds level by level. `trueCumWork` of a child block is then its subtree total
as always.

Attributed values are DERIVED, never facts: a node applies the rule from its
own copy of the parent level, parent levels first, live and again at restore.
The result is a function of the parent graph alone — independent of arrival
or replay order — and, like every run, independent of exclusion and of
parent canonicity.

## 10. Economic Model

### 10.1 Reward Schedule

```
rewardAtBlock(height) = initialReward >> ((height + premine) / halvingInterval)
```

The reward halves every `halvingInterval` blocks. After all halvings complete, the reward reaches 0.

### 10.2 Premine

The premine represents blocks conceptually "mined" by chain creators before public mining begins. The premine amount is the sum of the rewards of those `premine` blocks at the front of the schedule:

```
premineAmount = sum(initialReward >> (i / halvingInterval) for i in 0..<premine)
```

When `premine < halvingInterval` this reduces to `premine * initialReward` (all premined blocks fall in the first reward epoch). Premine is **not** capped: it may span multiple halving epochs, up to a fully-premined chain whose entire emission is front-loaded and which mines zero ongoing block reward. Because emission terminates once the reward reaches 0, `premineAmount` is inherently bounded by the chain's total lifetime supply — a chain cannot premine more coins than it will ever emit.

Public mining starts at block index 0, but the halving schedule treats it as block `premine` (`rewardAtBlock` shifts the curve forward by `premine`). When `premine < halvingInterval`, the first public halving occurs at block `halvingInterval - premine`.

### 10.3 Total Supply

```
totalRewards(n) = sum(rewardAtBlock(i) for i in 0..<n)
```

Computed efficiently via geometric series in O(log n) time by iterating through halving periods.

### 10.4 ChainSpec Validity

A `ChainSpec` is valid if:

```
maxNumberOfTransactionsPerBlock > 0
maxStateGrowth > 0
maxBlockSize > 0
targetBlockTime > 0
initialReward > 0
halvingInterval > 0
halfLife > 0
```

`premine` is unconstrained (any `uint64`): it is a block-count offset into the emission schedule and the reward math handles any size, supply-bounded, without overflow. Premine is governed by transparency (it is fixed in the content-addressed genesis spec and provable via `premineAmount`), not by a protocol ceiling.

Before decoding a previously unknown `ChainSpec`, a node may apply its own byte
ceiling. That decision is local capacity policy, not `ChainSpec` invalidity.

## 11. Cryptographic Primitives

| Primitive | Algorithm | Usage |
|---|---|---|
| Hash | SHA-256 | Block hashes, Merkle trees, addresses, proof-of-work |
| Signature | Ed25519 | Transaction authorization |
| Content addressing | CID (DAG-CBOR + SHA-256) | All data structure references |
| Sparse proofs | Sparse Merkle Tree | State inclusion/exclusion proofs |

### 11.1 Address Derivation

```
address(publicKey) = CID(PublicKey(key: publicKey))
```

An address is the Content Identifier (DAG-CBOR + SHA-256) of the `PublicKey` struct wrapping the key. Public keys are encoded as Multikey, and Ed25519 is the key type used for signing.

## 12. Invariants

The following invariants MUST hold at all times:

### 12.1 State Continuity

For any consecutive blocks `B[i]` and `B[i+1]` on the same chain:

```
B[i].postState == B[i+1].prevState
```

### 12.2 Balance Conservation

For any valid non-genesis block (section 8.2):

```
totalCredits + totalDeposited <= totalDebits + totalWithdrawn
coinbase credit to rewardRecipient == reward + fees   (none when nil: burned)
```

The block subsidy `reward` is the only minting source, and only a set
`rewardRecipient` receives it. Deposits lock balance (move it into deposit
state); withdrawals return it.

### 12.3 Consensus Invariants

1. The chain tip is always on the canonical chain
2. The chain tip block always exists in the block map
3. Exactly one accepted genesis root anchors the selected canonical path
4. Canonical-chain blocks form a connected path from genesis to tip
5. A canonical delta's added and removed block sets are disjoint
6. One validator process owns one absolute path and cannot mutate another chain

### 12.4 Cross-Chain Transfer Invariants

1. Each `DepositKey` is unique in deposit state (insertion proof prevents duplicate deposits)
2. Each `ReceiptKey` is unique in receipt state (insertion proof prevents duplicate receipts)
3. A withdrawal requires the corresponding deposit to contain its original
   nonzero amount
4. A withdrawal requires the corresponding receipt to exist in `parentState.receiptState` (mutation proof)
5. The stored `amountDeposited` must exactly match the declared `amountWithdrawn` (prevents over-withdrawal)
6. Withdrawal replaces the deposit value with a permanent spent marker

### 12.5 Fork Choice Invariants

1. Every level evaluates the same root hash against its own target
2. Directory-path work verification is independent of carrier validity,
   import, connectivity, and canonicity
3. A grind has exactly one terminal location per chain and is deduplicated by
   root CID across observations at that location;
   its credited quantity is the root-most verified accepted-target bound
   along its proof (§9.5), raised by the terminal child's own target
4. Work measures union by grind ID before totaling, so shared work is counted once
   while distinct grinds sum
5. Effective `trueCumWork` contains only connected, accepted same-chain
   locations derived from verified proof bytes, plus each committed block's
   attributed parent run (§9.10), derived from the parent level and only
   ever raised
6. Equal-work same-chain child blocks prefer the lexicographically smaller
   canonical block CID; `nextTarget` is not a comparator
7. Parent canonicity alone cannot change child validity, weight, or fork choice
8. A non-genesis child keeps the same parent-state reference or moves
   transitively forward through the immediate parent's connected accepted graph
9. Lattice never prunes accepted graph or verified local-work facts
10. There is no finality threshold; a strictly heavier effective subtree may reorg at any depth
11. Every successful consensus mutation has a monotonically increasing revision
12. One explicit validation-time context governs one import attempt

## 13. Constants

| Constant | Value | Description |
|---|---|---|
| `totalExponent` | 64 | Bit width of the reward/halving system |
