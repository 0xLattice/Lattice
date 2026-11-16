import XCTest
import Foundation
import Crypto
import UInt256
import cashew
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

/// `verifySecuringWork` walks the proof's own entries synchronously. Before
/// that it resolved the same entries through cashew's async targeted resolve
/// over an actor-tracked in-memory fetcher (Lattice 56.2.0). The two must
/// return the same verdict for every input: accept or reject, the failure
/// class, and on acceptance every field of the evidence (grind, root hash,
/// credited ancestor work, child, terminal carrier, contribution).
///
/// One deliberate exception: a directory spelled differently from the
/// runtime path or a map key that it equals only under Unicode canonical
/// equivalence (KELVIN SIGN for "K"). The old walk compared the proof's path
/// to the runtime path with `String ==` and followed such a key or not by an
/// accident of cashew's path trie (whether the first scalars of the two
/// spellings share a 5-bit hash bucket), so a peer's respelled proof path
/// could verify, even with no terminal entry. The proof path is now compared
/// byte for byte and a key is followed only under the directory's exact bytes:
/// a respelled proof path is rejected, and a map key respelled after its first
/// character, already not well-formed, is blamed `protocolInvalid` where it
/// could be `malformedEvidence`. Those cases assert the walk's verdict
/// (`unicodeVerdict`) and list where it differs.
///
/// The old verifier is kept below, verbatim, as the oracle. Inputs are real
/// testnet proofs and built proofs at depths 1–3 (unmined, mined across credit
/// ladders, a target miss, sibling children), and systematic mutants of each.
final class ChildBlockProofDifferentialTests: XCTestCase {

    func test_syncWalkMatchesResolveWalkOnEveryCorpusProofAndMutant() async throws {
        var fixtures = try testnetChildProofs.map(testnetFixture)
        for depth in 1...3 {
            fixtures.append(try await ladder(
                name: "unmined-d\(depth)",
                targets: Array(repeating: .max, count: depth + 1),
                miningTarget: nil
            ))
            fixtures.append(try await ladder(
                name: "siblings-d\(depth)",
                targets: Array(repeating: .max, count: depth + 1),
                miningTarget: nil,
                siblings: true
            ))
        }
        // Directories with a character that has a Unicode-equivalent spelling
        // (KELVIN SIGN for "K"), first and later in the name.
        fixtures.append(try await ladder(
            name: "kelvin-first-d2", targets: [.max, .max, .max], miningTarget: nil, prefix: "K"))
        fixtures.append(try await ladder(
            name: "kelvin-later-d2", targets: [.max, .max, .max], miningTarget: nil, prefix: "xK"))
        let easy = UInt256.max >> 4
        let mid = UInt256.max >> 8
        let hard = UInt256.max >> 40
        // Root-first targets. The grind beats `mid`: the credited target is
        // the root-most carrier it beats, or the child's own.
        fixtures.append(try await ladder(
            name: "mined-root-credited-d1", targets: [mid, easy], miningTarget: mid))
        fixtures.append(try await ladder(
            name: "mined-child-credited-d1", targets: [hard, mid], miningTarget: mid))
        fixtures.append(try await ladder(
            name: "mined-middle-credited-d2", targets: [hard, easy, mid], miningTarget: mid))
        fixtures.append(try await ladder(
            name: "mined-inverted-d3", targets: [hard, easy, hard, mid], miningTarget: mid))
        fixtures.append(try await ladder(
            name: "mined-target-miss-d2", targets: [easy, easy, hard], miningTarget: mid))

        var compared = 0
        var accepted = 0
        var outcomes: [String: Int] = [:]
        var differences: [String] = []
        for fixture in fixtures {
            let cases = mutants(of: fixture, others: fixtures.filter { $0.name != fixture.name })
            for c in cases {
                let old = Verdict(await Legacy.verifySecuringWork(
                    c.proof, child: c.child, chainPath: c.chainPath
                ))
                let new = Verdict(c.proof.verifySecuringWork(
                    child: c.child, chainPath: c.chainPath
                ))
                if let expected = c.unicodeVerdict {
                    XCTAssertEqual(new, expected, "\(fixture.name) / \(c.name)")
                    if new != old {
                        differences.append("\(fixture.name) / \(c.name): \(old) -> \(new)")
                    }
                } else {
                    XCTAssertEqual(new, old, "\(fixture.name) / \(c.name)")
                }
                compared += 1
                if case .accepted = old { accepted += 1 }
                outcomes[old.label, default: 0] += 1
            }
        }
        print("ChildBlockProofDifferential: \(compared) cases, \(accepted) accepted, outcomes \(outcomes.sorted { $0.key < $1.key })")
        print("ChildBlockProofDifferential: \(differences.count) Unicode-spelling differences:\n" + differences.joined(separator: "\n"))
        // Every verdict class must be exercised, or the comparison proves little.
        XCTAssertGreaterThan(outcomes["accepted+contribution", default: 0], 0)
        XCTAssertGreaterThan(outcomes["accepted-nocontribution", default: 0], 0)
        XCTAssertGreaterThan(outcomes["malformedEvidence", default: 0], 0)
        XCTAssertGreaterThan(outcomes["protocolInvalid", default: 0], 0)
    }

    // MARK: - Corpus

    private struct Fixture {
        let name: String
        /// Root first, terminal child last.
        let blocks: [Block]
        let directories: [String]
        let proof: ChildBlockProof
        var child: Block { blocks[blocks.count - 1] }
        var chainPath: [String] { [DEFAULT_ROOT_DIRECTORY] + directories }
    }

    /// A real proof, with the block at each level read from its own entries.
    private func testnetFixture(
        _ record: (chain: String, block: String, proof: String)
    ) throws -> Fixture {
        func bytes(_ base64: String) throws -> Data {
            try XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        }
        let child = try XCTUnwrap(Block(data: try bytes(record.block)))
        let proof = try XCTUnwrap(ChildBlockProof.deserialize(try bytes(record.proof)))
        let entries = Dictionary(uniqueKeysWithValues: proof.entries.map { ($0.cid, $0.data) })
        var blocks = [try XCTUnwrap(entries[proof.rootCID].flatMap { Block(data: $0) })]
        for directory in proof.directoryPath {
            let map = try XCTUnwrap(entries[blocks[blocks.count - 1].children.rawCID]
                .flatMap { FlatDictionary<BlockHeader>(data: $0) })
            blocks.append(try XCTUnwrap(map[directory]
                .flatMap { entries[$0.rawCID] }
                .flatMap { Block(data: $0) }))
        }
        XCTAssertEqual(blocks[blocks.count - 1], child, record.chain)
        XCTAssertEqual([DEFAULT_ROOT_DIRECTORY] + proof.directoryPath,
                       record.chain.split(separator: "/").map(String.init))
        return Fixture(
            name: "testnet \(record.chain)",
            blocks: blocks,
            directories: proof.directoryPath,
            proof: proof
        )
    }

    /// `root → L0 → … → terminal`, built bottom-up and proven the way nodes
    /// prove it: one generated hop per level, composed.
    private func ladder(
        name: String,
        targets: [UInt256],
        miningTarget: UInt256?,
        siblings: Bool = false,
        prefix: String = "L"
    ) async throws -> Fixture {
        let fetcher = StorableFetcher()
        let spec = ChainSpec.test()
        let depth = targets.count - 1
        let directories = (0..<depth).map { "\(prefix)\($0)" }
        var below = try await buildAndStoreGenesis(
            spec: spec, timestamp: 1_000, target: targets[depth], nonce: 1, fetcher: fetcher
        )
        var blocks = [below]
        for level in stride(from: depth - 1, through: 0, by: -1) {
            var children = [directories[level]: below]
            if siblings {
                children["Sib\(level)"] = try await buildAndStoreGenesis(
                    spec: spec, timestamp: Int64(500 + level), target: .max,
                    nonce: UInt64(100 + level), fetcher: fetcher
                )
            }
            below = try await buildAndStoreGenesis(
                spec: spec, children: children, timestamp: Int64(2_000 + level * 1_000),
                target: targets[level], nonce: UInt64(10 + level), fetcher: fetcher
            )
            blocks.insert(below, at: 0)
        }
        if let miningTarget {
            let mined = try XCTUnwrap(
                BlockBuilder.mine(block: blocks[0], target: miningTarget, maxAttempts: 2_000_000)
            )
            blocks[0] = try await storeBuiltBlock(mined, in: fetcher)
        }
        var proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: blocks[0]),
            childDirectory: directories[0],
            fetcher: fetcher
        )
        for level in 1..<depth {
            proof = proof.composing(hop: try await ChildBlockProof.generate(
                rootHeader: try BlockHeader(node: blocks[level]),
                childDirectory: directories[level],
                fetcher: fetcher
            ))
        }
        return Fixture(name: name, blocks: blocks, directories: directories, proof: proof)
    }

    // MARK: - Mutants

    private struct Case {
        let name: String
        let proof: ChildBlockProof
        let child: Block
        let chainPath: [String]
        /// The walk's verdict for a Unicode-respelled directory, which may
        /// differ from the old walk's (see the type's documentation).
        var unicodeVerdict: Verdict? = nil
    }

    private func mutants(of fixture: Fixture, others: [Fixture]) -> [Case] {
        let base = fixture.proof
        let entries = Dictionary(uniqueKeysWithValues: base.entries.map { ($0.cid, $0.data) })
        var cases: [Case] = []
        func add(
            _ name: String,
            root: String? = nil,
            path: [String]? = nil,
            entries list: [(cid: String, data: Data)]? = nil,
            child: Block? = nil,
            chainPath: [String]? = nil,
            unicodeVerdict: Verdict? = nil
        ) {
            cases.append(Case(
                name: name,
                proof: ChildBlockProof(
                    rootCID: root ?? base.rootCID,
                    directoryPath: path ?? base.directoryPath,
                    entries: list ?? base.entries
                ),
                child: child ?? fixture.child,
                chainPath: chainPath ?? fixture.chainPath,
                unicodeVerdict: unicodeVerdict
            ))
        }
        func addRelinked(_ name: String, replacing cid: String, with data: Data, child: Block? = nil) {
            let (root, list) = relinked(entries, root: base.rootCID, replacing: cid, with: data)
            add(name, root: root, entries: list.map { ($0.key, $0.value) }, child: child)
        }

        add("honest")

        // Entry-level mutants: every entry, by CID.
        for (cid, data) in entries {
            let tag = label(cid, in: fixture, entries: entries)
            add("drop \(tag)", entries: base.entries.filter { $0.cid != cid })
            add("duplicate \(tag)", entries: base.entries + [(cid, data)])
            for position in Set([0, data.count / 2, data.count - 1]) {
                var flipped = data
                flipped[flipped.startIndex + position] ^= 0x01
                add("flip \(tag)@\(position) in place",
                    entries: base.entries.map { $0.cid == cid ? (cid, flipped) : $0 })
                addRelinked("flip \(tag)@\(position) relinked", replacing: cid, with: flipped)
            }
            let nonMinimal = nonMinimalHead(data)
            add("non-minimal head \(tag) in place",
                entries: base.entries.map { $0.cid == cid ? (cid, nonMinimal) : $0 })
            addRelinked("non-minimal head \(tag) relinked", replacing: cid, with: nonMinimal)
            addRelinked("trailing byte \(tag) relinked", replacing: cid, with: data + Data([0]))
            for (index, link) in standardLinks(in: data).enumerated() {
                let respelled = replacingAll(
                    in: data, Data(link.utf8),
                    with: Data(("B" + link.dropFirst().uppercased()).utf8)
                )
                addRelinked("respelled link \(index) in \(tag)", replacing: cid, with: respelled)
            }
            if cid != base.rootCID {
                add("root swapped to \(tag)", root: cid)
            }
        }

        // Typed mutants per level: the block at each level, and each carrier's map.
        let other = LatticeStateHeader(rawCID: CIDIdentity.standardCID(of: Data("other state".utf8)))
        for (level, block) in fixture.blocks.enumerated() {
            let cid = try! BlockHeader(node: block).rawCID
            let isTerminal = level == fixture.blocks.count - 1
            func replaced(_ name: String, _ changed: Block) {
                addRelinked("\(name) at level \(level)", replacing: cid, with: changed.toData()!,
                            child: isTerminal ? changed : nil)
            }
            replaced("parentState", rebuilt(block, parentState: other))
            replaced("prevState", rebuilt(block, prevState: other))
            replaced("malformed recipient", rebuilt(block, rewardRecipient: "not-an-address"))
            replaced("nonce", rebuilt(block, nonce: block.nonce &+ 1))
            addRelinked("undecodable at level \(level)", replacing: cid, with: Data([0xa0]))
            addRelinked("not a block at level \(level)", replacing: cid,
                        with: FlatDictionary<BlockHeader>().toData()!)
            if isTerminal { continue }

            let directory = fixture.directories[level]
            let mapCID = block.children.rawCID
            guard let mapData = entries[mapCID],
                  let map = FlatDictionary<BlockHeader>(data: mapData),
                  let link = map[directory] else {
                XCTFail("\(fixture.name): fixture map at level \(level) is unreadable")
                continue
            }
            func remapped(
                _ name: String,
                _ changed: [String: BlockHeader],
                extra: [String: Data] = [:],
                dropping: String? = nil,
                unicodeVerdict: Verdict? = nil
            ) {
                var list = entries
                for (key, value) in extra { list[key] = value }
                if let dropping { list[dropping] = nil }
                let (root, relinkedList) = relinked(
                    list, root: base.rootCID, replacing: mapCID,
                    with: FlatDictionary(changed).toData()!
                )
                add("\(name) in map at level \(level)", root: root,
                    entries: relinkedList.map { ($0.key, $0.value) }, unicodeVerdict: unicodeVerdict)
            }
            var renamed = map.entries
            renamed[directory] = nil
            renamed["Zz\(level)"] = link
            remapped("missing directory key", renamed)
            var invalidKey = map.entries
            invalidKey["bad/dir"] = link
            remapped("invalid directory key", invalidKey)
            var sibling = map.entries
            sibling["Extra\(level)"] = BlockHeader(rawCID: CIDIdentity.standardCID(of: Data("x".utf8)))
            remapped("extra well-formed key", sibling)
            var emptyLink = map.entries
            emptyLink["Empty\(level)"] = BlockHeader(rawCID: "")
            remapped("empty link beside the path", emptyLink)

            let linked = entries[link.rawCID]!
            let raw = rawCodecCID(of: linked)
            var nonStandard = map.entries
            nonStandard[directory] = BlockHeader(rawCID: raw)
            remapped("raw-codec link (entry supplied)", nonStandard,
                     extra: [raw: linked], dropping: link.rawCID)
            remapped("raw-codec link (entry missing)", nonStandard, dropping: link.rawCID)
            var encrypted = map.entries
            encrypted[directory] = BlockHeader(
                rawCID: link.rawCID, node: nil,
                encryptionInfo: EncryptionInfo(keyHash: "k", iv: "iv")
            )
            remapped("encrypted link", encrypted)
            remapped("empty map", [:])
            for (position, spelled) in unicodeEquivalents(of: directory) {
                var respelled = map.entries
                respelled[directory] = nil
                respelled[spelled] = link
                remapped("key equivalent @\(position)", respelled)
                // Not a directory: the map is judged before the link.
                remapped("key equivalent @\(position), link entry missing", respelled,
                         dropping: link.rawCID, unicodeVerdict: .rejected(.protocolInvalid))
            }
        }
        for (level, directory) in fixture.directories.enumerated() {
            for (position, spelled) in unicodeEquivalents(of: directory) {
                var path = fixture.directories
                path[level] = spelled
                // The proof never names the respelled directory.
                add("runtime directory \(level) equivalent @\(position)", path: path,
                    chainPath: [DEFAULT_ROOT_DIRECTORY] + path,
                    unicodeVerdict: .rejected(.malformedEvidence))
            }
        }
        // A peer respells the proof's path; the runtime path stays ASCII. The
        // shape is compared byte for byte, so the walk never sees it, with or
        // without the terminal entry.
        let terminalCID = try! BlockHeader(node: fixture.child).rawCID
        var respelledPaths: [(name: String, path: [String])] = []
        for (level, directory) in fixture.directories.enumerated() {
            for (position, spelled) in unicodeEquivalents(of: directory) {
                var path = fixture.directories
                path[level] = spelled
                respelledPaths.append(("proof directory \(level) equivalent @\(position)", path))
            }
        }
        if respelledPaths.count > 1 {
            respelledPaths.append(("every proof directory equivalent", fixture.directories.map {
                unicodeEquivalents(of: $0).first?.spelled ?? $0
            }))
        }
        for (name, path) in respelledPaths {
            add(name, path: path, unicodeVerdict: .rejected(.malformedEvidence))
            add("\(name), terminal entry dropped", path: path,
                entries: base.entries.filter { $0.cid != terminalCID },
                unicodeVerdict: .rejected(.malformedEvidence))
        }

        // Wrong child, extra entries, shape.
        add("child = root", child: fixture.blocks[0])
        add("child re-nonced", child: rebuilt(fixture.child, nonce: fixture.child.nonce &+ 1))
        for (index, other) in others.prefix(3).enumerated() {
            add("child from another proof \(index)", child: other.child)
            add("extra entry from another proof \(index)",
                entries: base.entries + [other.proof.entries[0]])
        }
        let junk = Data("junk".utf8)
        add("extra junk entry", entries: base.entries + [(CIDIdentity.standardCID(of: junk), junk)])
        add("no entries", entries: [])
        add("no directories", path: [], chainPath: [DEFAULT_ROOT_DIRECTORY])
        add("chain path off-root", chainPath: ["Other"] + fixture.directories)
        add("chain path short", chainPath: Array(fixture.chainPath.dropLast()))
        add("chain path long", chainPath: fixture.chainPath + ["X"])
        let renamedPath = fixture.directories.dropLast() + ["Nope"]
        add("renamed last directory", path: Array(renamedPath),
            chainPath: [DEFAULT_ROOT_DIRECTORY] + renamedPath)
        let emptyPath = fixture.directories.dropLast() + [""]
        add("empty last directory", path: Array(emptyPath),
            chainPath: [DEFAULT_ROOT_DIRECTORY] + emptyPath)
        return cases
    }

    // MARK: - Byte helpers

    /// Replace the entry `old` with `data` under its own CID, and rewrite every
    /// entry linking `old` to link the new CID instead, up to the root.
    private func relinked(
        _ entries: [String: Data],
        root: String,
        replacing old: String,
        with data: Data
    ) -> (root: String, entries: [String: Data]) {
        var entries = entries
        var root = root
        let new = CIDIdentity.standardCID(of: data)
        entries[old] = nil
        entries[new] = data
        if root == old { root = new }
        guard new != old else { return (root, entries) }
        while let parent = entries.first(where: { $0.key != new && $0.value.range(of: Data(old.utf8)) != nil }) {
            (root, entries) = relinked(
                entries, root: root, replacing: parent.key,
                with: replacingAll(in: parent.value, Data(old.utf8), with: Data(new.utf8))
            )
        }
        return (root, entries)
    }

    private func replacingAll(in data: Data, _ target: Data, with replacement: Data) -> Data {
        var out = data
        var start = out.startIndex
        while let range = out.range(of: target, in: start..<out.endIndex) {
            out.replaceSubrange(range, with: replacement)
            start = range.lowerBound + replacement.count
        }
        return out
    }

    /// The same value with a non-minimal initial head: `a1` becomes `b8 01`.
    private func nonMinimalHead(_ data: Data) -> Data {
        let head = data[data.startIndex]
        guard head & 0x1f < 24 else { return data + Data([0]) }
        return Data([head & 0xe0 | 24, head & 0x1f]) + data.dropFirst()
    }

    private func standardLinks(in data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var links: [String] = []
        var rest = text[...]
        while let range = rest.range(of: "bafyrei") {
            let candidate = String(rest[range.lowerBound...].prefix(59))
            if CIDIdentity.isStandard(candidate), !links.contains(candidate) { links.append(candidate) }
            rest = rest[range.upperBound...]
        }
        return links
    }

    /// `directory` with one character respelled as a canonically equivalent,
    /// byte-distinct one: equal as a Swift `String`, unequal as bytes.
    private func unicodeEquivalents(of directory: String) -> [(position: Int, spelled: String)] {
        let equivalents: [Character: Character] = ["K": "\u{212A}", ";": "\u{037E}", "`": "\u{1FEF}"]
        return Array(directory).enumerated().compactMap { position, character in
            guard let equivalent = equivalents[character] else { return nil }
            var spelled = Array(directory)
            spelled[position] = equivalent
            return (position, String(spelled))
        }
    }

    private func rawCodecCID(of data: Data) -> String {
        CIDIdentity.base32Multibase([0x01, 0x55, 0x12, 0x20] + Array(SHA256.hash(data: data)))
    }

    private func label(_ cid: String, in fixture: Fixture, entries: [String: Data]) -> String {
        if let level = fixture.blocks.firstIndex(where: { (try? BlockHeader(node: $0).rawCID) == cid }) {
            return "block\(level)"
        }
        if let level = fixture.blocks.firstIndex(where: { $0.children.rawCID == cid }) {
            return "map\(level)"
        }
        return "entry \(cid.suffix(6))"
    }

    private func rebuilt(
        _ block: Block,
        parentState: LatticeStateHeader? = nil,
        prevState: LatticeStateHeader? = nil,
        rewardRecipient: String? = nil,
        nonce: UInt64? = nil
    ) -> Block {
        Block(
            version: block.version, parent: block.parent, transactions: block.transactions,
            target: block.target, nextTarget: block.nextTarget, spec: block.spec,
            parentState: parentState ?? block.parentState,
            prevState: prevState ?? block.prevState,
            postState: block.postState, children: block.children, height: block.height,
            timestamp: block.timestamp,
            rewardRecipient: rewardRecipient ?? block.rewardRecipient,
            nonce: nonce ?? block.nonce
        )
    }
}

// MARK: - Verdict

private enum Verdict: Equatable, CustomStringConvertible {
    case accepted(
        grindID: String,
        rootHash: UInt256,
        creditedAncestorWork: UInt256,
        childCID: String,
        terminalCarrierCID: String,
        contribution: VerifiedWorkContribution?
    )
    case rejected(ChildProofVerificationFailure)

    init(_ result: Result<VerifiedChildEvidence, ChildProofVerificationFailure>) {
        switch result {
        case .success(let e):
            self = .accepted(
                grindID: e.grindID, rootHash: e.rootHash,
                creditedAncestorWork: e.creditedAncestorWork, childCID: e.childCID,
                terminalCarrierCID: e.terminalCarrierCID, contribution: e.contribution
            )
        case .failure(let failure):
            self = .rejected(failure)
        }
    }

    var label: String {
        switch self {
        case .accepted(_, _, _, _, _, let contribution):
            return contribution == nil ? "accepted-nocontribution" : "accepted+contribution"
        case .rejected(let failure):
            return "\(failure)"
        }
    }

    var description: String {
        switch self {
        case .accepted(_, _, let credited, _, _, let contribution):
            return "accepted(credited: \(credited), contribution: \(String(describing: contribution?.work)))"
        case .rejected(let failure):
            return "rejected(\(failure))"
        }
    }
}

// MARK: - The verifier before the synchronous walk (Lattice 56.2.0, d0edb15)

private enum Legacy {
    static func verifySecuringWork(
        _ proof: ChildBlockProof,
        child: Block,
        chainPath: [String]
    ) async -> Result<VerifiedChildEvidence, ChildProofVerificationFailure> {
        let entries = proof.entries
        let rootCID = proof.rootCID
        let directoryPath = proof.directoryPath
        let hasRepresentableDirectoryPath = directoryPath.count <= ChildProofWireLimits.maximumDepth
            && directoryPath.allSatisfy {
                $0.utf8.count <= ChildProofWireLimits.maximumDirectoryBytes
            }
        guard chainPath.first == DEFAULT_ROOT_DIRECTORY,
              hasRepresentableDirectoryPath,
              chainPath.count == directoryPath.count + 1,
              directoryPath == Array(chainPath.dropFirst()),
              !entries.isEmpty,
              !directoryPath.isEmpty else {
            return .failure(.malformedEvidence)
        }
        let root: (block: Block, hash: UInt256)
        switch verifiedRoot(proof) {
        case .success(let verified): root = verified
        case .failure(let failure): return .failure(failure)
        }
        guard let childCID = try? BlockHeader(node: child).rawCID else {
            return .failure(.malformedEvidence)
        }

        let rootBlock = root.block
        let rootHash = root.hash

        var proofEntries: [String: Data] = [:]
        for entry in entries {
            guard proofEntries.updateValue(entry.data, forKey: entry.cid) == nil else {
                return .failure(.malformedEvidence)
            }
        }
        let fetcher = LegacyTrackingProofFetcher(proofEntries)
        var directlyConsumed = Set([rootCID])
        var carriers: [(block: Block, cid: String)] = [
            (rootBlock, rootCID)
        ]
        var currentBlock = rootBlock

        for (index, directory) in directoryPath.enumerated() {
            guard let children = try? await currentBlock.children.resolve(
                    paths: [[directory]: .targeted], fetcher: fetcher
                  ).node,
                  let childHeader: VolumeImpl<Block> = children[directory]
            else { return .failure(.malformedEvidence) }
            guard children.isWellFormed else { return .failure(.protocolInvalid) }

            if index == directoryPath.count - 1 {
                guard childHeader.rawCID == childCID else {
                    return .failure(.malformedEvidence)
                }
                guard child.parentState.rawCID == currentBlock.prevState.rawCID else {
                    return .failure(.protocolInvalid)
                }
                let consumed = await fetcher.consumed().union(directlyConsumed)
                guard consumed == Set(proofEntries.keys) else {
                    return .failure(.malformedEvidence)
                }
                guard let deepestCarrier = carriers.last else {
                    return .failure(.malformedEvidence)
                }
                let creditedAncestorWork = carriers.first {
                    $0.block.validateProofOfWork(nexusHash: rootHash)
                }.map { workForTarget($0.block.target) } ?? UInt256.zero
                let contribution = child.validateProofOfWork(nexusHash: rootHash)
                    ? VerifiedWorkContribution(
                        id: rootCID,
                        work: max(
                            creditedAncestorWork,
                            workForTarget(child.target)
                        )
                    )
                    : nil
                return .success(VerifiedChildEvidence(
                    grindID: rootCID,
                    rootHash: rootHash,
                    creditedAncestorWork: creditedAncestorWork,
                    childCID: childCID,
                    terminalCarrierCID: deepestCarrier.cid,
                    contribution: contribution
                ))
            }

            guard let nextData = proofEntries[childHeader.rawCID] else {
                return .failure(.malformedEvidence)
            }
            let next: Block
            switch contentBoundBlock(cid: childHeader.rawCID, data: nextData) {
            case .success(let block): next = block
            case .failure(let failure): return .failure(failure)
            }
            directlyConsumed.insert(childHeader.rawCID)
            guard next.parentState.rawCID == currentBlock.prevState.rawCID else {
                return .failure(.protocolInvalid)
            }
            currentBlock = next
            carriers.append((
                currentBlock,
                childHeader.rawCID
            ))
        }
        return .failure(.malformedEvidence)
    }

    private static func verifiedRoot(
        _ proof: ChildBlockProof
    ) -> Result<(block: Block, hash: UInt256), ChildProofVerificationFailure> {
        let rootEntries = proof.entries.filter { $0.cid == proof.rootCID }
        guard rootEntries.count == 1, let rootData = rootEntries.first?.data else {
            return .failure(.malformedEvidence)
        }
        return contentBoundBlock(cid: proof.rootCID, data: rootData).map { ($0, $0.proofOfWorkHash()) }
    }

    private static func contentBoundBlock(
        cid: String,
        data: Data
    ) -> Result<Block, ChildProofVerificationFailure> {
        guard CIDIdentity.standardCID(of: data) == cid else { return .failure(.malformedEvidence) }
        guard let block = Block(data: data), block.hasWellFormedRewardRecipient else {
            return .failure(.protocolInvalid)
        }
        return .success(block)
    }
}

private actor LegacyTrackingProofFetcher: Fetcher {
    private let source: InMemoryContentSource
    private var consumedCIDs = Set<String>()

    init(_ entries: [String: Data]) {
        source = InMemoryContentSource(entries)
    }

    func fetch(rawCid: String) async throws -> Data {
        consumedCIDs.insert(rawCid)
        return try await source.fetch(rawCid: rawCid)
    }

    func consumed() -> Set<String> {
        consumedCIDs
    }
}
