# Cross-Chain Transfer Guide

This guide walks through one transfer of value between a child chain and its
parent, and explains why each step is safe. It is not normative: the types and
rules are in the specification, sections
[6](spec.md#6-state-transitions), [7](spec.md#7-transaction-validation) and
[8](spec.md#8-cross-chain-transfer-protocol), and each step below links to the
rule it relies on.

## The Idea

A transfer is a swap between two people across two chains. Nobody moves a coin
from one chain to the other. Instead:

1. One person locks value on the child chain and says what they want for it on
   the parent.
2. A second person pays them that amount on the parent.
3. The second person then unlocks the value on the child by proving the
   payment happened.

The two chains validate independently. The parent never looks at the child,
and the child checks the parent's state only through a proof. No bridge,
federation, or relayer has authority over either step.

## Roles

For a child chain `C` and its direct parent `P`:

| Role | Does |
|---|---|
| Demander | Locks value on `C` and receives the requested payment on `P` |
| Withdrawer | Pays the demander on `P`, then unlocks the locked value on `C` |
| Child chain | Validates its deposit and the matching parent receipt |
| Parent chain | Validates only the signed receipt payment in its own state |

## Worked Example

Alice holds 100 on the child chain `Nexus/Payments` and wants 40 on Nexus. Bob
holds funds on Nexus and wants funds on `Nexus/Payments`. They agree: Alice's
100 on the child for Bob's 40 on the parent. Alice picks the nonce `7`.

```text
child Nexus/Payments                         parent Nexus

1. Alice signs a deposit
   DepositKey Alice/40/7 -> 100
                                             2. Bob signs a receipt
                                                Bob   -= 40
                                                Alice += 40
                                                ReceiptKey Payments/Alice/40/7 -> Bob

3. a later Nexus block carries a Payments block;
   that Payments block commits the Nexus state
   that already contains the receipt

4. Bob signs a withdrawal
   proves DepositKey Alice/40/7 holds 100
   proves ReceiptKey Payments/Alice/40/7 holds Bob
   DepositKey Alice/40/7 -> 0   (spent, permanently)
   Bob += 100                   (an explicit credit)
```

The two keys tie the three actions together
([spec §3.7](spec.md#37-keys)):

```text
DepositKey = demander / amountDemanded / nonce
ReceiptKey = directory / demander / amountDemanded / nonce
```

`directory` is the child's single edge label under this parent (`Payments`),
not its absolute chain path.

### Step 1: Alice Deposits On The Child

Alice signs a child transaction with a `DepositAction`:

```text
DepositAction { nonce: 7, demander: Alice, amountDemanded: 40, amountDeposited: 100 }
```

The child stores 100 at `Alice/40/7`. From this block on, that 100 is locked.

- Alice, the demander, must sign.
- The key must not exist yet, so the same deposit cannot be made twice.
- The 100 has to come from somewhere: the block's debits must cover its
  deposits. Here Alice's transaction also debits her own account by 100. The
  protocol does not require that; it requires only that the block as a whole
  does not create value.

**There is no timeout, cancellation, or refund.** If nobody pays the receipt
and withdraws, the deposit stays locked. Applications must account for that
before creating a deposit.

Rules: [spec §6.4](spec.md#64-deposit-state-transitions),
[§7.3](spec.md#73-depositreceiptwithdrawal-authorization),
[§8.2](spec.md#82-balance-conservation-with-cross-chain-transfers).

### Step 2: Bob Pays On The Parent

Bob signs a parent transaction with a `ReceiptAction`:

```text
ReceiptAction { withdrawer: Bob, nonce: 7, demander: Alice, amountDemanded: 40, directory: "Payments" }
```

The parent debits Bob 40, credits Alice 40, and stores Bob's public-key CID at
`Payments/Alice/40/7`. That stored value is what later lets Bob, and only Bob,
withdraw.

- Bob, the withdrawer, must sign.
- The key must not exist yet.
- Bob must be able to fund the debit, netted with the block's other changes to
  his balance.

The parent does **not** check that Alice's deposit exists. It validates its
own authorized payment and records who paid. That is the chain boundary at
work: the parent need not execute, trust, or choose the child chain.

A receipt with no matching deposit cannot unlock anything, because the
withdrawal needs both proofs. It is not free either: Bob's payment still
happens and the receipt still occupies parent state. So **Bob should wait for
Alice's deposit to be confirmed on the child before he pays**.

Rules: [spec §6.5](spec.md#65-receipt-state-transitions),
[§6.2](spec.md#62-account-state-transitions),
[§8.1](spec.md#81-protocol-phases).

### Step 3: The Receipt Reaches The Child

The child cannot read the parent directly. A child block commits one parent
state, its `parentState`, which is the state the carrying parent block started
from:

```text
child.parentState == carrier.prevState
```

So the receipt must already be in the carrier's entering state. In practice
the withdrawal is carried by a parent block after the one that created the
receipt.

`parentState` is a state CID, not a parent-block CID. The child validates the
state proof supplied for its own candidate. It does not query a canonical
parent tip or infer a parent block from the state root.

### Step 4: Bob Withdraws On The Child

Bob signs a child transaction with a `WithdrawalAction` and a credit to
himself:

```text
WithdrawalAction { withdrawer: Bob, nonce: 7, demander: Alice, amountDemanded: 40, amountWithdrawn: 100 }
AccountAction    { owner: Bob, delta: +100 }
```

The child checks two proofs: its own deposit state holds 100 at `Alice/40/7`,
and the parent's receipt state holds Bob at `Payments/Alice/40/7`. Then it
sets the deposit to zero, permanently.

- Bob, the withdrawer named by the receipt, must sign.
- `amountWithdrawn` must equal the stored deposit exactly.
- The withdrawal does not credit Bob by itself. It adds 100 to what the block
  may credit, and the explicit `AccountAction` says who receives it.
- The zero is a permanent spent marker. It prevents a second withdrawal and
  prevents the same deposit key from being created again.

Rules: [spec §6.4](spec.md#64-deposit-state-transitions),
[§7.3](spec.md#73-depositreceiptwithdrawal-authorization),
[§8.1](spec.md#81-protocol-phases).

## The Amounts Are An Exchange Rate

The parent payment and the child withdrawal use different quantities:

| Field | Chain | Meaning |
|---|---|---|
| `amountDemanded` | Parent | What the withdrawer pays the demander |
| `amountDeposited` | Child | What is locked, and later returned to a block's credit budget |

In the example the rate is 100 child units for 40 parent units. Consensus does
not calculate a rate. It enforces only the declared amounts, the signatures,
the state proofs, and the exact withdrawal.

## Why The Child Can Trust `parentState`

The equality in step 3 is a structural check on the committed path. It does
**not** establish that the state is real: a carrier need not be imported,
connected, valid or canonical, so one party may have chosen both sides of it.
A child header whose proof fails the check is dropped without blame and weighs
nothing ([spec §9.9](spec.md#99-deferred-execution-weighed-and-validated-tiers),
header admission).

What makes `parentState` trustworthy is import:

- every child block proves its `parentState` by continuity at every height,
  block 1 included, rooted in the genesis's `emptyHeader`
  ([spec §5.3](spec.md#53-child-chain-block-validation), step 6);
- a parent attests continuity only across blocks on its executed-from-genesis
  frontier: executed, every ancestor executed, none under an excluded block
  ([spec §9.5](spec.md#95-cross-chain-evidence-independence)).

[Work and fork choice](consensus-fork-choice.md#parent-state-continuity)
explains continuity with examples.

## What Reorganizations Can Do

Neither chain has finality, so a transfer is exposed to reorganizations of
both. The exact statements are in
[spec §8.1](spec.md#81-protocol-phases) ("Receipt canonicity") and
[§8.3](spec.md#83-security-properties) ("Atomicity under reorganization"). In
short:

| Event | Effect |
|---|---|
| The parent abandons the branch that holds the receipt | Alice is paid only while the canonical parent chain contains the receipt. A withdrawal anchored on the abandoned branch is undone once the honest child branch is heavier |
| The child drops the withdrawal but keeps the deposit | The deposit is live again, and the receipt can be redeemed again by a child block anchored at a parent state that contains it |
| The child drops the deposit as well | Nothing can be redeemed until the deposit is mined again |

Bob pays first, so he waits for the deposit to be confirmed before paying and
for the withdrawal to be confirmed after.

## Security Properties

Each property and the rule that gives it
([spec §8.3](spec.md#83-security-properties)):

| Property | Because |
|---|---|
| No duplicate deposit or receipt | Both keys enter their tries by insertion, which requires absence |
| No unauthorized parent payment | The debited withdrawer signs the receipt |
| No withdrawal from a receipt alone | The child requires both the deposit proof and the receipt proof |
| No unauthorized withdrawal | The receipt stores the withdrawer's key CID |
| No over-withdrawal | The withdrawal must equal the stored deposit |
| No replay after withdrawal | The deposit becomes a permanent spent marker |
| No replay on another chain | The signed transaction envelope commits `chainPath` |

Parent and child canonical pointers are not proof inputs. A provider may
supply the necessary bytes, but each chain verifies its own state and
consensus facts before they can affect acceptance.
