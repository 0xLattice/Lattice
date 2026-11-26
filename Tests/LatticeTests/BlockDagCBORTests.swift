import XCTest
import Foundation
import Crypto
import UInt256
import cashew
@testable import LatticePrimitives
@testable import LatticeProofs

/// `Block` reads and writes its own DAG-CBOR (cashew's `DagCBORCodable`).
/// It must give `Codable`'s answers: the same bytes, so the same CID, for
/// every block, and the same verdict and value for every input. Inputs are
/// the real testnet blocks and maps of the child-proof corpus, blocks outside
/// the usual shape, and every mutant of the child blocks, the shapes and the
/// maps.
final class BlockDagCBORTests: XCTestCase {

    func test_everyBlockIsWrittenAsCodableWritesIt() throws {
        for block in try corpusBlocks() + shapes(of: corpusBlocks()[0]) {
            XCTAssertEqual(try DagCBOR.encode(block), try DagCBOR.encodeThroughCodable(block))
        }
    }

    func test_everyInputGetsCodablesVerdictAndValue() throws {
        var compared = 0
        var accepted = 0
        func check<T: Codable>(_ type: T.Type, _ input: Data) {
            let own = try? DagCBOR.decode(type, from: input)
            let codable = try? DagCBOR.decodeThroughCodable(type, from: input)
            XCTAssertEqual(
                own.map { try? DagCBOR.encodeThroughCodable($0) },
                codable.map { try? DagCBOR.encodeThroughCodable($0) },
                "\(T.self): \(input.base64EncodedString())"
            )
            if own != nil { accepted += 1 }
            compared += 1
        }
        let children = try testnetChildProofs.map {
            try XCTUnwrap(Block(data: try XCTUnwrap(Data(base64Encoded: $0.block, options: .ignoreUnknownCharacters))))
        }
        for block in children + shapes(of: children[0]) {
            for input in mutants(of: try DagCBOR.encodeThroughCodable(block)) {
                check(Block.self, input)
            }
        }
        for map in try corpusEntries().filter({ FlatDictionary<BlockHeader>(data: $0) != nil }) {
            for input in mutants(of: map) {
                check(FlatDictionary<BlockHeader>.self, input)
            }
        }
        XCTAssertGreaterThan(compared, 50_000)
        XCTAssertGreaterThan(accepted, 30)
    }

    /// The other types written field by field: specs with and without
    /// policies, the corpus blocks' states, and targets.
    func test_specsStatesAndTargetsGetCodablesBytesVerdictsAndValues() throws {
        let policy = WasmPolicyRef(moduleCID: "bafy-module", sourceCID: "bafy-source", scope: .action)
        let specs = [
            ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: -1, premine: 0, targetBlockTime: 1_000,
                      initialReward: 50, halvingInterval: 210_000, halfLife: 120),
            ChainSpec(maxNumberOfTransactionsPerBlock: .max, maxStateGrowth: .max, maxBlockSize: 24, premine: .max,
                      targetBlockTime: 0, initialReward: .max, halvingInterval: 0, halfLife: .max,
                      wasmPolicies: [policy, WasmPolicyRef(moduleCID: "m", abiVersion: .max, scope: .transaction, entrypoint: "é")]),
        ]
        let states = try corpusBlocks().prefix(4).compactMap { block -> LatticeState? in
            LatticeState(
                accountState: AccountStateHeader(rawCID: block.prevState.rawCID),
                generalState: GeneralStateHeader(rawCID: block.postState.rawCID),
                depositState: DepositStateHeader(rawCID: block.parentState.rawCID),
                receiptState: ReceiptStateHeader(rawCID: block.spec.rawCID)
            )
        } + [LatticeState.empty]
        let targets: [UInt256] = [.zero, UInt256(1), UInt256.max, try corpusBlocks()[0].target]

        for spec in specs { XCTAssertEqual(try DagCBOR.encode(spec), try DagCBOR.encodeThroughCodable(spec)) }
        XCTAssertEqual(try DagCBOR.encode(policy), try DagCBOR.encodeThroughCodable(policy))
        for state in states { XCTAssertEqual(try DagCBOR.encode(state), try DagCBOR.encodeThroughCodable(state)) }
        for target in targets { XCTAssertEqual(try DagCBOR.encode(target), try DagCBOR.encodeThroughCodable(target)) }

        var compared = 0
        func check<T: Codable>(_ type: T.Type, _ value: T) throws {
            for input in mutants(of: try DagCBOR.encodeThroughCodable(value)) {
                let own = try? DagCBOR.decode(type, from: input)
                let codable = try? DagCBOR.decodeThroughCodable(type, from: input)
                XCTAssertEqual(
                    own.map { try? DagCBOR.encodeThroughCodable($0) },
                    codable.map { try? DagCBOR.encodeThroughCodable($0) },
                    "\(T.self): \(input.base64EncodedString())"
                )
                compared += 1
            }
        }
        for spec in specs { try check(ChainSpec.self, spec) }
        try check(WasmPolicyRef.self, policy)
        for state in states.prefix(2) { try check(LatticeState.self, state) }
        for target in targets { try check(UInt256.self, target) }
        XCTAssertGreaterThan(compared, 10_000)
    }

    // MARK: - Inputs

    /// Every child block and proof entry of the corpus.
    private func corpusEntries() throws -> [Data] {
        try testnetChildProofs.flatMap { record -> [Data] in
            let block = try XCTUnwrap(Data(base64Encoded: record.block, options: .ignoreUnknownCharacters))
            let proofBytes = try XCTUnwrap(Data(base64Encoded: record.proof, options: .ignoreUnknownCharacters))
            let proof = try XCTUnwrap(ChildBlockProof.deserialize(proofBytes))
            return [block] + proof.entries.map(\.data)
        }
    }

    private func corpusBlocks() throws -> [Block] {
        let blocks = try corpusEntries().compactMap { Block(data: $0) }
        XCTAssertGreaterThan(blocks.count, 12)
        return blocks
    }

    /// `block` outside the usual shape: optional fields absent, extreme
    /// integers, non-ASCII text, and links decoding refuses.
    private func shapes(of block: Block) -> [Block] {
        func with(
            parent: VolumeImpl<Block>?? = nil,
            transactions: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>? = nil,
            target: UInt256? = nil,
            spec: VolumeImpl<ChainSpec>? = nil,
            height: UInt64? = nil,
            timestamp: Int64? = nil,
            rewardRecipient: String?? = nil,
            version: UInt16? = nil
        ) -> Block {
            Block(
                version: version ?? block.version,
                parent: parent ?? block.parent,
                transactions: transactions ?? block.transactions,
                target: target ?? block.target,
                nextTarget: block.nextTarget,
                spec: spec ?? block.spec,
                parentState: block.parentState,
                prevState: block.prevState,
                postState: block.postState,
                children: block.children,
                height: height ?? block.height,
                timestamp: timestamp ?? block.timestamp,
                rewardRecipient: rewardRecipient ?? block.rewardRecipient,
                nonce: block.nonce
            )
        }
        let rawCodec = CIDIdentity.base32Multibase([0x01, 0x55, 0x12, 0x20] + Array(SHA256.hash(data: Data("spec".utf8))))
        return [
            with(parent: .some(nil)),
            with(rewardRecipient: .some(nil)),
            with(rewardRecipient: "café"),
            with(timestamp: -1),
            with(timestamp: .min),
            with(height: .max),
            with(target: .zero),
            with(version: .max),
            with(spec: VolumeImpl(rawCID: rawCodec)),
            with(transactions: HeaderImpl(
                rawCID: block.transactions.rawCID, node: nil,
                encryptionInfo: EncryptionInfo(keyHash: "k", iv: "iv")
            )),
        ]
    }

    /// Every byte deleted, replaced or preceded by another; every prefix;
    /// every head widened; trailing bytes.
    private func mutants(of data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var out: [Data] = [data, data + [0x00]]
        for index in bytes.indices {
            var deleted = bytes
            deleted.remove(at: index)
            out.append(Data(deleted))
            out.append(Data(bytes[..<index]))
            for replacement in [bytes[index] ^ 0x01, bytes[index] ^ 0x20, bytes[index] ^ 0x80, 0x00, 0xf6, 0xff] {
                var replaced = bytes
                replaced[index] = replacement
                out.append(Data(replaced))
            }
            for inserted in [0x00, 0x60, 0xa0, 0xf6] as [UInt8] {
                var grown = bytes
                grown.insert(inserted, at: index)
                out.append(Data(grown))
            }
            if let widened = widened(bytes, at: index) {
                out.append(Data(widened))
            }
        }
        return out
    }

    /// `bytes` with the byte at `index`, read as a head of major 0–5, written
    /// one width wider: the same value, not in its shortest form.
    private func widened(_ bytes: [UInt8], at index: Int) -> [UInt8]? {
        let initial = bytes[index]
        let major = initial >> 5
        let additional = initial & 0x1f
        guard major <= 5, additional <= 26 else { return nil }
        let width = additional < 24 ? 0 : 1 << Int(additional - 24)
        guard index + width < bytes.count else { return nil }
        var value: UInt64 = additional < 24 ? UInt64(additional) : 0
        for offset in stride(from: 1, through: width, by: 1) {
            value = value << 8 | UInt64(bytes[index + offset])
        }
        let wider = additional < 24 ? 1 : width * 2
        var head: [UInt8] = [major << 5 | UInt8(24 + wider.trailingZeroBitCount)]
        for shift in stride(from: (wider - 1) * 8, through: 0, by: -8) {
            head.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
        return Array(bytes[..<index]) + head + Array(bytes[(index + 1 + width)...])
    }
}
