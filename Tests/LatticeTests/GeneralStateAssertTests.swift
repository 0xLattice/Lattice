import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeValidation
import UInt256
import cashew
import Foundation

/// An action whose oldValue and newValue are the same bytes asserts the key's
/// value before the block and writes nothing. Asserts never conflict with
/// each other; an assert and a write of one key conflict, as two writes do.
final class GeneralStateAssertTests: XCTestCase {

    private func base(_ fetcher: StorableFetcher) async throws -> GeneralStateHeader {
        let empty = try GeneralStateHeader(node: GeneralState())
        try await empty.storeRecursively(storer: fetcher)
        let (base, _) = try await empty.proveAndUpdateState(
            allActions: [
                Action(key: "offer", oldValue: nil, newValue: "v"),
                Action(key: "other", oldValue: nil, newValue: "o"),
            ],
            fetcher: fetcher
        )
        try await base.storeRecursively(storer: fetcher)
        return base
    }

    private func assertConflict(_ actions: [Action], on state: GeneralStateHeader, fetcher: StorableFetcher, _ message: String) async {
        do {
            _ = try await state.proveAndUpdateState(allActions: actions, fetcher: fetcher)
            XCTFail(message)
        } catch StateErrors.conflictingActions {
        } catch {
            XCTFail("\(message): expected conflictingActions, got \(error)")
        }
    }

    func testManyAssertsOnAKeyLeaveStateUnchanged() async throws {
        let fetcher = StorableFetcher()
        let state = try await base(fetcher)
        let assert = Action(key: "offer", oldValue: "v", newValue: "v")
        let (after, diff) = try await state.proveAndUpdateState(
            allActions: [assert, assert, assert, Action(key: "other", oldValue: "o", newValue: "o")],
            fetcher: fetcher
        )
        XCTAssertEqual(after.rawCID, state.rawCID)
        XCTAssertTrue(diff.isEmpty)
    }

    /// An assert and a write of one key cannot share a block, whichever
    /// transactions carry them, so a block's asserts all hold after it.
    func testAssertAndAWriteOfTheKeyConflict() async throws {
        let fetcher = StorableFetcher()
        let state = try await base(fetcher)
        let assert = Action(key: "offer", oldValue: "v", newValue: "v")
        for write in [
            Action(key: "offer", oldValue: "v", newValue: "w"),
            Action(key: "offer", oldValue: "v", newValue: nil),
        ] {
            for actions in [[assert, write], [write, assert], [assert, assert, write]] {
                await assertConflict(actions, on: state, fetcher: fetcher, "an assert and a write of one key must conflict")
            }
        }
    }

    /// Write skew: each transaction asserts the claim the other closes. Run
    /// one after the other, the second's assert would fail; together they
    /// must not land.
    func testWriteSkewIsRefused() async throws {
        let fetcher = StorableFetcher()
        let empty = try GeneralStateHeader(node: GeneralState())
        try await empty.storeRecursively(storer: fetcher)
        let (state, _) = try await empty.proveAndUpdateState(
            allActions: [
                Action(key: "claimA", oldValue: nil, newValue: "open"),
                Action(key: "claimB", oldValue: nil, newValue: "open"),
            ],
            fetcher: fetcher
        )
        try await state.storeRecursively(storer: fetcher)
        let tx1 = [Action(key: "claimB", oldValue: "open", newValue: "open"), Action(key: "claimA", oldValue: "open", newValue: "closed")]
        let tx2 = [Action(key: "claimA", oldValue: "open", newValue: "open"), Action(key: "claimB", oldValue: "open", newValue: "closed")]
        await assertConflict(tx1 + tx2, on: state, fetcher: fetcher, "the write-skew pair must not share a block")
        for tx in [tx1, tx2] {
            let (after, _) = try await state.proveAndUpdateState(allActions: tx, fetcher: fetcher)
            XCTAssertNotEqual(after.rawCID, state.rawCID)
        }
    }

    func testAssertOfAnotherValueIsRefused() async throws {
        let fetcher = StorableFetcher()
        let state = try await base(fetcher)
        await assertConflict(
            [Action(key: "offer", oldValue: "x", newValue: "x")],
            on: state, fetcher: fetcher, "an assert of a value the key does not hold must be refused"
        )
        await assertConflict(
            [Action(key: "offer", oldValue: "v", newValue: "v"), Action(key: "offer", oldValue: "x", newValue: "x")],
            on: state, fetcher: fetcher, "one wrong assert among right ones must be refused"
        )
    }

    func testAssertOnAMissingKeyIsRefused() async throws {
        let fetcher = StorableFetcher()
        let state = try await base(fetcher)
        await assertConflict(
            [Action(key: "absent", oldValue: "v", newValue: "v")],
            on: state, fetcher: fetcher, "an assert on a missing key must be refused"
        )
    }

    func testTwoWritesStillConflict() async throws {
        let fetcher = StorableFetcher()
        let state = try await base(fetcher)
        await assertConflict(
            [Action(key: "offer", oldValue: "v", newValue: "w"), Action(key: "offer", oldValue: "v", newValue: "x")],
            on: state, fetcher: fetcher, "two updates of one key must conflict"
        )
        await assertConflict(
            [Action(key: "offer", oldValue: "v", newValue: "w"), Action(key: "offer", oldValue: "v", newValue: nil)],
            on: state, fetcher: fetcher, "an update and a delete of one key must conflict"
        )
        await assertConflict(
            [Action(key: "new", oldValue: nil, newValue: "a"), Action(key: "new", oldValue: nil, newValue: "a")],
            on: state, fetcher: fetcher, "two inserts of one key must conflict"
        )
    }

    /// Same bytes, not String ==: canonically equivalent but byte-different
    /// spellings are a write, so two of them conflict.
    func testEquivalentSpellingsAreAWrite() async throws {
        let fetcher = StorableFetcher()
        let empty = try GeneralStateHeader(node: GeneralState())
        try await empty.storeRecursively(storer: fetcher)
        let (state, _) = try await empty.proveAndUpdateState(
            allActions: [Action(key: "k", oldValue: nil, newValue: "\u{E9}")],
            fetcher: fetcher
        )
        try await state.storeRecursively(storer: fetcher)
        let respell = Action(key: "k", oldValue: "\u{E9}", newValue: "e\u{301}")
        XCTAssertFalse(respell.isAssert)
        let (after, _) = try await state.proveAndUpdateState(allActions: [respell], fetcher: fetcher)
        XCTAssertEqual(try after.node?.get(key: "k").map { Array($0.utf8) }, Array("e\u{301}".utf8))
        await assertConflict([respell, respell], on: state, fetcher: fetcher, "two writes of one key must conflict")
    }

    func transaction(_ actions: [Action], nonce: UInt64, by keyPair: (privateKey: String, publicKey: String)) -> Transaction {
        signedTestTransaction(TransactionBody(
            accountActions: [], actions: actions,
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [testAddress(publicKey: keyPair.publicKey)], nonce: nonce, chainPath: ["Nexus"]
        ), by: keyPair)
    }

    /// Through a whole block: many transactions assert one key; another
    /// transaction's write of it cannot join them.
    func testBlockOfManyAssertsIsValidAndRefusesAWriteOfTheKey() async throws {
        let fetcher = StorableFetcher()
        let g = try await buildAndStoreGenesis(
            spec: ChainSpec.test(), timestamp: Int64(Date().timeIntervalSince1970 * 1000) - 20_000,
            target: UInt256.max, fetcher: fetcher
        )
        let seller = CryptoUtils.generateKeyPair()
        let listed = try await buildAndStoreBlock(
            previous: g, transactions: [transaction([Action(key: "offer", oldValue: nil, newValue: "v")], nonce: 0, by: seller)],
            timestamp: g.timestamp + 1_000, fetcher: fetcher
        )
        let assert = Action(key: "offer", oldValue: "v", newValue: "v")
        let orders = (0..<3).map { _ in transaction([assert, assert], nonce: 0, by: CryptoUtils.generateKeyPair()) }
        let block = try await buildAndStoreBlock(
            previous: listed, transactions: orders, timestamp: g.timestamp + 2_000, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)

        do {
            _ = try await buildAndStoreBlock(
                previous: listed,
                transactions: orders + [transaction([Action(key: "offer", oldValue: "v", newValue: "w")], nonce: 1, by: seller)],
                timestamp: g.timestamp + 2_000, fetcher: fetcher
            )
            XCTFail("built a block where an assert and another transaction's write share a key")
        } catch StateErrors.conflictingActions {}
    }
}
