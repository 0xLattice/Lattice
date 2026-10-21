import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import cashew

private func makeFetcher() -> StorableFetcher { StorableFetcher() }

@MainActor
final class StateDiffTests: XCTestCase {

    // MARK: - diffCIDs fundamentals

    func testIdenticalHeadersProduceEmptyDiff() async throws {
        let fetcher = makeFetcher()
        var dict = AccountState()
        dict = try dict.inserting(key: "alice", value: 100)
        let header = try! AccountStateHeader(node: dict)
        try await header.storeRecursively(storer: fetcher)

        let diff = diffCIDs(old: header, new: header)
        XCTAssertTrue(diff.isEmpty)
        XCTAssertTrue(diff.replaced.isEmpty)
        XCTAssertTrue(diff.created.isEmpty)
    }

    func testSingleInsertionIntoEmptyTrie() async throws {
        let fetcher = makeFetcher()
        let empty = try! AccountStateHeader(node: AccountState())
        try await empty.storeRecursively(storer: fetcher)

        let (result, diff) = try await empty.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: "alice", delta: 100)],
            fetcher: fetcher
        )

        XCTAssertFalse(diff.isEmpty)
        XCTAssertFalse(diff.created.isEmpty, "insertion should produce created CIDs")
        XCTAssertTrue(diff.replaced.values.allSatisfy { $0 > 0 })
        XCTAssertTrue(diff.created.values.allSatisfy { $0 > 0 })
        XCTAssertNotEqual(empty.rawCID, result.rawCID)

        for cid in diff.created.keys {
            XCTAssertFalse(diff.replaced.keys.contains(cid),
                "a newly created CID should not also be in replaced (insertion path)")
        }
    }

    func testSingleMutationDiff() async throws {
        let fetcher = makeFetcher()
        var dict = AccountState()
        dict = try dict.inserting(key: "alice", value: 50)
        let header = try! AccountStateHeader(node: dict)
        try await header.storeRecursively(storer: fetcher)

        let resolved = try await header.resolve(fetcher: fetcher)
        let proven = try await resolved.proof(paths: [["alice"]: .mutation], fetcher: fetcher)
        guard let result = try proven.transform(transforms: [["alice"]: .update("200")]) else {
            return XCTFail("transform returned nil")
        }

        let diff = diffCIDs(old: proven, new: result)
        XCTAssertFalse(diff.replaced.isEmpty, "mutation should replace old path CIDs")
        XCTAssertFalse(diff.created.isEmpty, "mutation should create new path CIDs")
        XCTAssertEqual(diff.replaced.count, diff.created.count,
            "mutation modifies the same # of nodes on the path (old → new)")

        XCTAssertTrue(diff.replaced.keys.contains(proven.rawCID))
        XCTAssertTrue(diff.created.keys.contains(result.rawCID))

        let overlap = Set(diff.replaced.keys).intersection(diff.created.keys)
        XCTAssertTrue(overlap.isEmpty, "replaced and created should be disjoint for a mutation")
    }

    func testSingleDeletionDiff() async throws {
        let fetcher = makeFetcher()
        var dict = AccountState()
        dict = try dict.inserting(key: "alice", value: 100)
        dict = try dict.inserting(key: "bob", value: 200)
        let header = try! AccountStateHeader(node: dict)
        try await header.storeRecursively(storer: fetcher)

        let resolved = try await header.resolve(paths: [["alice"]: .targeted], fetcher: fetcher)
        let proven = try await resolved.proof(paths: [["alice"]: .deletion], fetcher: fetcher)
        guard let result = try proven.transform(transforms: [["alice"]: .delete]) else {
            return XCTFail("transform returned nil")
        }

        let diff = diffCIDs(old: proven, new: result)
        XCTAssertFalse(diff.replaced.isEmpty, "deletion should have replaced CIDs")
        XCTAssertTrue(diff.replaced.count > diff.created.count,
            "deletion removes more nodes than it creates")
    }

    func testInsertionCreatesNoReplacedLeaf() async throws {
        let fetcher = makeFetcher()
        var dict = AccountState()
        dict = try dict.inserting(key: "alice", value: 100)
        let header = try! AccountStateHeader(node: dict)
        try await header.storeRecursively(storer: fetcher)

        let proven = try await header.proof(paths: [["bob"]: .insertion], fetcher: fetcher)
        guard let result = try proven.transform(transforms: [["bob"]: .insert("200")]) else {
            return XCTFail("transform returned nil")
        }

        let diff = diffCIDs(old: proven, new: result)
        XCTAssertTrue(diff.created.count > diff.replaced.count,
            "insertion creates more nodes than it replaces (new leaf + potentially new internal)")
    }

    // MARK: - Reference counting

    func testReferenceCounts() async throws {
        let fetcher = makeFetcher()
        let empty = try! AccountStateHeader(node: AccountState())
        try await empty.storeRecursively(storer: fetcher)

        let (afterFirst, diff1) = try await empty.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: "alice", delta: 100)],
            fetcher: fetcher
        )
        try await afterFirst.storeRecursively(storer: fetcher)

        let (_, diff2) = try await afterFirst.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: "bob", delta: 200)],
            fetcher: fetcher
        )

        for (_, count) in diff1.replaced { XCTAssertEqual(count, 1) }
        for (_, count) in diff1.created { XCTAssertEqual(count, 1) }
        for (_, count) in diff2.replaced { XCTAssertEqual(count, 1) }
        for (_, count) in diff2.created { XCTAssertEqual(count, 1) }
    }

    func testMergingDiffsAccumulatesCounts() async {
        let a = StateDiff(
            replaced: ["cid1": 1, "cid2": 1],
            created: ["cid3": 1]
        )
        let b = StateDiff(
            replaced: ["cid2": 1, "cid4": 1],
            created: ["cid3": 2, "cid5": 1]
        )

        let merged = a.merging(b)
        XCTAssertEqual(merged.replaced["cid1"], 1)
        XCTAssertEqual(merged.replaced["cid2"], 2)
        XCTAssertEqual(merged.replaced["cid4"], 1)
        XCTAssertEqual(merged.created["cid3"], 3)
        XCTAssertEqual(merged.created["cid5"], 1)
    }

    func testMutatingMerge() async {
        var a = StateDiff(replaced: ["x": 1], created: ["y": 1])
        let b = StateDiff(replaced: ["x": 2], created: ["y": 3, "z": 1])
        a.merge(b)
        XCTAssertEqual(a.replaced["x"], 3)
        XCTAssertEqual(a.created["y"], 4)
        XCTAssertEqual(a.created["z"], 1)
    }

    // MARK: - Multi-key operations

    func testMultipleInsertions() async throws {
        let fetcher = makeFetcher()
        let empty = try! AccountStateHeader(node: AccountState())
        try await empty.storeRecursively(storer: fetcher)

        let (result, diff) = try await empty.proveAndUpdateState(
            allAccountActions: [
                AccountAction(owner: "alice", delta: 100),
                AccountAction(owner: "bob", delta: 200),
                AccountAction(owner: "charlie", delta: 300)
            ],
            fetcher: fetcher
        )

        XCTAssertFalse(diff.isEmpty)
        XCTAssertNotEqual(empty.rawCID, result.rawCID)
        let totalCreated = diff.created.values.reduce(0, +)
        XCTAssertGreaterThanOrEqual(totalCreated, 3,
            "at least 3 leaf CIDs should be created for 3 insertions")
    }

    func testMultipleMutations() async throws {
        let fetcher = makeFetcher()
        var dict = AccountState()
        dict = try dict.inserting(key: "alice", value: 10)
        dict = try dict.inserting(key: "bob", value: 20)
        dict = try dict.inserting(key: "charlie", value: 30)
        let header = try! AccountStateHeader(node: dict)
        try await header.storeRecursively(storer: fetcher)

        let (result, diff) = try await header.proveAndUpdateState(
            allAccountActions: [
                AccountAction(owner: "alice", delta: 5),
                AccountAction(owner: "bob", delta: 10),
                AccountAction(owner: "charlie", delta: 15)
            ],
            fetcher: fetcher
        )

        XCTAssertFalse(diff.replaced.isEmpty)
        XCTAssertFalse(diff.created.isEmpty)
        XCTAssertNotEqual(header.rawCID, result.rawCID)
    }

    // MARK: - Successive transforms share no CIDs

    func testSuccessiveTransformsProduceDisjointDiffs() async throws {
        let fetcher = makeFetcher()
        let empty = try! AccountStateHeader(node: AccountState())
        try await empty.storeRecursively(storer: fetcher)

        let (after1, diff1) = try await empty.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: "alice", delta: 100)],
            fetcher: fetcher
        )
        try await after1.storeRecursively(storer: fetcher)

        let (after2, diff2) = try await after1.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: "alice", delta: 50)],
            fetcher: fetcher
        )

        let created1 = Set(diff1.created.keys)
        let created2 = Set(diff2.created.keys)
        let overlap = created1.intersection(created2)
        XCTAssertTrue(overlap.isEmpty,
            "two transforms of the same key should produce different created CIDs (different values → different hashes)")

        XCTAssertTrue(Set(diff2.replaced.keys).isSubset(of: created1),
            "second transform's replaced CIDs should be a subset of first transform's created CIDs")
        XCTAssertNotEqual(after1.rawCID, after2.rawCID)
    }

    // MARK: - O(log n) behavior — diff only walks materialized paths

    func testDiffSizeIsLogarithmic() async throws {
        let fetcher = makeFetcher()
        var dict = AccountState()
        for i in 0..<100 {
            dict = try dict.inserting(key: "user_\(String(format: "%03d", i))", value: UInt64(i + 1))
        }
        let header = try! AccountStateHeader(node: dict)
        try await header.storeRecursively(storer: fetcher)

        let (_, diff) = try await header.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: "user_042", delta: 1)],
            fetcher: fetcher
        )

        let totalNodes = diff.replaced.count + diff.created.count
        XCTAssertLessThan(totalNodes, 40,
            "modifying 1 key in a 100-key trie should touch O(log n) nodes, not \(totalNodes)")
    }

    // MARK: - Nonce tracking creates additional CIDs

    func testNonceTrackingProducesExtraCIDs() async throws {
        let fetcher = makeFetcher()
        let empty = try! AccountStateHeader(node: AccountState())
        try await empty.storeRecursively(storer: fetcher)

        let kp = CryptoUtils.generateKeyPair()
        let owner = try! HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID
        let body = TransactionBody(
            accountActions: [AccountAction(owner: owner, delta: 100)],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [owner], nonce: 0,
            chainPath: ["Nexus"]
        )

        let (_, diffWithNonce) = try await empty.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: owner, delta: 100)],
            transactionBodies: [body],
            fetcher: fetcher
        )

        let (_, diffWithoutNonce) = try await empty.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: owner, delta: 100)],
            fetcher: fetcher
        )

        XCTAssertGreaterThan(diffWithNonce.created.count, diffWithoutNonce.created.count,
            "nonce tracking inserts an extra key, creating additional CIDs")
    }

    func testMaximumNonceRejectsWithoutWrapping() async throws {
        XCTAssertThrowsError(
            try AccountStateHeader.nextExpectedNonce(afterStored: .max)
        )

        let state = try AccountStateHeader(node: AccountState())
        let transaction = TransactionBody(
            accountActions: [], actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: ["owner"], nonce: .max,
            chainPath: ["Nexus"]
        )
        do {
            _ = try await state.proveAndUpdateState(
                allAccountActions: [],
                transactionBodies: [transaction, transaction],
                fetcher: makeFetcher()
            )
            XCTFail("duplicate maximum nonces must be rejected")
        } catch StateErrors.nonceGap {
            // Expected.
        }
    }

    // MARK: - LatticeState aggregated diff

    func testLatticeStateAggregatesDiffsFromSubStates() async throws {
        let fetcher = makeFetcher()
        let state = LatticeState.emptyState()
        let header = try! LatticeStateHeader(node: state)
        try await header.storeRecursively(storer: fetcher)

        let kp = CryptoUtils.generateKeyPair()
        let owner = try! HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        let (updated, diff) = try await state.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: owner, delta: 100)],
            allActions: [Action(key: "foo", oldValue: nil, newValue: "bar")],
            allDepositActions: [],
            allReceiptActions: [],
            allWithdrawalActions: [],
            transactionBodies: [],
            fetcher: fetcher
        )

        XCTAssertFalse(diff.isEmpty)
        XCTAssertGreaterThanOrEqual(diff.created.count, 2,
            "at least account + general state should have created CIDs")
        let previousRoot = try LatticeStateHeader(node: state).rawCID
        let updatedRoot = try LatticeStateHeader(node: updated).rawCID
        XCTAssertEqual(diff.replaced[previousRoot], 1)
        XCTAssertEqual(diff.created[updatedRoot], 1)
    }

    func testEmptyActionsProduceEmptyDiff() async throws {
        let fetcher = makeFetcher()
        let state = LatticeState.emptyState()
        let header = try! LatticeStateHeader(node: state)
        try await header.storeRecursively(storer: fetcher)

        let (newState, diff) = try await state.proveAndUpdateState(
            allAccountActions: [],
            allActions: [],
            allDepositActions: [],
            allReceiptActions: [],
            allWithdrawalActions: [],
            transactionBodies: [],
            fetcher: fetcher
        )

        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(state.accountState.rawCID, newState.accountState.rawCID)
    }

    // MARK: - GeneralState insert + delete round-trip

    func testGeneralStateDiffOnInsertThenDelete() async throws {
        let fetcher = makeFetcher()
        let empty = try! GeneralStateHeader(node: GeneralState())
        try await empty.storeRecursively(storer: fetcher)

        let (afterInsert, insertDiff) = try await empty.proveAndUpdateState(
            allActions: [Action(key: "mykey", oldValue: nil, newValue: "hello")],
            fetcher: fetcher
        )
        XCTAssertFalse(insertDiff.created.isEmpty)
        try await afterInsert.storeRecursively(storer: fetcher)

        let (afterDelete, deleteDiff) = try await afterInsert.proveAndUpdateState(
            allActions: [Action(key: "mykey", oldValue: "hello", newValue: nil)],
            fetcher: fetcher
        )

        XCTAssertFalse(deleteDiff.replaced.isEmpty)
        let insertCreated = Set(insertDiff.created.keys)
        let deleteReplaced = Set(deleteDiff.replaced.keys)
        XCTAssertTrue(deleteReplaced.isSubset(of: insertCreated),
            "deleting the same key should replace exactly the CIDs that were created by insertion")
        XCTAssertNotEqual(afterInsert.rawCID, afterDelete.rawCID)
    }

    // MARK: - GeneralState actions on a key and a key it prefixes

    /// One transaction may update or delete key K and insert a key extending
    /// K. cashew 5.0.0 refused this (the proof on K leaked into K's children).
    func testGeneralStateActionOnKeyAndKeyItPrefixes() async throws {
        let fetcher = makeFetcher()
        let empty = try! GeneralStateHeader(node: GeneralState())
        try await empty.storeRecursively(storer: fetcher)
        let (base, _) = try await empty.proveAndUpdateState(
            allActions: [
                Action(key: "profile/al", oldValue: nil, newValue: "v"),
                Action(key: "profile/al/d", oldValue: nil, newValue: "d"),
            ],
            fetcher: fetcher
        )
        try await base.storeRecursively(storer: fetcher)

        for keyAction in [
            Action(key: "profile/al", oldValue: "v", newValue: "w"),
            Action(key: "profile/al", oldValue: "v", newValue: "v"),
            Action(key: "profile/al", oldValue: "v", newValue: nil),
        ] {
            let (after, _) = try await base.proveAndUpdateState(
                allActions: [keyAction, Action(key: "profile/al/c", oldValue: nil, newValue: "x")],
                fetcher: fetcher
            )
            XCTAssertEqual(try after.node?.get(key: "profile/al"), keyAction.newValue)
            XCTAssertEqual(try after.node?.get(key: "profile/al/c"), "x")
            XCTAssertEqual(try after.node?.get(key: "profile/al/d"), "d")
        }
    }

    // MARK: - DepositState two-phase diff

    func testDepositWithdrawalDiff() async throws {
        let fetcher = makeFetcher()
        let empty = try! DepositStateHeader(node: DepositState())
        try await empty.storeRecursively(storer: fetcher)

        let depositAction = DepositAction(
            nonce: 1, demander: "alice", amountDemanded: 100, amountDeposited: 100
        )
        let (afterDeposit, depositDiff) = try await empty.proveAndUpdateState(
            allDepositActions: [depositAction],
            fetcher: fetcher
        )
        XCTAssertFalse(depositDiff.created.isEmpty)
        try await afterDeposit.storeRecursively(storer: fetcher)

        let withdrawalAction = WithdrawalAction(
            withdrawer: "bob", nonce: 1, demander: "alice", amountDemanded: 100, amountWithdrawn: 100
        )
        let (afterWithdrawal, withdrawalDiff) = try await afterDeposit.proveAndSpendForWithdrawals(
            allWithdrawalActions: [withdrawalAction],
            fetcher: fetcher
        )

        XCTAssertFalse(withdrawalDiff.replaced.isEmpty,
            "withdrawing a deposit should replace CIDs")
        XCTAssertNotEqual(afterDeposit.rawCID, afterWithdrawal.rawCID)
    }

    func testSpentDepositCannotBeRecreatedOrWithdrawnAgain() async throws {
        let fetcher = makeFetcher()
        let empty = try DepositStateHeader(node: DepositState())
        try await empty.storeRecursively(storer: fetcher)
        let deposit = DepositAction(
            nonce: 1,
            demander: "alice",
            amountDemanded: 100,
            amountDeposited: 100
        )
        let withdrawal = WithdrawalAction(
            withdrawer: "bob",
            nonce: 1,
            demander: "alice",
            amountDemanded: 100,
            amountWithdrawn: 100
        )
        let (funded, _) = try await empty.proveAndUpdateState(
            allDepositActions: [deposit],
            fetcher: fetcher
        )
        try await funded.storeRecursively(storer: fetcher)
        let (spent, _) = try await funded.proveAndSpendForWithdrawals(
            allWithdrawalActions: [withdrawal],
            fetcher: fetcher
        )
        try await spent.storeRecursively(storer: fetcher)

        let key = DepositKey(depositAction: deposit).description
        XCTAssertEqual(try spent.node?.get(key: key), SPENT_DEPOSIT_MARKER)
        do {
            _ = try await spent.proveAndUpdateState(
                allDepositActions: [deposit],
                fetcher: fetcher
            )
            XCTFail("a spent deposit identity must not be recreated")
        } catch {
            guard case ProofErrors.invalidProofType = error else {
                return XCTFail("expected an existing-key proof failure, got \(error)")
            }
        }
        do {
            _ = try await spent.proveAndSpendForWithdrawals(
                allWithdrawalActions: [withdrawal],
                fetcher: fetcher
            )
            XCTFail("a spent deposit identity must not be withdrawn twice")
        } catch StateErrors.conflictingActions {}
    }

    // MARK: - Stub headers (node == nil)

    func testDiffWithOneStubHeader() async {
        let stub = AccountStateHeader(rawCID: "stubcid")
        let materialized = try! AccountStateHeader(node: AccountState())

        let diff1 = diffCIDs(old: stub, new: materialized)
        XCTAssertTrue(diff1.replaced.isEmpty, "stub old has no node → nothing replaced")
        XCTAssertFalse(diff1.created.isEmpty)

        let diff2 = diffCIDs(old: materialized, new: stub)
        XCTAssertFalse(diff2.replaced.isEmpty)
        XCTAssertTrue(diff2.created.isEmpty, "stub new has no node → nothing created")
    }

    func testDiffBetweenTwoStubs() async {
        let a = AccountStateHeader(rawCID: "cid_a")
        let b = AccountStateHeader(rawCID: "cid_b")
        let diff = diffCIDs(old: a, new: b)
        XCTAssertTrue(diff.replaced.isEmpty)
        XCTAssertTrue(diff.created.isEmpty)
    }

    // MARK: - Large trie single-key mutation (stress O(log n))

    func testLargeTrieSingleMutationBounded() async throws {
        let fetcher = makeFetcher()
        var dict = AccountState()
        for i in 0..<1000 {
            dict = try dict.inserting(key: "addr_\(String(format: "%04d", i))", value: UInt64(i + 1))
        }
        let header = try! AccountStateHeader(node: dict)
        try await header.storeRecursively(storer: fetcher)

        let (_, diff) = try await header.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: "addr_0500", delta: 1)],
            fetcher: fetcher
        )

        let totalTouched = diff.replaced.count + diff.created.count
        XCTAssertLessThan(totalTouched, 80,
            "single mutation in 1000-key trie should touch O(log n) ≈ 20-40 nodes, got \(totalTouched)")
    }
}
