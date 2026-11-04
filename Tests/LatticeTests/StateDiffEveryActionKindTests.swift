import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeValidation
import cashew

/// A block's diff, netted per CID, is the change in places of the whole
/// state, for every action kind, when the previous state starts unloaded,
/// as `validatePostState` resolves it. Keys are short and values few, so
/// a new node often equals one a split or a merge moves elsewhere.
@MainActor
final class StateDiffEveryActionKindTests: XCTestCase {
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

    /// How many places each CID holds in the state `cid`, resolved whole.
    private func places(_ cid: String, _ fetcher: StorableFetcher) async throws -> [String: Int] {
        var places: [String: Int] = [:]
        func count(_ header: any Header) {
            places[header.rawCID, default: 0] += 1
            guard let node = header.node else { return }
            for property in node.properties() {
                if let child = node.get(property: property) { count(child) }
            }
        }
        count(try await LatticeStateHeader(rawCID: cid).resolveRecursive(fetcher: fetcher))
        return places
    }

    /// Stores what a transition loaded, each Volume on its own, as a node does.
    private func storeLoaded(_ header: any Header, _ fetcher: StorableFetcher) async throws {
        guard let node = header.node else { return }
        if let volume = header as? any Volume { try await volume.store(storer: fetcher) }
        for property in node.properties() {
            if let child = node.get(property: property) { try await storeLoaded(child, fetcher) }
        }
    }

    func testTheNettedDiffIsTheChangeInPlacesForEveryActionKind() async throws {
        for seed in UInt64(1)...UInt64(24) {
            try await run(seed: seed)
        }
    }

    private func run(seed: UInt64) async throws {
        var rng = SplitMix64(state: seed)
        let fetcher = StorableFetcher()
        var header = try LatticeStateHeader(node: LatticeState.emptyState())
        try await header.storeRecursively(storer: fetcher)
        let alphabet = Array("ab")
        func key(_ len: Int) -> String { String((0..<len).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }) }
        var balances: [String: UInt64] = [:]
        var general: [String: String] = [:]
        var deposits: [(nonce: UInt128, demander: String, demanded: UInt64, deposited: UInt64)] = []
        var spent: Set<Int> = []
        var depositNonce: UInt128 = 0
        var receiptNonce: UInt128 = 0
        var before = try await places(header.rawCID, fetcher)
        for block in 0..<40 {
            var accountActions: [AccountAction] = []
            var actions: [Action] = []
            var depositActions: [DepositAction] = []
            var withdrawalActions: [WithdrawalAction] = []
            var receiptActions: [ReceiptAction] = []
            var owners = Set<String>()
            var projected = balances
            for _ in 0..<Int.random(in: 0...4, using: &rng) {
                let owner = "o" + key(Int.random(in: 1...3, using: &rng))
                guard owners.insert(owner).inserted else { continue }
                let current = projected[owner] ?? 0
                if current > 0, Bool.random(using: &rng) {
                    let debit = Bool.random(using: &rng) ? current : UInt64.random(in: 1...current, using: &rng)
                    accountActions.append(AccountAction(owner: owner, delta: -Int64(debit)))
                    projected[owner] = current - debit
                } else {
                    let credit = UInt64.random(in: 1...50, using: &rng)
                    accountActions.append(AccountAction(owner: owner, delta: Int64(credit)))
                    projected[owner] = current + credit
                }
            }
            var keys = Set<String>()
            var nextGeneral = general
            for _ in 0..<Int.random(in: 0...5, using: &rng) {
                let k = key(Int.random(in: 1...4, using: &rng))
                guard keys.insert(k).inserted else { continue }
                if let old = general[k] {
                    if Bool.random(using: &rng) {
                        actions.append(Action(key: k, oldValue: old, newValue: nil)); nextGeneral[k] = nil
                    } else {
                        let v = ["1", "2", "3"].randomElement(using: &rng)!
                        guard v != old else { continue }
                        actions.append(Action(key: k, oldValue: old, newValue: v)); nextGeneral[k] = v
                    }
                } else {
                    let v = ["1", "2", "3"].randomElement(using: &rng)!
                    actions.append(Action(key: k, oldValue: nil, newValue: v)); nextGeneral[k] = v
                }
            }
            for _ in 0..<Int.random(in: 0...2, using: &rng) {
                depositNonce += 1
                let d = (depositNonce, "d" + key(2), UInt64.random(in: 1...9, using: &rng), UInt64.random(in: 1...9, using: &rng))
                depositActions.append(DepositAction(nonce: d.0, demander: d.1, amountDemanded: d.2, amountDeposited: d.3))
                deposits.append(d)
            }
            // Withdrawals spend deposits of earlier blocks.
            let unspent = (0..<(deposits.count - depositActions.count)).filter { !spent.contains($0) }
            for index in unspent.shuffled(using: &rng).prefix(Int.random(in: 0...2, using: &rng)) {
                let d = deposits[index]
                withdrawalActions.append(WithdrawalAction(
                    withdrawer: "w", nonce: d.nonce, demander: d.demander, amountDemanded: d.demanded, amountWithdrawn: d.deposited
                ))
                spent.insert(index)
            }
            // A receipt: the withdrawer pays the demander.
            if let payer = projected.filter({ $0.value >= 3 && !owners.contains($0.key) }).keys.sorted().first, Bool.random(using: &rng) {
                receiptNonce += 1
                let demander = "o" + key(2)
                if !owners.contains(demander), demander != payer {
                    receiptActions.append(ReceiptAction(withdrawer: payer, nonce: receiptNonce, demander: demander, amountDemanded: 2, directory: "X"))
                    projected[payer]! -= 2
                    projected[demander, default: 0] += 2
                }
            }

            // Execution starts from the root alone, as validatePostState does.
            let prev = try await LatticeStateHeader(rawCID: header.rawCID).resolve(fetcher: fetcher)
            let (updated, diff) = try await XCTUnwrap(prev.node).proveAndUpdateState(
                allAccountActions: accountActions, allActions: actions, allDepositActions: depositActions,
                allReceiptActions: receiptActions, allWithdrawalActions: withdrawalActions,
                transactionBodies: [], fetcher: fetcher
            )
            let next = try LatticeStateHeader(node: updated)
            try await storeLoaded(next, fetcher)
            let after = try await places(next.rawCID, fetcher)
            var expected = after
            for (cid, n) in before { expected[cid, default: 0] -= n }
            var netted = diff.created
            for (cid, n) in diff.replaced { netted[cid, default: 0] -= n }
            XCTAssertEqual(
                netted.filter { $0.value != 0 }, expected.filter { $0.value != 0 },
                "seed \(seed) block \(block): \(accountActions.count)a \(actions.count)g \(depositActions.count)d \(withdrawalActions.count)w \(receiptActions.count)r"
            )
            header = next
            before = after
            balances = projected.filter { $0.value > 0 }
            general = nextGeneral
        }
    }
}
