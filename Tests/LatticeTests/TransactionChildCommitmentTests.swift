import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeValidation
import UInt256
import cashew
import Foundation

/// A `child/X` = C action is valid only in a block whose `children[X]` is C.
final class TransactionChildCommitmentTests: XCTestCase {

    private let directory = "Payments"

    private func commitTransaction(
        oldValue: String?, newValue: String?, nonce: UInt64,
        by keyPair: (privateKey: String, publicKey: String)
    ) -> Transaction {
        signedTestTransaction(TransactionBody(
            accountActions: [],
            actions: [Action(key: CHILD_COMMITMENT_KEY_PREFIX + directory, oldValue: oldValue, newValue: newValue)],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [testAddress(publicKey: keyPair.publicKey)], nonce: nonce, chainPath: ["Nexus"]
        ), by: keyPair)
    }

    private func genesis(_ fetcher: StorableFetcher) async throws -> Block {
        try await buildAndStoreGenesis(
            spec: ChainSpec.test(), timestamp: Int64(Date().timeIntervalSince1970 * 1000) - 20_000,
            target: UInt256.max, fetcher: fetcher
        )
    }

    private func child(_ nonce: UInt64) -> (block: Block, cid: String) {
        let block = makeGenesisBlock(spec: ChainSpec.test(), nonce: nonce)
        return (block, try! BlockHeader(node: block).rawCID)
    }

    func testMatchingChildEntryIsValid() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        let c = child(1)
        let block = try await buildAndStoreBlock(
            previous: g, transactions: [commitTransaction(oldValue: nil, newValue: c.cid, nonce: 0, by: kp)],
            children: [directory: c.block], timestamp: g.timestamp + 1_000, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }

    func testDifferentChildEntryIsInvalid() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        let block = try await buildAndStoreBlock(
            previous: g, transactions: [commitTransaction(oldValue: nil, newValue: child(1).cid, nonce: 0, by: kp)],
            children: [directory: child(2).block], timestamp: g.timestamp + 1_000, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "the action and children[X] name different child blocks")
    }

    func testMissingChildEntryIsInvalid() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        let block = try await buildAndStoreBlock(
            previous: g, transactions: [commitTransaction(oldValue: nil, newValue: child(1).cid, nonce: 0, by: kp)],
            timestamp: g.timestamp + 1_000, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "a child/X action needs children[X]")
    }

    func testChildEntryWithoutActionIsValid() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let block = try await buildAndStoreBlock(
            previous: g, children: [directory: child(1).block],
            timestamp: g.timestamp + 1_000, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }

    func testDeleteCommitsNothing() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        let c = child(1)
        let committed = try await buildAndStoreBlock(
            previous: g, transactions: [commitTransaction(oldValue: nil, newValue: c.cid, nonce: 0, by: kp)],
            children: [directory: c.block], timestamp: g.timestamp + 1_000, fetcher: fetcher
        )
        let deleted = try await buildAndStoreBlock(
            previous: committed, transactions: [commitTransaction(oldValue: c.cid, newValue: nil, nonce: 1, by: kp)],
            timestamp: g.timestamp + 2_000, fetcher: fetcher
        )
        let valid = try await deleted.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid, "a delete needs no children entry")
    }
}
