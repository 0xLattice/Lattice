# Cross-Chain Transfer Guide

This is a non-normative walkthrough of the parent-child value exchange. Exact
types and consensus rules live in [specification sections 6-8](spec.md#6-state-transitions).

The protocol coordinates two independently validated chains without giving
either process authority over the other's fork choice.

## Roles

For a child chain `C` and its direct parent `P`:

| Role | Action |
|---|---|
| demander | Authorizes the child deposit and receives the requested payment on `P` |
| withdrawer | Pays the demander on `P`, then authorizes spending the locked value on `C` |
| child process | Validates its deposit and the matching parent receipt |
| parent process | Validates only the signed receipt payment in its own state |

A block may fund deposits with authorized debits across several transactions.
The protocol requires the demander to sign the deposit, but does not bind that
deposit to one account or to a transaction-local debit.

## The Three Actions

```text
DepositAction {
    nonce, demander, amountDemanded, amountDeposited
}

ReceiptAction {
    withdrawer, nonce, demander, amountDemanded, directory
}

WithdrawalAction {
    withdrawer, nonce, demander, amountDemanded, amountWithdrawn
}
```

`amountDeposited` is the child-chain amount locked. `amountDemanded` is the
parent-chain payment. They may differ.

The shared identities are:

```text
DepositKey = demander / amountDemanded / nonce
ReceiptKey = directory / demander / amountDemanded / nonce
```

`directory` is the child's single separator-free edge label under this parent,
not its absolute chain path.

The receipt value stores the withdrawer's public-key CID. The child uses that
value to ensure only the party that paid on the parent can authorize withdrawal.

## The Exchange

```text
child C                                      parent P

1. signed deposit
   insert DepositKey -> amountDeposited
                         2. signed receipt
                            debit withdrawer by amountDemanded
                            credit demander by amountDemanded
                            insert ReceiptKey -> withdrawer

3. a later parent carrier commits a prevState containing the receipt
   child block commits that state as parentState

4. signed withdrawal
   prove DepositKey holds amountWithdrawn
   prove ReceiptKey holds withdrawer in parentState
   replace deposit value with permanent zero marker
   add amountWithdrawn to C's block-wide credit budget
   use explicit AccountAction credits for recipients
```

### 1. Deposit On The Child

The deposit transaction must satisfy:

- `demander` signed the transaction;
- `amountDeposited > 0` and `amountDemanded > 0`;
- the `DepositKey` is absent before insertion;
- block-wide balance conservation funds aggregate deposits.

The child inserts `amountDeposited` at the key. This reserves the identity and
removes that amount from available child-chain value until a valid withdrawal.
The base protocol has no timeout, cancellation, or refund action. Without a
matching parent receipt and withdrawal, the deposit remains locked; applications
must account for that liveness tradeoff before creating a deposit.

### 2. Receipt On The Parent

The receipt transaction must satisfy:

- `withdrawer` signed the transaction;
- `amountDemanded > 0`;
- the `ReceiptKey` is absent before insertion;
- the withdrawer can fund the derived debit, netted with the block's other
  deltas to the same owner (spec §6.2).

The parent derives an equal debit and credit:

```text
withdrawer -= amountDemanded
demander   += amountDemanded
```

The parent does **not** verify the child deposit when admitting the receipt. It
validates its own authorized transfer and records the claimant identity. A
receipt without a deposit cannot authorize child value because withdrawal still
requires the deposit proof. It is not free: it still performs the signed parent
payment and consumes parent state.

This separation is the chain boundary in action. The parent need not execute,
trust, or choose the child chain.

### 3. Withdrawal On The Child

The withdrawal transaction must satisfy:

- `withdrawer` signed the transaction;
- the child `prevState.depositState` contains the matching nonzero deposit;
- `parentState.receiptState` contains the matching receipt and withdrawer;
- `amountWithdrawn` exactly equals the stored `amountDeposited`.

The child then replaces the deposit value with zero and adds the exact deposited
amount to the block-wide credit budget. This does not credit the withdrawer
automatically; an explicit `AccountAction` determines the recipient. The
permanent zero marker prevents both a second withdrawal and recreation of the
same deposit identity.

## Why `parentState` Matters

For a child block nested under a parent carrier:

```text
child.parentState == carrier.prevState
```

The receipt must therefore already exist in the carrier's entering state. A
withdrawal is normally committed by a parent block after the block that created
the receipt.

`parentState` is a state CID, not a parent-block CID. The child validates the
state proof supplied for its own candidate. It does not query a canonical parent
tip or infer a parent block from the state root.

That equality is a structural check on the committed path — it does NOT
establish that the state is real. A child header whose proof fails it is
dropped without blame and weighs nothing (spec §9.9 header admission). A carrier need not be imported, connected,
valid or canonical, so both sides of it may be chosen by the same party. What
makes `parentState` trustworthy is import: every block proves its
`parentState` by continuity at every height including block 1, rooted in the
genesis's `emptyHeader`, and a parent attests continuity only across blocks on
its executed-from-genesis frontier — executed, every ancestor executed, none
under an excluded block. See spec §5.3 step 6, §8.3 and §9.5.

## Variable-Rate Transfers

The parent payment and child withdrawal use different quantities:

- `amountDemanded`: parent value paid by the withdrawer;
- `amountDeposited`: child value later returned to a block's credit budget.

This permits an agreed exchange rate between the chains. Consensus does not
calculate that rate; it only enforces the declared amounts, signatures, state
proofs, and exact withdrawal.

## Security Properties

- **No duplicate deposit or receipt.** Both identities enter their trees with
  insertion proofs.
- **No unauthorized parent payment.** The debited withdrawer signs the receipt.
- **No withdrawal from a receipt alone.** The child requires both deposit and
  receipt proofs.
- **No unauthorized withdrawal.** The receipt proves the authorizing
  withdrawer's key CID.
- **No over-withdrawal.** The requested withdrawal must equal the stored deposit.
- **No replay after withdrawal.** The deposit becomes a permanent spent marker.
- **No cross-path replay.** The signed transaction envelope commits `chainPath`.

Parent and child canonical pointers are not proof inputs. A provider may supply
the necessary bytes, but each chain process verifies its own state and consensus
facts before they can affect acceptance.
