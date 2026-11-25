import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import cashew
import UInt256

@MainActor
final class BlockVersionPoWTests: XCTestCase {
    private func spec(_ directory: String = "Nexus") -> ChainSpec {
        ChainSpec.test()
    }

    private func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func genesis(
        version: UInt16 = Block.currentVersion,
        directory: String = "Nexus",
        timestamp: Int64? = nil,
        fetcher: StorableFetcher = StorableFetcher()
    ) async throws -> Block {
        try await buildAndStoreGenesis(
            spec: spec(directory),
            timestamp: timestamp ?? now() - 20_000,
            target: UInt256(1000),
            version: version,
            fetcher: fetcher
        )
    }

    private func copy(
        _ block: Block,
        version: UInt16? = nil,
        spec: VolumeImpl<ChainSpec>? = nil,
        nonce: UInt64? = nil
    ) -> Block {
        Block(
            version: version ?? block.version,
            parent: block.parent,
            transactions: block.transactions,
            target: block.target,
            nextTarget: block.nextTarget,
            spec: spec ?? block.spec,
            parentState: block.parentState,
            prevState: block.prevState,
            postState: block.postState,
            children: block.children,
            height: block.height,
            timestamp: block.timestamp,
            rewardRecipient: block.rewardRecipient,
            nonce: nonce ?? block.nonce
        )
    }

    func test_proofOfWorkHash_commitsVersion() async throws {
        let block = try await genesis()
        let forgedVersion = copy(block, version: Block.currentVersion + 1)

        XCTAssertNotEqual(
            block.proofOfWorkHash(),
            forgedVersion.proofOfWorkHash(),
            "PoW hash must commit to the block version"
        )
    }

    func test_unexpectedVersion_rejected() async throws {
        let fetcher = StorableFetcher()
        let badGenesis = try await genesis(version: Block.currentVersion + 1, fetcher: fetcher)

        let genesisResult = try await badGenesis.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        XCTAssertFalse(genesisResult.0, "genesis validation must reject unsupported block versions")

        let nexusResult = try await badGenesis.validateNexus(fetcher: fetcher)
        XCTAssertFalse(nexusResult.0, "nexus validation must reject unsupported block versions")
    }

    func test_hashable_distinguishesContent() async throws {
        let block = try await genesis()
        // ChainSpec no longer carries a directory; differ on a real content field
        // (premine) so the spec CID changes and the Hashable check stays meaningful.
        let differentContentSpec = ChainSpec.test(premine: 999)
        let otherSpec = try! VolumeImpl<ChainSpec>(node: differentContentSpec)
        let sameScalarsDifferentContent = copy(block, spec: otherSpec)

        XCTAssertNotEqual(block, sameScalarsDifferentContent)
        XCTAssertNotEqual(
            block.hashValue,
            sameScalarsDifferentContent.hashValue,
            "Hashable must include canonical serialized content, not only scalar header fields"
        )
    }

    func test_equality_matchesContentAndHash() async throws {
        let block = try await genesis()
        guard let data = block.toData(), let restored = Block(data: data) else {
            return XCTFail("block serialization round trip failed")
        }

        XCTAssertEqual(block, restored)
        XCTAssertFalse(block != restored, "equal-content blocks must never compare unequal")
        XCTAssertEqual(block.hashValue, restored.hashValue)

        let changedVersion = copy(block, version: Block.currentVersion + 1)
        XCTAssertNotEqual(block, changedVersion)
        XCTAssertNotEqual(block.hashValue, changedVersion.hashValue)
    }

    private func deterministicGenesis(version: UInt16 = Block.currentVersion) async throws -> Block {
        try await buildAndStoreGenesis(
            spec: spec("Nexus"),
            timestamp: 1_000_000_000_000,
            target: UInt256.max,
            nonce: 0,
            version: version,
            fetcher: StorableFetcher()
        )
    }

    func test_makeProofOfWorkPreimage_goldenBytes() async throws {
        let block = try await deterministicGenesis()
        let preimage = Block.makeProofOfWorkPreimage(block: block, nonce: 0)
        let digest = UInt256.hash(preimage).toHexString()
        let goldenDigest = "7338ebe21969647356e63731a9b4ea5f48654aa655ebbc671189590e23fa7b8c"

        XCTAssertEqual(
            digest,
            goldenDigest,
            "canonical PoW preimage bytes changed — any field addition/removal/reordering breaks this. If intentional, update the golden value (consensus-breaking)."
        )
    }

    func test_preimagePrefix_plusNonce_equalsFullPreimage() async throws {
        let block = try await deterministicGenesis()
        let prefix = Block.makeProofOfWorkPreimagePrefix(block: block)

        for nonce: UInt64 in [0, 1, 42, 1_000_000, UInt64.max] {
            var reconstructed = prefix
            reconstructed.append(contentsOf: Block.proofOfWorkNonceBytes(nonce))
            XCTAssertEqual(
                reconstructed,
                Block.makeProofOfWorkPreimage(block: block, nonce: nonce),
                "prefix + nonce must reproduce the canonical preimage byte-for-byte (nonce=\(nonce))"
            )
        }
    }

    func test_preimagePrefix_isFullPreimageMinusNonceSuffix() async throws {
        let block = try await deterministicGenesis()
        let prefix = Block.makeProofOfWorkPreimagePrefix(block: block)
        let full = Block.makeProofOfWorkPreimage(block: block, nonce: 0)

        // nonce 0 appends exactly 8 big-endian zero bytes; the prefix is everything before them.
        XCTAssertEqual(prefix, full.dropLast(8), "prefix must be the canonical preimage minus the nonce suffix")
        XCTAssertTrue(full.starts(with: prefix), "full preimage must begin with the prefix")
    }

    func test_midstateHash_equalsConsensusHash() async throws {
        let block = try await deterministicGenesis()
        let midstate = ProofOfWorkMidstate(block: block)
        let fromPrefix = ProofOfWorkMidstate(prefix: Block.makeProofOfWorkPreimagePrefix(block: block))

        for nonce: UInt64 in [0, 1, 42, 1_000_000, UInt64.max] {
            let consensus = copy(block, nonce: nonce).proofOfWorkHash()
            XCTAssertEqual(midstate.hash(nonce: nonce), consensus, "nonce=\(nonce)")
            XCTAssertEqual(fromPrefix.hash(nonce: nonce), consensus, "nonce=\(nonce)")
        }
        XCTAssertEqual(
            midstate.hash(nonce: 0).toHexString(),
            "7338ebe21969647356e63731a9b4ea5f48654aa655ebbc671189590e23fa7b8c"
        )
    }

    func test_midstateHash_commitsRewardRecipient() async throws {
        let block = try await deterministicGenesis()
        let paid = Block(
            version: block.version, parent: block.parent, transactions: block.transactions,
            target: block.target, nextTarget: block.nextTarget, spec: block.spec,
            parentState: block.parentState, prevState: block.prevState, postState: block.postState,
            children: block.children, height: block.height, timestamp: block.timestamp,
            rewardRecipient: "recipient", nonce: 7
        )
        XCTAssertEqual(ProofOfWorkMidstate(block: paid).hash(nonce: 7), paid.proofOfWorkHash())
        XCTAssertNotEqual(ProofOfWorkMidstate(block: paid).hash(nonce: 7), ProofOfWorkMidstate(block: block).hash(nonce: 7))
    }

    func test_makeProofOfWorkPreimage_containsVersionBytes() async throws {
        let block = try await deterministicGenesis(version: 1)
        let forged = copy(block, version: 7)

        let preimage = Block.makeProofOfWorkPreimage(block: block, nonce: 0)
        let forgedPreimage = Block.makeProofOfWorkPreimage(block: forged, nonce: 0)

        XCTAssertNotEqual(
            preimage,
            forgedPreimage,
            "preimage must commit to the version field (the field the node copy omitted, per #135)"
        )
        XCTAssertTrue(
            preimage.starts(with: Array(String(block.version).utf8)),
            "preimage must begin with the version bytes"
        )
    }

    func test_mine_preservesVersionedPreimage() async throws {
        let block = try await genesis(version: Block.currentVersion + 1)
        guard let mined = BlockBuilder.mine(block: block, target: UInt256.max, maxAttempts: 1) else {
            return XCTFail("max target should accept the first nonce")
        }

        XCTAssertEqual(mined.version, block.version)
        XCTAssertEqual(mined.nonce, 0)
        XCTAssertEqual(
            mined.proofOfWorkHash(),
            UInt256.hash(Block.makeProofOfWorkPreimage(block: block, nonce: 0))
        )
    }
}
