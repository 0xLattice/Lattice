import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import cashew

/// A block's children are one flat DAG-CBOR map: its bytes are canonical, a
/// proof of one child carries the whole map and nothing else, and the block
/// reads it with a single fetch.
final class BlockChildrenTests: XCTestCase {

    private func spec() -> ChainSpec {
        ChainSpec.test(halfLife: 10)
    }

    func testEncodingIsCanonicalAndRoundTrips() throws {
        let a = try BlockHeader(node: makeGenesisBlock(spec: spec(), nonce: 1))
        let b = try BlockHeader(node: makeGenesisBlock(spec: spec(), nonce: 2))
        var forward = FlatDictionary<BlockHeader>()
        forward.entries["Payments"] = a
        forward.entries["Games"] = b
        var reversed = FlatDictionary<BlockHeader>()
        reversed.entries["Games"] = b
        reversed.entries["Payments"] = a
        let forwardData = try XCTUnwrap(forward.toData())
        XCTAssertEqual(forwardData, reversed.toData(), "insertion order does not reach the bytes")
        let decoded = try XCTUnwrap(FlatDictionary<BlockHeader>(data: forwardData))
        XCTAssertEqual(decoded.entries.mapValues(\.rawCID), forward.entries.mapValues(\.rawCID))
        XCTAssertEqual(decoded["Games"]?.rawCID, b.rawCID)
        XCTAssertEqual(
            try HeaderImpl(node: forward).rawCID,
            try HeaderImpl(node: reversed).rawCID
        )
    }

    /// Every builder path names children through `buildChildren`, which
    /// admits only directory atoms.
    func testBuilderRefusesNonDirectoryNames() async throws {
        let child = makeGenesisBlock(spec: spec(), nonce: 1)
        for name in ["", "Pay/ments", "bad key", "Zahlung\u{FC}"] {
            XCTAssertThrowsError(try BlockBuilder.buildChildren([name: child]), name)
        }
        XCTAssertNoThrow(try BlockBuilder.buildChildren(["Payments": child]))
        do {
            _ = try await BlockBuilder.buildGenesis(
                spec: spec(), children: ["Pay/ments": child],
                timestamp: 1_000, target: .max, fetcher: StorableFetcher()
            )
            XCTFail("a genesis carrying a non-directory name was built")
        } catch BlockBuilderError.invalidChildDirectory(let name) {
            XCTAssertEqual(name, "Pay/ments")
        }
    }

    /// No CID names a children map longer than the decoder reads: the
    /// encoder refuses it.
    func testChildrenBeyondTheDecoderLimitCannotBeBuilt() throws {
        let a = try BlockHeader(node: makeGenesisBlock(spec: spec(), nonce: 1))
        var tooMany: [String: BlockHeader] = [:]
        for index in 0...Int(DagCBOR.maxCollectionCount) { tooMany["d\(index)"] = a }
        XCTAssertThrowsError(try HeaderImpl(node: FlatDictionary(tooMany)))
        tooMany.removeValue(forKey: "d0")
        XCTAssertNoThrow(try HeaderImpl(node: FlatDictionary(tooMany)))
    }

    /// A proof of one child is the root block, the index, and the child: three
    /// entries, however many siblings the index holds.
    func testSingleHopProofCarriesTheWholeIndexAndNothingElse() async throws {
        let fetcher = StorableFetcher()
        let s = spec()
        let parentGenesis = try await buildAndStoreGenesis(
            spec: s, timestamp: 1_000, target: UInt256.max, fetcher: fetcher
        )
        var children: [String: Block] = [:]
        for (index, directory) in ["Alpha", "Beta", "Gamma"].enumerated() {
            let child = makeGenesisBlock(spec: s, nonce: UInt64(index + 1))
            try await VolumeImpl<Block>(node: child).storeBlock(storer: fetcher)
            children[directory] = child
        }
        let carrier = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: children,
            timestamp: 2_000,
            fetcher: fetcher
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Beta",
            fetcher: fetcher
        )
        XCTAssertEqual(proof.entries.count, 3, "root block, children, child block")
        XCTAssertEqual(
            Set(proof.entries.map(\.cid)),
            [carrierHeader.rawCID, carrier.children.rawCID, try BlockHeader(node: children["Beta"]!).rawCID]
        )
        let hopValue = await proof.directHop()
        let hop = try XCTUnwrap(hopValue)
        XCTAssertEqual(hop.childCID, try BlockHeader(node: children["Beta"]!).rawCID)
        // The index names every sibling, so a block read from bytes learns all
        // of its commitments from the same node the proof carried.
        let fromBytes = try await BlockHeader(rawCID: carrierHeader.rawCID).resolve(
            paths: [[CHILDREN_PROPERTY]: .targeted], fetcher: fetcher
        )
        let map = try XCTUnwrap(fromBytes.node?.children.node?.entries.mapValues(\.rawCID))
        XCTAssertEqual(Set(map.keys), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(map["Gamma"], try BlockHeader(node: children["Gamma"]!).rawCID)
    }

    /// A block read from bytes fetches its index with one request and only when
    /// it is asked for; the child blocks stay independent volumes.
    func testResolvingTheIndexFetchesOneNodeAndNoChildBlocks() async throws {
        let fetcher = StorableFetcher()
        let s = spec()
        let parentGenesis = try await buildAndStoreGenesis(
            spec: s, timestamp: 1_000, target: UInt256.max, fetcher: fetcher
        )
        let child = makeGenesisBlock(spec: s, nonce: 7)
        let carrier = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: ["Solo": child],
            timestamp: 2_000,
            fetcher: fetcher
        )
        let counting = CountingFetcher(backing: fetcher)
        let header = BlockHeader(rawCID: try BlockHeader(node: carrier).rawCID)
        let resolved = try await header.resolve(
            paths: [[CHILDREN_PROPERTY]: .targeted], fetcher: counting
        )
        let index = try XCTUnwrap(resolved.node?.children.node)
        XCTAssertEqual(index.count, 1)
        XCTAssertNil(index["Solo"]?.node, "the child block is not fetched")
        let fetches = await counting.count()
        XCTAssertEqual(fetches, 2, "the block and its index")
    }

    /// Absence is decided by the same node: a proof for a directory the
    /// carrier does not name proves no child.
    func testAbsentDirectoryProvesNoChild() async throws {
        let fetcher = StorableFetcher()
        let s = spec()
        let child = try await buildAndStoreGenesis(
            spec: s, timestamp: 500, target: .max, fetcher: fetcher
        )
        let root = try await buildAndStoreGenesis(
            spec: s, children: ["Beta": child], timestamp: 1_000, target: .max, fetcher: fetcher
        )
        let rootHeader = try BlockHeader(node: root)
        let present = try await ChildBlockProof.generate(
            rootHeader: rootHeader, childDirectory: "Beta", fetcher: fetcher
        )
        guard case .success = await present.verifySecuringWork(child: child, chainPath: ["Nexus", "Beta"]) else {
            return XCTFail("a carried child verifies")
        }
        // The proof carries the whole map, so the same node shows what the
        // carrier does not name.
        let sealed = InMemoryContentSource(Dictionary(uniqueKeysWithValues: present.entries.map { ($0.cid, $0.data) }))
        let carried = try await BlockHeader(rawCID: rootHeader.rawCID).resolve(
            paths: [[CHILDREN_PROPERTY]: .targeted], fetcher: sealed
        )
        let children = try XCTUnwrap(carried.node?.children.node)
        XCTAssertNotNil(children["Beta"])
        XCTAssertNil(children["Delta"])
        let absent = try await ChildBlockProof.generate(
            rootHeader: rootHeader, childDirectory: "Delta", fetcher: fetcher
        )
        XCTAssertEqual(absent.entries.count, 2, "root block and children: no child")
        guard case .failure(.malformedEvidence) = await absent.verifySecuringWork(child: child, chainPath: ["Nexus", "Delta"]) else {
            return XCTFail("an absent directory proves no child")
        }
        let relabeled = ChildBlockProof(rootCID: present.rootCID, directoryPath: ["Delta"], entries: present.entries)
        guard case .failure(.malformedEvidence) = await relabeled.verifySecuringWork(child: child, chainPath: ["Nexus", "Delta"]) else {
            return XCTFail("a present child's proof does not prove it under another directory")
        }
    }

    // MARK: - Received blocks

    /// Names a block may not carry a child under: each passes canonical
    /// decode, and the Kelvin sign is Swift-equal to "K".
    private static let invalidDirectories = [
        "\u{212A}", "", "Pay/ments", "Zahlung\u{FC}",
        String(repeating: "a", count: ChildProofWireLimits.maximumDirectoryBytes + 1),
    ]

    /// `block` carrying `children` instead of its own: a block a peer could mine.
    private func carrying(_ children: [String: BlockHeader], _ block: Block) throws -> (Block, FlatDictionary<BlockHeader>) {
        let map = FlatDictionary(children)
        return (Block(
            version: block.version, parent: block.parent, transactions: block.transactions,
            target: block.target, nextTarget: block.nextTarget, spec: block.spec,
            parentState: block.parentState, prevState: block.prevState, postState: block.postState,
            children: try HeaderImpl(node: map), height: block.height, timestamp: block.timestamp,
            rewardRecipient: block.rewardRecipient, nonce: block.nonce
        ), map)
    }

    func testReceivedBlockWithAnInvalidDirectoryIsDropped() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let tree = try await TreeDriver.tree(genesis: genesis, context: testChainContext(genesis: genesis), fetcher: fetcher)
        let base = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let someChild = try BlockHeader(node: genesis)

        // Each insertion runs on its own tree: `tree` stays held for the next.
        var control = tree.detached()
        let (valid, validMap) = try carrying(["K": someChild], base)
        XCTAssertNotNil(control.insertRootHeader(valid, childIndex: validMap).update, "a valid directory weighs")

        for name in Self.invalidDirectories {
            var header = tree.detached()
            let (block, map) = try carrying([name: someChild], base)
            XCTAssertEqual(header.insertRootHeader(block, childIndex: map).failure, .protocolInvalid, name.prefix(16).description)

            let (forgedGenesis, genesisMap) = try carrying([name: someChild], genesis)
            var root = ChainTree.empty(context: testChainContext(genesis: forgedGenesis))
            XCTAssertEqual(
                root.insertGenesis(forgedGenesis, spec: chainLocalSpec(), childIndex: genesisMap).failure,
                .protocolInvalid, name.prefix(16).description
            )

            try await BlockHeader(node: block).storeBlock(storer: fetcher)
            let commitments = await BlockImport.childCommitments(of: try BlockHeader(node: block), fetcher: fetcher)
            guard case .failure(.protocolInvalid) = commitments else {
                return XCTFail("child commitments of \(name.prefix(16)) are read")
            }
        }
    }

    /// A proof that steps through a carrier naming an invalid directory proves
    /// nothing, even when Swift reads the name as a valid one ("K").
    func testProofThroughAnInvalidDirectoryIsRejected() async throws {
        let fetcher = StorableFetcher()
        let s = spec()
        let child = try await buildAndStoreGenesis(spec: s, timestamp: 500, target: .max, fetcher: fetcher)
        let childHeader = try BlockHeader(node: child)
        let built = try await buildAndStoreGenesis(spec: s, timestamp: 1_000, target: .max, fetcher: fetcher)
        let (root, _) = try carrying(["\u{212A}": childHeader], built)
        let rootHeader = try BlockHeader(node: root)
        try await rootHeader.storeBlock(storer: fetcher)
        let proof = try await ChildBlockProof.generate(rootHeader: rootHeader, childDirectory: "K", fetcher: fetcher)
        guard case .failure(.protocolInvalid) = await proof.verifySecuringWork(child: child, chainPath: ["Nexus", "K"]) else {
            return XCTFail("a proof through an invalid directory verifies")
        }
        let hop = await proof.directHop()
        XCTAssertNil(hop)
    }
}
