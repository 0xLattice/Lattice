import Foundation
import XCTest
@testable import LatticePrimitives
@testable import LatticeValidation
@testable import LatticeImport
import cashew
import CID
import Multihash
import Multicodec

/// A block may reference content by a CID with a truncated digest. Before
/// cashew 5.0.2 such a CID authenticated any bytes matching its short digest,
/// so one block could resolve to a valid transaction set for some peers and an
/// invalid one for others: the same block CID, two permanent verdicts.
final class WeakDigestCIDTests: XCTestCase {
    private func oneByteDigestCID(_ data: Data) throws -> String {
        let multihash = try Multihash(raw: data, hashedWith: .sha2_256, customByteLength: 1)
        return try CID(version: .v1, codec: .dag_cbor, multihash: multihash).toBaseEncodedString
    }

    func testBlockNamingTransactionsByTruncatedDigestIsInvalidForEveryPeer() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let validSet = try XCTUnwrap(fetcher.entries[valid.transactions.rawCID])
        let weakCID = try oneByteDigestCID(validSet)

        // A different, invalid (unsigned) transaction set with the same 1-byte digest.
        var invalidSet: Data?
        var invalidEntries: [String: Data] = [:]
        for nonce in UInt64(0)..<5000 {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: "x", delta: 5)], actions: [], depositActions: [],
                receiptActions: [], withdrawalActions: [], signers: [], nonce: nonce,
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )
            let tx = Transaction(signatures: [:], body: try HeaderImpl<TransactionBody>(node: body))
            let header = try BlockBuilder.buildTransactionsDictionary([tx])
            let data = try XCTUnwrap(header.node?.toData())
            if try oneByteDigestCID(data) == weakCID {
                invalidSet = data
                let store = StorableFetcher()
                try await header.storeRecursively(storer: store)
                invalidEntries = store.entries
                break
            }
        }
        XCTAssertNotEqual(try XCTUnwrap(invalidSet), validSet)

        let block = Block(
            version: valid.version, parent: valid.parent, transactions: HeaderImpl(rawCID: weakCID),
            target: valid.target, nextTarget: valid.nextTarget, spec: valid.spec,
            parentState: valid.parentState, prevState: valid.prevState, postState: valid.postState,
            children: valid.children, height: valid.height, timestamp: valid.timestamp,
            rewardRecipient: valid.rewardRecipient, nonce: valid.nonce
        )
        var peerA = fetcher.entries
        peerA[weakCID] = validSet
        var peerB = fetcher.entries.merging(invalidEntries) { existing, _ in existing }
        peerB[weakCID] = invalidSet

        let context = ValidationContext(nowMilliseconds: 10_000)
        var verdicts: [BlockImportError?] = []
        for entries in [peerA, peerB] {
            do {
                let (isValid, _, _) = try await block.validateNexus(
                    fetcher: InMemoryContentSource(entries),
                    chainPath: [DEFAULT_ROOT_DIRECTORY],
                    validationContext: context
                )
                verdicts.append(isValid ? nil : .protocolInvalid)
            } catch {
                verdicts.append(classifyValidationFailure(error))
            }
        }
        XCTAssertEqual(verdicts, [.protocolInvalid, .protocolInvalid])
    }
}
