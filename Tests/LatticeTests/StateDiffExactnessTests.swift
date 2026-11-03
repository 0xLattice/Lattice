import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeValidation
import cashew

/// A transition's state diff, netted per CID, is the change in how many
/// places each CID holds in the whole state tree: what pruning by diffs,
/// and `storeMaterialized(createdBy:)`, rely on. Keys share long prefixes,
/// so insertions split radix nodes and deletions merge them.
@MainActor
final class StateDiffExactnessTests: XCTestCase {
    /// Deterministic, so a failure reproduces.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// How many places each CID holds in the tree under `header`, resolved whole.
    private func places(_ header: AccountStateHeader, _ fetcher: Fetcher) async throws -> [String: Int] {
        var counts: [String: Int] = [:]
        func walk(_ h: any Header) {
            counts[h.rawCID, default: 0] += 1
            guard let node = h.node else { return }
            for property in node.properties() { if let child = node.get(property: property) { walk(child) } }
        }
        walk(try await header.resolveRecursive(fetcher: fetcher))
        return counts
    }

    /// Stores what a transition loaded, each Volume on its own, as a node does.
    private func storeLoaded(_ header: any Header, _ storer: any VolumeStorer) async throws {
        guard let node = header.node else { return }
        if let volume = header as? any Volume { try await volume.store(storer: storer) }
        for property in node.properties() {
            if let child = node.get(property: property) { try await storeLoaded(child, storer) }
        }
    }

    /// The diff, netted, against the change in places from `before` to `after`.
    private func assertExact(
        _ diff: StateDiff, from before: [String: Int], to after: [String: Int], _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var expected: [String: Int] = [:]
        for (cid, n) in after { expected[cid, default: 0] += n }
        for (cid, n) in before { expected[cid, default: 0] -= n }
        var netted: [String: Int] = [:]
        for (cid, n) in diff.created { netted[cid, default: 0] += n }
        for (cid, n) in diff.replaced { netted[cid, default: 0] -= n }
        XCTAssertEqual(netted.filter { $0.value != 0 }, expected.filter { $0.value != 0 }, message, file: file, line: line)
    }

    /// Two insertions split `bbb` into `b`, `b`, `b`: the old children move
    /// down unloaded, and the new nodes between them are created.
    func testASplitCreatesEveryNodeBetweenItAndWhatMovedDown() async throws {
        let fetcher = StorableFetcher()
        let dict = try AccountState().inserting(key: "bbba", value: 1).inserting(key: "bbbb", value: 1)
        let header = try AccountStateHeader(node: dict)
        try await header.storeRecursively(storer: fetcher)
        let before = try await places(header, fetcher)
        let (result, diff) = try await AccountStateHeader(rawCID: header.rawCID).proveAndUpdateState(
            allAccountActions: [AccountAction(owner: "baba", delta: 1), AccountAction(owner: "bbab", delta: 1)],
            fetcher: fetcher
        )
        try await storeLoaded(result, fetcher)
        assertExact(diff, from: before, to: try await places(result, fetcher), "the split's diff")
    }

    /// The mirror: two deletions merge `b`, `b`, `b` back into `bbb`, and
    /// the nodes that were between go.
    func testAMergeReplacesEveryNodeBetweenItAndWhatMovedUp() async throws {
        let fetcher = StorableFetcher()
        var dict = AccountState()
        for key in ["bbba", "bbbb", "baba", "bbab"] { dict = try dict.inserting(key: key, value: 1) }
        let header = try AccountStateHeader(node: dict)
        try await header.storeRecursively(storer: fetcher)
        let before = try await places(header, fetcher)
        let (result, diff) = try await AccountStateHeader(rawCID: header.rawCID).proveAndUpdateState(
            allAccountActions: [AccountAction(owner: "baba", delta: -1), AccountAction(owner: "bbab", delta: -1)],
            fetcher: fetcher
        )
        try await storeLoaded(result, fetcher)
        assertExact(diff, from: before, to: try await places(result, fetcher), "the merge's diff")
        XCTAssertTrue(Set(diff.created.keys).isDisjoint(with: diff.replaced.keys), "a diff is netted per CID")
    }

    /// A block's whole post-state, stored by its diff alone, as admission
    /// stores it (`storeMaterialized(createdBy:)`), resolves whole from the
    /// store, when the block's insertions split a node.
    func testAPostStateStoredByItsDiffResolvesWholeAfterASplit() async throws {
        let fetcher = StorableFetcher()
        let account = try AccountStateHeader(node: AccountState().inserting(key: "bbba", value: 1).inserting(key: "bbbb", value: 1))
        let empty = LatticeState.emptyState()
        let state = LatticeState(
            accountState: account, generalState: empty.generalState,
            depositState: empty.depositState, receiptState: empty.receiptState
        )
        let header = try LatticeStateHeader(node: state)
        try await header.storeRecursively(storer: fetcher)
        let resolved = try await LatticeStateHeader(rawCID: header.rawCID).resolve(fetcher: fetcher)
        let prev = try XCTUnwrap(resolved.node)
        let (post, diff) = try await prev.proveAndUpdateState(
            allAccountActions: [AccountAction(owner: "baba", delta: 1), AccountAction(owner: "bbab", delta: 1)],
            allActions: [], allDepositActions: [], allReceiptActions: [], allWithdrawalActions: [],
            transactionBodies: [], fetcher: fetcher
        )
        let postHeader = try LatticeStateHeader(node: post)
        try await postHeader.storeMaterialized(createdBy: diff, storer: fetcher)
        let whole = try? await LatticeStateHeader(rawCID: postHeader.rawCID).resolveRecursive(fetcher: fetcher)
        XCTAssertNotNil(whole, "every node of the post-state is stored")
    }

    func testTheNettedDiffIsTheChangeInPlacesUnderSplitsAndMerges() async throws {
        for seed in UInt64(0)..<40 {
            var generator = SplitMix64(state: seed)
            let fetcher = StorableFetcher()
            func key() -> String { String((0..<6).map { _ in "ab".randomElement(using: &generator)! }) }
            var balances: [String: UInt64] = [:]
            var dict = AccountState()
            for _ in 0..<24 {
                let k = key()
                if balances[k] == nil { balances[k] = 1; dict = try dict.inserting(key: k, value: 1) }
            }
            var header = try AccountStateHeader(node: dict)
            try await header.storeRecursively(storer: fetcher)
            for round in 0..<12 {
                var actions: [AccountAction] = []
                var touched = Set<String>()
                for _ in 0..<Int.random(in: 1...5, using: &generator) {
                    let k = key()
                    guard touched.insert(k).inserted else { continue }
                    if let held = balances[k], Bool.random(using: &generator) {
                        actions.append(AccountAction(owner: k, delta: -Int64(held)))
                        balances[k] = nil
                    } else {
                        let d = UInt64.random(in: 1...9, using: &generator)
                        actions.append(AccountAction(owner: k, delta: Int64(d)))
                        balances[k, default: 0] += d
                    }
                }
                let before = try await places(header, fetcher)
                let (result, diff) = try await AccountStateHeader(rawCID: header.rawCID)
                    .proveAndUpdateState(allAccountActions: actions, fetcher: fetcher)
                try await storeLoaded(result, fetcher)
                assertExact(diff, from: before, to: try await places(result, fetcher), "seed \(seed), round \(round)")
                header = result
            }
        }
    }
}
