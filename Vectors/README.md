# Lattice conformance vectors

Published test vectors for SDKs in other languages. An SDK that reproduces
every vector here encodes, addresses, signs and verifies exactly as Lattice
does.

Every file is generated from the real Lattice code by
`Tests/LatticeTests/ConformanceVectorTests.swift`, and CI checks it on macOS
and Linux on every run in two ways:

1. The committed file must be byte-identical to a fresh in-memory
   regeneration.
2. Every vector is run back through the Lattice verifier: the bytes decode and
   re-encode to the same CID, and each signature and proof verifies exactly
   when its `valid` field says it does.

## Files

Each file is JSON with a top-level `version`, a `spec` reference into
[`docs/spec.md`](../docs/spec.md), a `description`, and a `vectors` array.
Every vector has a stable `name`. Hex is lowercase and has no `0x` prefix,
except the negative vector `message/uppercase-signature-hex`, whose
signature is uppercase on purpose and must be rejected.

A vector in `signing.json` or `proofs.json` carries a `valid` field. A vector
with `"valid": false` is a **negative vector**: an SDK must reject it. They
are listed under [Negative vectors](#negative-vectors). Every vector in
`encoding.json` and `addresses.json` is positive and has no `valid` field.

| File | Contents | Spec |
|---|---|---|
| `encoding.json` | DAG-CBOR bytes (`dagCborHex`) and CID (`cid`) for a `TransactionBody` with each action kind, a `Transaction` with one signer and one with two, a genesis `Block` at the maximum target and one at a lower target, and two `ChainSpec`s. `value` shows the same fields as readable JSON, for building the value in an SDK. `dagCborHex` is normative. | §3 |
| `addresses.json` | Ed25519 key (`privateKey` when one is known, then `publicKeyEd25519Hex`), its Multikey hex (`publicKey`), the DAG-CBOR `PublicKey` node, and the `address`. | §11.1 |
| `signing.json` | Ed25519 signatures over `signedBytesHex = UTF8("lattice-tx-v1:" + message)`. Scheme `message` verifies with `CryptoUtils.verify`. Scheme `transaction` carries the body (`transactionBodyDagCborHex`, `transactionBodyCid`) and verifies with `TransactionSigning.verify`: its `message` is the `lattice-tx-v1` envelope, the only valid signing input. | §7.1 |
| `proofs.json` | Sparse proofs over an `AccountState` trie (address to uint64 balance): only the nodes on one key's path. The trie is the compressed radix trie of spec §3.4.1, not a fixed-depth sparse Merkle tree. `entries` are the content-addressed DAG-CBOR nodes along the key's path. A proof is valid when `key` resolves from `root`, using only those entries (each checked against its CID), to exactly `value`, or to absence when `value` is `null`. | §3.4 |

## Negative vectors

Each of these has `"valid": false` and must be rejected.

| File | Vector | What is wrong |
|---|---|---|
| `signing.json` | `message/tampered-message` | The message was changed after signing |
| `signing.json` | `message/wrong-public-key` | The signature is checked against another key |
| `signing.json` | `message/tampered-signature` | The signature bytes were changed |
| `signing.json` | `message/uppercase-signature-hex` | The signature hex is uppercase |
| `signing.json` | `message/bare-ed25519-public-key` | The key is a bare 32-byte Ed25519 key, not Multikey |
| `signing.json` | `message/malleated-signature-s-plus-l` | The signature is malleated (S + L) |
| `signing.json` | `transaction/legacy-body-cid` | The signature is over the bare body CID, not the `lattice-tx-v1` envelope. Its `message` is the body CID. A bare body-CID message is never a valid signing input (spec §7.1) |
| `signing.json` | `transaction/tampered-nonce` | The nonce was changed after signing |
| `proofs.json` | `negative/wrong-root` | The proof is checked against another root |
| `proofs.json` | `negative/wrong-value` | The claimed value is not the stored one |
| `proofs.json` | `negative/absence-of-present-key` | Absence is claimed for a key that is present |
| `proofs.json` | `negative/tampered-entry` | The leaf's bytes are altered under its original CID, claiming the altered value. Only the entry-CID check rejects it |

## Encoding details

Encoding details an SDK must match, all visible in `encoding.json`. The
specification states them in [§3.8](../docs/spec.md#38-encoding).

- DAG-CBOR map keys are sorted by length first, then bytewise.
- A field that is a Header (a content-addressed child object, such as a
  block's `spec`, `transactions` or states, or a transaction's `body`) is the
  map `{"rawCID": "<cid>"}`, not a tag-42 link. Other CID-valued fields are
  plain text strings: addresses (`signers`, `owner`, `demander`,
  `withdrawer`). `PublicKey.key` is the Multikey
  hex as a text string.
- A `U256` is a `"0x"`-prefixed, lowercase hex string of minimal length: no
  leading zero digits, so zero is `"0x0"` (see
  `block/genesis-non-max-target`).
- An absent optional field is omitted, not encoded as null.
- A transaction's `signatures` is an array of `{"key", "value"}` maps
  (public-key hex, signature hex), sorted ascending by `key`, independent of
  the order of `signers` (see `transaction/signed-two-signers`).
- A CID string is multibase prefix `b` followed by lowercase RFC 4648 base32
  without padding of the binary CID: version `0x01` (CIDv1), codec `0x71`
  (dag-cbor), then the multihash `0x12 0x20` (sha2-256, 32 bytes) and the
  SHA-256 digest of the DAG-CBOR bytes.
- `WasmPolicyRef.moduleCID` in `chain-spec/with-wasm-policy` is an opaque
  string here; the encoding does not validate it as a CID.

The keys come from the golden generator's fixed seed (`GoldenRandom(seed:
0x5EED_5EED)`). Generation uses no clock and no system randomness.

## Signatures and hosts

The committed signatures are the deterministic RFC 8032 Ed25519 signatures,
which any RFC 8032 signer reproduces from `privateKey` and `signedBytesHex`.
swift-crypto signs this way on Linux (BoringSSL). CryptoKit on Apple platforms
randomizes Ed25519 signatures instead. Both are valid, and verification is the
consensus rule. So:

- a host that signs deterministically must reproduce each signature byte for
  byte;
- a host that does not (macOS) keeps the committed signature, as long as
  Lattice still verifies it.

Regenerate any vector that adds or changes a signature on Linux. A signature
regenerated on macOS is random, and the Linux CI job rejects it.

## Regenerating

```sh
LATTICE_REGENERATE_GOLDENS=1 swift test --filter ConformanceVectorTests
```

This rewrites the files, and then the tests FAIL on purpose, so that a
changed vector always shows up as a reviewed diff. Unset the variable and
rerun, and the tests pass. For signatures, run it on Linux, for example in
`swift:6.1-jammy`.

## Versioning

This rule is a review convention; no check enforces it.

- Adding a vector or a file is additive. It keeps `version`.
- Changing or removing an existing vector changes what "conforming" means.
  That is a consensus-level change, so it must bump `version`, and the PR
  must call it out. All files share one version,
  `ConformanceVectorTests.vectorVersion`.

SDKs should pin the `version` they were checked against.
