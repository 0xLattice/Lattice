import XCTest
import Foundation
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeValidation
import cashew

private struct RNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Independent oracle: every child edge is a place; the root is a place.
private func oraclePlaces(_ root: any Header) -> [String: Int] {
    var counts: [String: Int] = [:]
    var stack: [any Header] = [root]
    while let h = stack.popLast() {
        counts[h.rawCID, default: 0] += 1
        guard let node = h.node else { fatalError("oracle needs a fully resolved tree") }
        for p in node.properties() { if let c = node.get(property: p) { stack.append(c) } }
    }
    return counts
}

private func storeAllLoaded(_ header: any Header, _ storer: any VolumeStorer) async throws {
    guard let node = header.node else { return }
    if let volume = header as? any Volume { try await volume.store(storer: storer) }
    for p in node.properties() { if let c = node.get(property: p) { try await storeAllLoaded(c, storer) } }
}

/// Randomly unloads subtrees (keeps CIDs).
private func strip(_ h: any Header, _ rng: inout RNG, _ p: Double, keepRoot: Bool = false) -> any Header {
    stripTyped(h, &rng, p, keepRoot)
}
private func stripTyped<H: Header>(_ h: H, _ rng: inout RNG, _ p: Double, _ keepRoot: Bool) -> H {
    guard let node = h.node else { return h }
    if !keepRoot, Double.random(in: 0..<1, using: &rng) < p { return H(rawCID: h.rawCID) }
    var props: [String: any Header] = [:]
    for prop in node.properties() { if let c = node.get(property: prop) { props[prop] = strip(c, &rng, p) } }
    let rebuilt = try! H(node: node.set(properties: props))
    precondition(rebuilt.rawCID == h.rawCID, "strip changed CID")
    return rebuilt
}

private func netted(_ diff: StateDiff) -> [String: Int] {
    var n: [String: Int] = [:]
    for (c, k) in diff.created { n[c, default: 0] += k }
    for (c, k) in diff.replaced { n[c, default: 0] -= k }
    return n.filter { $0.value != 0 }
}

private func expected(_ before: [String: Int], _ after: [String: Int]) -> [String: Int] {
    var e = after
    for (c, k) in before { e[c, default: 0] -= k }
    return e.filter { $0.value != 0 }
}

private enum LoadMode: CaseIterable { case rootOnly, full, partial, targeted }

/// A block's diff, netted per CID, is the change in places of the whole
/// state whatever part of the previous state is loaded: the root alone
/// (`validatePostState`), all of it (`BlockBuilder.computePostState`),
/// a random part, or the paths a block touches. The oracle resolves both
/// states whole and counts every child edge and the root. Bigger runs:
/// STATE_DIFF_SEEDS, STATE_DIFF_BLOCKS, STATE_DIFF_LSEEDS, STATE_DIFF_ALL_ALPHABETS.
final class StateDiffPartialLoadingTests: XCTestCase {

    // MARK: General state

    func testGeneralStateDiffUnderEveryLoading() async throws {
        let env = ProcessInfo.processInfo.environment
        let seeds = Int(env["STATE_DIFF_SEEDS"] ?? "4") ?? 4
        let blocks = Int(env["STATE_DIFF_BLOCKS"] ?? "20") ?? 20
        // Small alphabets make equal nodes, which is where an inexact diff
        // shows; the wider ones run with STATE_DIFF_ALL_ALPHABETS=1.
        var alphabets: [[Character]] = [Array("ab"), Array("abc")]
        if env["STATE_DIFF_ALL_ALPHABETS"] != nil {
            alphabets += [Array("abcdef"), Array("ab0123456789xyz"), ["a", "b", "é", "e\u{301}", "🇺", "🇸", "\u{301}"]]
        }
        var failures = 0
        var checked = 0
        for alpha in alphabets.indices {
            for seed in 0..<seeds {
                for mode in LoadMode.allCases {
                    let f = try await runGeneral(seed: UInt64(seed * 131 + alpha * 7 + 1), alphabet: alphabets[alpha], blocks: blocks, mode: mode, checked: &checked)
                    failures += f
                    if failures > 5 { XCTFail("too many failures"); return }
                }
            }
        }
        print("general checked \(checked) blocks, failures \(failures)")
    }

    private func runGeneral(seed: UInt64, alphabet: [Character], blocks: Int, mode: LoadMode, checked: inout Int) async throws -> Int {
        var rng = RNG(state: seed)
        let fetcher = StorableFetcher()
        var header = try GeneralStateHeader(node: GeneralState())
        try await header.storeRecursively(storer: fetcher)
        var kv: [String: String] = [:]
        var before = oraclePlaces(header)
        let maxLen = Int.random(in: 2...9, using: &rng)
        let values = Array(["1", "2", "3", "4"].prefix(Int.random(in: 1...4, using: &rng)))
        func randKey() -> String {
            let existing = kv.keys.sorted()
            if !existing.isEmpty, Int.random(in: 0..<3, using: &rng) > 0 {
                let base = existing.randomElement(using: &rng)!
                let chars = Array(base)
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: return String(chars.prefix(Int.random(in: 1...chars.count, using: &rng)))
                case 1: return base + String((0..<Int.random(in: 1...3, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
                case 2:
                    var c = chars; let i = Int.random(in: 0..<c.count, using: &rng); c[i] = alphabet.randomElement(using: &rng)!
                    return String(c)
                default:
                    return String(chars.prefix(Int.random(in: 1...chars.count, using: &rng))) + String(alphabet.randomElement(using: &rng)!)
                }
            }
            return String((0..<Int.random(in: 1...maxLen, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
        }
        var failures = 0
        for block in 0..<blocks {
            var actions: [Action] = []
            var used = Set<[UInt8]>()
            var next = kv
            let n = Int.random(in: 1...24, using: &rng)
            for _ in 0..<n {
                let k = randKey()
                // byte identity so canonical-equivalent keys don't collide in our model
                guard used.insert(Array(k.utf8)).inserted else { continue }
                if let old = kv[k] {
                    if Bool.random(using: &rng) { actions.append(Action(key: k, oldValue: old, newValue: nil)); next[k] = nil }
                    else {
                        let v = values.randomElement(using: &rng)!
                        actions.append(Action(key: k, oldValue: old, newValue: v)); next[k] = v
                    }
                } else {
                    let v = values.randomElement(using: &rng)!
                    actions.append(Action(key: k, oldValue: nil, newValue: v)); next[k] = v
                }
            }
            let prev: GeneralStateHeader
            switch mode {
            case .rootOnly: prev = GeneralStateHeader(rawCID: header.rawCID)
            case .full: prev = try await GeneralStateHeader(rawCID: header.rawCID).resolveRecursive(fetcher: fetcher)
            case .partial:
                let full = try await GeneralStateHeader(rawCID: header.rawCID).resolveRecursive(fetcher: fetcher)
                prev = strip(full, &rng, Double.random(in: 0.1...0.7, using: &rng)) as! GeneralStateHeader
            case .targeted:
                var paths: [[String]: ResolutionStrategy] = [:]
                for k in kv.keys.sorted() where Bool.random(using: &rng) { paths[[k]] = .targeted }
                prev = try await GeneralStateHeader(rawCID: header.rawCID).resolve(paths: paths, fetcher: fetcher)
            }
            let result: GeneralStateHeader
            let diff: StateDiff
            do {
                (result, diff) = try await prev.proveAndUpdateState(allActions: actions, fetcher: fetcher)
            } catch {
                // canonical-equivalence collisions etc.: model divergence, not a diff bug
                if alphabet.contains("é") { return failures }
                XCTFail("seed \(seed) block \(block) transform threw \(error)"); return failures + 1
            }
            try await storeAllLoaded(result, fetcher)
            let resolvedNew = try await GeneralStateHeader(rawCID: result.rawCID).resolveRecursive(fetcher: fetcher)
            let after = oraclePlaces(resolvedNew)
            let exp = expected(before, after)
            let got = netted(diff)
            checked += 1
            if got != exp {
                failures += 1
                XCTFail("GENERAL MISMATCH seed \(seed) mode \(mode) alpha \(String(alphabet)) block \(block)\n kv=\(kv.sorted { $0.key < $1.key })\n actions=\(actions.map { "\($0.key):\($0.oldValue ?? "-")->\($0.newValue ?? "-")" })\n got=\(got)\n exp=\(exp)")
                return failures
            }
            header = resolvedNew
            before = after
            kv = next
            // our model may diverge from cashew under canonical equivalence; resync from the trie
            if alphabet.contains("é") {
                kv = (try? resolvedNew.node!.allKeysAndValues()) ?? kv
            }
        }
        return failures
    }

    // MARK: Whole LatticeState, every action kind

    func testLatticeStateDiffUnderEveryLoading() async throws {
        let env = ProcessInfo.processInfo.environment
        let seeds = Int(env["STATE_DIFF_LSEEDS"] ?? "1") ?? 1
        let blocks = Int(env["STATE_DIFF_BLOCKS"] ?? "20") ?? 20
        var checked = 0
        for alpha in [Array("ab"), Array("abc"), Array("abcdefgh")] {
            for seed in 0..<seeds {
                for mode in LoadMode.allCases where mode != .targeted {
                    try await runLattice(seed: UInt64(seed * 977 + alpha.count), alphabet: alpha, blocks: blocks, mode: mode, checked: &checked)
                }
            }
        }
        print("lattice checked \(checked) blocks")
    }

    private func runLattice(seed: UInt64, alphabet: [Character], blocks: Int, mode: LoadMode, checked: inout Int) async throws {
        var rng = RNG(state: seed)
        let fetcher = StorableFetcher()
        var header = try LatticeStateHeader(node: LatticeState.emptyState())
        try await header.storeRecursively(storer: fetcher)
        func key(_ len: Int) -> String { String((0..<len).map { _ in alphabet.randomElement(using: &rng)! }) }
        var balances: [String: UInt64] = [:]
        var general: [String: String] = [:]
        var deposits: [(nonce: UInt128, demander: String, demanded: UInt64, deposited: UInt64)] = []
        var spent: Set<Int> = []
        var depositNonce: UInt128 = 0
        var receiptNonce: UInt128 = 0
        var before = oraclePlaces(try await LatticeStateHeader(rawCID: header.rawCID).resolveRecursive(fetcher: fetcher))
        for block in 0..<blocks {
            var accountActions: [AccountAction] = []
            var actions: [Action] = []
            var depositActions: [DepositAction] = []
            var withdrawalActions: [WithdrawalAction] = []
            var receiptActions: [ReceiptAction] = []
            var owners = Set<String>()
            var projected = balances
            for _ in 0..<Int.random(in: 0...10, using: &rng) {
                let owner = "o" + key(Int.random(in: 1...5, using: &rng))
                guard owners.insert(owner).inserted else { continue }
                let current = projected[owner] ?? 0
                if current > 0, Bool.random(using: &rng) {
                    let debit = Bool.random(using: &rng) ? current : UInt64.random(in: 1...current, using: &rng)
                    accountActions.append(AccountAction(owner: owner, delta: -Int64(debit)))
                    projected[owner] = current - debit
                } else {
                    let credit = UInt64.random(in: 1...3, using: &rng)
                    accountActions.append(AccountAction(owner: owner, delta: Int64(credit)))
                    projected[owner] = current + credit
                }
            }
            var keys = Set<String>()
            var nextGeneral = general
            for _ in 0..<Int.random(in: 0...12, using: &rng) {
                let k = key(Int.random(in: 1...6, using: &rng))
                guard keys.insert(k).inserted else { continue }
                if let old = general[k] {
                    if Bool.random(using: &rng) {
                        actions.append(Action(key: k, oldValue: old, newValue: nil)); nextGeneral[k] = nil
                    } else {
                        let v = ["1", "2"].randomElement(using: &rng)!
                        actions.append(Action(key: k, oldValue: old, newValue: v)); nextGeneral[k] = v
                    }
                } else {
                    let v = ["1", "2"].randomElement(using: &rng)!
                    actions.append(Action(key: k, oldValue: nil, newValue: v)); nextGeneral[k] = v
                }
            }
            for _ in 0..<Int.random(in: 0...4, using: &rng) {
                depositNonce += 1
                let d = (depositNonce, "d" + key(2), UInt64.random(in: 1...3, using: &rng), UInt64.random(in: 1...3, using: &rng))
                depositActions.append(DepositAction(nonce: d.0, demander: d.1, amountDemanded: d.2, amountDeposited: d.3))
                deposits.append(d)
            }
            let unspent = (0..<(deposits.count - depositActions.count)).filter { !spent.contains($0) }
            for index in unspent.shuffled(using: &rng).prefix(Int.random(in: 0...4, using: &rng)) {
                let d = deposits[index]
                withdrawalActions.append(WithdrawalAction(withdrawer: "w", nonce: d.nonce, demander: d.demander, amountDemanded: d.demanded, amountWithdrawn: d.deposited))
                spent.insert(index)
            }
            for _ in 0..<Int.random(in: 0...2, using: &rng) {
                if let payer = projected.filter({ $0.value >= 1 && !owners.contains($0.key) }).keys.sorted().randomElement(using: &rng) {
                    let demander = "o" + key(2)
                    if !owners.contains(demander), demander != payer {
                        receiptNonce += 1
                        receiptActions.append(ReceiptAction(withdrawer: payer, nonce: receiptNonce, demander: demander, amountDemanded: 1, directory: "X"))
                        projected[payer]! -= 1
                        projected[demander, default: 0] += 1
                        owners.insert(payer); owners.insert(demander)
                    }
                }
            }
            let prevNode: LatticeState
            switch mode {
            case .rootOnly, .targeted: prevNode = try await LatticeStateHeader(rawCID: header.rawCID).resolve(fetcher: fetcher).node!
            case .full: prevNode = try await LatticeStateHeader(rawCID: header.rawCID).resolveRecursive(fetcher: fetcher).node!
            case .partial:
                let full = try await LatticeStateHeader(rawCID: header.rawCID).resolveRecursive(fetcher: fetcher)
                prevNode = (strip(full, &rng, Double.random(in: 0.1...0.7, using: &rng), keepRoot: true) as! LatticeStateHeader).node!
            }
            let updated: LatticeState
            let diff: StateDiff
            do {
                (updated, diff) = try await prevNode.proveAndUpdateState(
                    allAccountActions: accountActions, allActions: actions, allDepositActions: depositActions,
                    allReceiptActions: receiptActions, allWithdrawalActions: withdrawalActions,
                    transactionBodies: [], fetcher: fetcher)
            } catch {
                XCTFail("seed \(seed) block \(block) threw \(error)"); return
            }
            let next = try LatticeStateHeader(node: updated)

            try await storeAllLoaded(next, fetcher)
            let resolvedNew = try await LatticeStateHeader(rawCID: next.rawCID).resolveRecursive(fetcher: fetcher)
            let after = oraclePlaces(resolvedNew)
            let exp = expected(before, after)
            let got = netted(diff)
            checked += 1
            if got != exp {
                XCTFail("LATTICE MISMATCH seed \(seed) mode \(mode) alpha \(String(alphabet)) block \(block): got \(got) exp \(exp)")
                return
            }
            header = next
            before = after
            balances = projected.filter { $0.value > 0 }
            general = nextGeneral
        }
    }
}
