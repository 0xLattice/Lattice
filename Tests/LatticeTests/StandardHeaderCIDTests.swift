import Foundation
import XCTest
import CID
@testable import LatticePrimitives
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import cashew

/// Every CID link in a block header is the standard CID — CIDv1, dag-cbor,
/// sha2-256, a 32-byte digest (spec §3.1). A header with any other link is
/// malformed: its bytes do not decode as a block, so it is refused before
/// admission and never reaches a block tree.
final class StandardHeaderCIDTests: XCTestCase {
    private let digest = Array(try! CID(testCID("standard-link")).rawBuffer.suffix(32))

    /// Each shape a link may not take, by name.
    private var nonStandardShapes: [(name: String, cid: String)] {
        [
            ("raw (0x55)", CIDIdentity.base32Multibase([0x01, 0x55, 0x12, 0x20] + digest)),
            ("dag-pb (0x70)", CIDIdentity.base32Multibase([0x01, 0x70, 0x12, 0x20] + digest)),
            ("CIDv0", try! CID([0x12, 0x20] + digest).toBaseEncodedString),
            ("sha2-512", CIDIdentity.base32Multibase(
                [0x01, 0x71, 0x13, 0x40] + digest + digest
            )),
            ("20-byte sha2-256", CIDIdentity.base32Multibase(
                [0x01, 0x71, 0x12, 0x14] + digest.prefix(20)
            )),
            ("not a CID", "not-a-cid"),
        ]
    }

    func testOnlyTheStandardCIDIsStandard() {
        let standard = testCID("standard-link")
        XCTAssertTrue(CIDIdentity.isStandard(standard))
        XCTAssertFalse(CIDIdentity.isStandard(standard.uppercased()), "a non-canonical spelling")
        for shape in nonStandardShapes {
            XCTAssertFalse(CIDIdentity.isStandard(shape.cid), shape.name)
        }
    }

    /// `template` with one header link replaced.
    private func replacing(_ field: String, of template: Block, with cid: String) -> Block {
        Block(
            version: template.version,
            parent: field == "parent" ? VolumeImpl(rawCID: cid) : template.parent,
            transactions: field == "transactions" ? HeaderImpl(rawCID: cid) : template.transactions,
            target: template.target,
            nextTarget: template.nextTarget,
            spec: field == "spec" ? VolumeImpl(rawCID: cid) : template.spec,
            parentState: field == "parentState" ? LatticeStateHeader(rawCID: cid) : template.parentState,
            prevState: field == "prevState" ? LatticeStateHeader(rawCID: cid) : template.prevState,
            postState: field == "postState" ? LatticeStateHeader(rawCID: cid) : template.postState,
            children: field == "children" ? HeaderImpl(rawCID: cid) : template.children,
            height: template.height,
            timestamp: template.timestamp,
            rewardRecipient: template.rewardRecipient,
            nonce: template.nonce
        )
    }

    private let linkFields = [
        "parent", "transactions", "spec", "parentState", "prevState", "postState", "children",
    ]

    func testAHeaderWithANonStandardLinkDoesNotDecodeAndIsRefused() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let block = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)

        for field in linkFields {
            for shape in nonStandardShapes {
                let label = "\(field): \(shape.name)"
                let malformed = replacing(field, of: block, with: shape.cid)
                let data = try XCTUnwrap(malformed.toData(), label)
                XCTAssertNil(Block(data: data), label)

                let cid = try BlockHeader(node: malformed).rawCID
                fetcher.store(rawCid: cid, data: data)
                guard case .failure(let failure) = await BlockImport.resolveBlock(
                    BlockHeader(rawCID: cid), fetcher: fetcher
                ) else {
                    XCTFail("\(label): resolved")
                    continue
                }
                XCTAssertEqual(failure, .protocolInvalid, label)
            }
        }
    }

    /// The standard form is the plain CID: a standard CID carrying encryption
    /// info is not a header link. No honest producer encrypts one.
    func testAStandardLinkWithEncryptionInfoIsMalformed() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let block = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let info = EncryptionInfo(keyHash: "key", iv: "iv")
        let encrypted = Block(
            version: block.version,
            parent: block.parent,
            transactions: block.transactions,
            target: block.target,
            nextTarget: block.nextTarget,
            spec: block.spec,
            parentState: block.parentState,
            prevState: block.prevState,
            postState: LatticeStateHeader(rawCID: block.postState.rawCID, node: nil, encryptionInfo: info),
            children: block.children,
            height: block.height,
            timestamp: block.timestamp,
            rewardRecipient: block.rewardRecipient,
            nonce: block.nonce
        )
        XCTAssertTrue(CIDIdentity.isStandard(encrypted.postState.rawCID))
        XCTAssertNil(Block(data: try XCTUnwrap(encrypted.toData())))

        let index = FlatDictionary<BlockHeader>([
            "Child": BlockHeader(rawCID: testCID("child"), node: nil, encryptionInfo: info),
        ])
        XCTAssertFalse(index.isWellFormed)
    }

    func testAllStandardHeadersDecodeUnchanged() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let block = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        for honest in [genesis, block] {
            XCTAssertTrue(honest.hasStandardLinks)
            let data = try XCTUnwrap(honest.toData())
            XCTAssertEqual(try XCTUnwrap(Block(data: data)).toData(), data)
            let cid = try BlockHeader(node: honest).rawCID
            guard case .success(let resolved) = await BlockImport.resolveBlock(
                BlockHeader(rawCID: cid), fetcher: fetcher
            ) else { return XCTFail("an honest block resolves") }
            XCTAssertEqual(resolved.header.rawCID, cid)
        }
    }

    func testAChildIndexWithANonStandardChildIsRefusedAtHeaderAdmission() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let block = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let context = testChainContext()

        for shape in nonStandardShapes {
            var tree = try await TreeDriver.tree(genesis: genesis, context: context, fetcher: fetcher)
            let index = FlatDictionary<BlockHeader>(["Child": BlockHeader(rawCID: shape.cid)])
            let malformed = replacing(
                "children", of: block, with: try HeaderImpl(node: index).rawCID
            )
            XCTAssertNotNil(Block(data: try XCTUnwrap(malformed.toData())), "the block itself is standard")
            XCTAssertEqual(
                tree.insertRootHeader(malformed, childIndex: index).failure,
                .protocolInvalid,
                shape.name
            )
            XCTAssertFalse(tree.contains(blockHash: try BlockHeader(node: malformed).rawCID), shape.name)
        }
    }

    func testAChildProofThroughANonStandardChildIndexIsRefused() async throws {
        let fetcher = StorableFetcher()
        let carrierTemplate = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 500)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let child = try await AdmissionFixture.makeChild(
            of: childGenesis, fetcher: fetcher, timestamp: 2_000, nonce: 2,
            parentChainBlock: carrierTemplate
        )
        let childHeader = try BlockHeader(node: child)

        for shape in nonStandardShapes {
            let index = FlatDictionary<BlockHeader>([
                "Child": childHeader.removingNode(),
                "Other": BlockHeader(rawCID: shape.cid),
            ])
            let indexHeader = try HeaderImpl(node: index)
            fetcher.store(rawCid: indexHeader.rawCID, data: try XCTUnwrap(index.toData()))
            let carrier = replacing("children", of: carrierTemplate, with: indexHeader.rawCID)
            let carrierHeader = try BlockHeader(node: carrier)
            fetcher.store(rawCid: carrierHeader.rawCID, data: try XCTUnwrap(carrier.toData()))

            let proof = try await ChildBlockProof.generate(
                rootHeader: carrierHeader, childDirectory: "Child", fetcher: fetcher
            )
            guard case .failure(let failure) = await proof.verifySecuringWork(
                child: child, chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
            ) else {
                XCTFail("\(shape.name): verified")
                continue
            }
            XCTAssertEqual(failure, .protocolInvalid, shape.name)
        }
    }
}
