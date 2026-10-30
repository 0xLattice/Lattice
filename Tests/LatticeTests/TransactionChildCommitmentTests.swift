import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeValidation
import UInt256
import cashew
import Foundation

/// A `child/X` = `C@P` action is valid only in a block whose `children[X]` is
/// C and whose `prevState` is P.
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

    /// The value committing `cid` on the state a block after `previous` enters.
    private func value(_ cid: String, after previous: Block) -> String {
        cid + "@" + previous.postState.rawCID
    }

    func testMatchingChildEntryIsValid() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        let c = child(1)
        let block = try await buildAndStoreBlock(
            previous: g, transactions: [commitTransaction(oldValue: nil, newValue: value(c.cid, after: g), nonce: 0, by: kp)],
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
            previous: g, transactions: [commitTransaction(oldValue: nil, newValue: value(child(1).cid, after: g), nonce: 0, by: kp)],
            children: [directory: child(2).block], timestamp: g.timestamp + 1_000,
            allowChildCommitmentMismatch: true, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "the action and children[X] name different child blocks")
    }

    func testMissingChildEntryIsInvalid() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        let block = try await buildAndStoreBlock(
            previous: g, transactions: [commitTransaction(oldValue: nil, newValue: value(child(1).cid, after: g), nonce: 0, by: kp)],
            timestamp: g.timestamp + 1_000, allowChildCommitmentMismatch: true, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "a child/X action needs children[X]")
    }

    /// `child/a/b` names no directory a block can carry, so it never matches.
    func testNonDirectoryKeyIsInvalid() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        let c = child(1)
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: CHILD_COMMITMENT_KEY_PREFIX + directory + "/b", oldValue: nil, newValue: value(c.cid, after: g))],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [testAddress(publicKey: kp.publicKey)], nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await buildAndStoreBlock(
            previous: g, transactions: [signedTestTransaction(body, by: kp)],
            children: [directory: c.block], timestamp: g.timestamp + 1_000,
            allowChildCommitmentMismatch: true, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid)
    }

    func testBuilderRefusesUnmatchedCommitment() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        let transaction = commitTransaction(oldValue: nil, newValue: value(child(1).cid, after: g), nonce: 0, by: kp)
        do {
            _ = try await BlockBuilder.buildBlock(
                previous: g, transactions: [transaction], children: [directory: child(2).block],
                timestamp: g.timestamp + 1_000, fetcher: fetcher
            )
            XCTFail("built a block whose commitment does not match children")
        } catch BlockBuilderError.unmatchedChildCommitment(let name) {
            XCTAssertEqual(name, directory)
        }
        do {
            _ = try await BlockBuilder.buildGenesis(
                spec: ChainSpec.test(), transactions: [transaction], children: [directory: child(2).block],
                timestamp: g.timestamp, target: .max, fetcher: fetcher
            )
            XCTFail("built a genesis whose commitment names another child and state")
        } catch BlockBuilderError.unmatchedChildCommitment(let name) {
            XCTAssertEqual(name, directory)
        }
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
            previous: g, transactions: [commitTransaction(oldValue: nil, newValue: value(c.cid, after: g), nonce: 0, by: kp)],
            children: [directory: c.block], timestamp: g.timestamp + 1_000, fetcher: fetcher
        )
        let deleted = try await buildAndStoreBlock(
            previous: committed, transactions: [commitTransaction(oldValue: value(c.cid, after: g), newValue: nil, nonce: 1, by: kp)],
            timestamp: g.timestamp + 2_000, fetcher: fetcher
        )
        let valid = try await deleted.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid, "a delete needs no children entry")
    }

    func testAnotherParentStateIsInvalid() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        let c = child(1)
        let block = try await buildAndStoreBlock(
            previous: g, transactions: [commitTransaction(oldValue: nil, newValue: c.cid + "@" + c.cid, nonce: 0, by: kp)],
            children: [directory: c.block], timestamp: g.timestamp + 1_000,
            allowChildCommitmentMismatch: true, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "the block does not enter the committed parent state")
    }

    func testMalformedValuesAreInvalid() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let c = child(1)
        let state = g.postState.rawCID
        for malformed in [c.cid, c.cid + "@", "@" + state, c.cid + "@" + state + "@" + state, c.cid + "@@" + state] {
            let block = try await buildAndStoreBlock(
                previous: g,
                transactions: [commitTransaction(oldValue: nil, newValue: malformed, nonce: 0, by: CryptoUtils.generateKeyPair())],
                children: [directory: c.block], timestamp: g.timestamp + 1_000,
                allowChildCommitmentMismatch: true, fetcher: fetcher
            )
            let valid = try await block.validateNexus(fetcher: fetcher).0
            XCTAssertFalse(valid, malformed)
        }
    }

    /// The builder carries a committed child it does not hold, by CID, and
    /// the block validates without the child's content.
    func testBuilderCarriesACommittedChildByCID() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        let c = child(1)
        let block = try await buildAndStoreBlock(
            previous: g, transactions: [commitTransaction(oldValue: nil, newValue: value(c.cid, after: g), nonce: 0, by: kp)],
            timestamp: g.timestamp + 1_000, fetcher: fetcher
        )
        let index = try await block.children.resolve(fetcher: fetcher).node
        XCTAssertEqual(index?[directory]?.rawCID, c.cid)
        let held = try? await fetcher.fetch(rawCid: c.cid)
        XCTAssertNil(held, "the child itself was never stored")
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }

    func testBuilderRefusesAnotherParentState() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        let c = child(1)
        do {
            _ = try await BlockBuilder.buildBlock(
                previous: g, transactions: [commitTransaction(oldValue: nil, newValue: c.cid + "@" + c.cid, nonce: 0, by: kp)],
                timestamp: g.timestamp + 1_000, fetcher: fetcher
            )
            XCTFail("built a block entering a state other than the committed one")
        } catch BlockBuilderError.unmatchedChildCommitment(let name) {
            XCTAssertEqual(name, directory)
        }
    }

    func testBuilderRefusesANonStandardChildCID() async throws {
        let fetcher = StorableFetcher()
        let g = try await genesis(fetcher)
        let kp = CryptoUtils.generateKeyPair()
        do {
            _ = try await BlockBuilder.buildBlock(
                previous: g,
                transactions: [commitTransaction(oldValue: nil, newValue: "not-a-cid@" + g.postState.rawCID, nonce: 0, by: kp)],
                timestamp: g.timestamp + 1_000, fetcher: fetcher
            )
            XCTFail("built a block whose children name a non-standard CID")
        } catch BlockBuilderError.unmatchedChildCommitment(let name) {
            XCTAssertEqual(name, directory)
        }
    }
}
