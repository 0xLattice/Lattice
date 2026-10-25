import Foundation
import cashew
import UInt256
import LatticePrimitives
import LatticePoW

public enum ChildProofSerializationError: Error, Sendable, Equatable {
    case valueTooLarge
}

/// Canonical sparse proof for the terminal parent-to-child commitment in a
/// potentially composed ``ChildBlockProof``.
///
/// This is a structural CAS fact only. It makes no claim about work,
/// authority, admission, or canonicity.
public struct DirectChildHop: Sendable {
    public let proof: ChildBlockProof
    public let childCID: String
    public let parentStateCID: String

    public func binds(child: Block) -> Bool {
        guard let cid = try? BlockHeader(node: child).rawCID else { return false }
        return cid == childCID && child.parentState.rawCID == parentStateCID
    }
}

/// Content-addressed identity for one canonical direct
/// `parent.children[directory] -> child` commitment.
///
/// This remains a structural CAS fact: availability does not imply work,
/// authority, admission, or canonicity.
public struct DirectChildEdge: Hashable, Scalar {
    public let parentCarrierCID: String
    public let directory: String
    public let childCID: String
    public let proofBytes: Data

    public var edgeCID: String? {
        try? HeaderImpl<DirectChildEdge>(node: self).rawCID
    }

    public var proof: ChildBlockProof? {
        ChildBlockProof.deserialize(proofBytes)
    }

    /// Strip the outer root context from a complete proof and regenerate its
    /// exact canonical terminal hop using only the sealed proof entries.
    public static func derive(from proof: ChildBlockProof) async -> DirectChildEdge? {
        guard let directory = proof.directoryPath.last,
              let hop = await proof.directHop(),
              let proofBytes = try? hop.proof.serialize(),
              let edge = await DirectChildEdge(
                parentCarrierCID: hop.proof.rootCID,
                directory: directory,
                childCID: hop.childCID,
                proofBytes: proofBytes
              ).validated()
        else { return nil }
        return edge
    }

    public func validated() async -> DirectChildEdge? {
        guard await canonicalHop() != nil, edgeCID != nil else { return nil }
        return self
    }

    public func validates(child: Block) async -> Bool {
        guard let hop = await canonicalHop(), edgeCID != nil else { return false }
        return hop.binds(child: child)
    }

    private func canonicalHop() async -> DirectChildHop? {
        guard CIDIdentity.isStandard(parentCarrierCID),
              CIDIdentity.isStandard(childCID),
              isValidChildDirectory(directory),
              let proof,
              proof.rootCID == parentCarrierCID,
              proof.directoryPath == [directory],
              (try? proof.serialize()) == proofBytes,
              let hop = await proof.directHop(),
              hop.childCID == childCID,
              (try? hop.proof.serialize()) == proofBytes else { return nil }
        return hop
    }
}

/// Scheduling values derived from a structurally verified descendant path.
public struct ChildSchedulingTargets: Sendable, Equatable {
    public let searchTarget: UInt256
    public let deploymentTarget: UInt256?

    public init(searchTarget: UInt256, deploymentTarget: UInt256?) {
        self.searchTarget = searchTarget
        self.deploymentTarget = deploymentTarget
    }
}

// MARK: - Proof

/// Sparse proof that a block is embedded under a PoW root, following the
/// content-addressed path `root → children[d0] → children[d1] → … → block`.
///
/// `directoryPath` is the chain of child directories from the PoW root down to the
/// proven block — `["SwapTest"]` for a direct child of the root, `["Mid","Stable"]`
/// for a grandchild. `entries` is the union of the sparse cashew CAS entries along
/// that whole path; `rootCID` is the absolute PoW-root block. A single-hop proof is
/// just a 1-element path — the depth-1 case is not special.
///
/// Multi-hop proofs are built by `composing(hop:)`: a relaying node that holds only its own
/// `root→self` proof (not the blocks above it) appends a locally-generated
/// `self→child` hop to extend the path one level, without ever materializing the
/// ancestor chain.
///
/// Serialized proof format:
///   [rootCIDLen: UInt16 LE][rootCID: UTF-8]
///   [pathLen: UInt16 LE]  for each: [dirLen: UInt16 LE][dir: UTF-8]
///   [numEntries: UInt16 LE]
///   for each entry:
///     [cidLen: UInt16 LE][cid: UTF-8]
///     [dataLen: UInt32 LE][data: bytes]
///
/// Verification uses a sealed in-memory source, verifies the mined root, then
/// walks `directoryPath` via targeted resolution down to the leaf CID.
public struct ChildBlockProof: Sendable {
    /// CAS entries from the sparse path (union across all hops, root → leaf only).
    public let entries: [(cid: String, data: Data)]
    /// CID of the PoW root block.
    public let rootCID: String
    /// Child directories from the root down to the proven block (root-exclusive).
    public let directoryPath: [String]

    public init(rootCID: String, directoryPath: [String], entries: [(cid: String, data: Data)]) {
        self.rootCID = CIDIdentity.canonicalString(rootCID) ?? rootCID
        self.directoryPath = directoryPath
        self.entries = entries.map {
            (CIDIdentity.canonicalString($0.cid) ?? $0.cid, $0.data)
        }.sorted { $0.0 < $1.0 }
    }

    private var hasRepresentableDirectoryPath: Bool {
        directoryPath.count <= ChildProofWireLimits.maximumDepth
            && directoryPath.allSatisfy {
                $0.utf8.count <= ChildProofWireLimits.maximumDirectoryBytes
            }
    }

    // MARK: - Generation

    /// Generate a single-hop sparse proof for `childDirectory` from a block the
    /// caller holds (the PoW root, or — for composition — an intermediate block).
    /// `directoryPath` is `[childDirectory]`; multi-level paths are built by
    /// composing single hops.
    public static func generate(
        rootHeader: VolumeImpl<Block>,
        childDirectory: String,
        fetcher: Fetcher
    ) async throws -> ChildBlockProof {
        try await resolveHop(
            rootHeader: rootHeader,
            childDirectory: childDirectory,
            fetcher: fetcher
        ).proof
    }

    /// Resolve `rootHeader` along `children/childDirectory` once, returning the
    /// single-hop proof together with the resolved block and children map so
    /// callers that also inspect them do not resolve the same map twice.
    private static func resolveHop(
        rootHeader: VolumeImpl<Block>,
        childDirectory: String,
        fetcher: Fetcher
    ) async throws -> (
        proof: ChildBlockProof,
        block: Block?,
        children: FlatDictionary<BlockHeader>?
    ) {
        guard childDirectory.utf8.count <= ChildProofWireLimits.maximumDirectoryBytes else {
            throw ChildProofSerializationError.valueTooLarge
        }
        let path: [[String]: ResolutionStrategy] = [["children", childDirectory]: .targeted]
        let resolvedRoot = try await rootHeader.resolve(paths: path, fetcher: fetcher)
        let storer = _CollectingStorer()
        try await resolvedRoot.store(paths: path, storer: storer)

        let proof = ChildBlockProof(
            rootCID: rootHeader.rawCID,
            directoryPath: [childDirectory],
            entries: storer.entries
        )
        let block = resolvedRoot.node
        return (proof, block, block?.children.node)
    }

    // MARK: - Composition

    /// Extend an upstream `root → self` proof by one level using a locally-generated
    /// `self → child` hop, yielding `root → … → self → child`. The relaying node
    /// holds only its own proof and its own block, never the blocks above it: the
    /// upstream path is reused verbatim, the hop appends `child`, and the entry sets
    /// are unioned (deduped by CID) so the verifier can walk the whole path. The hop
    /// must be rooted at `self` — the block whose directory is the last element of
    /// the upstream path — so the seam is content-addressed and unforgeable.
    public func composing(hop: ChildBlockProof) -> ChildBlockProof {
        var merged = entries
        var known = Dictionary(
            entries.map { ($0.cid, $0.data) },
            uniquingKeysWith: { first, _ in first }
        )
        for entry in hop.entries {
            if let data = known[entry.cid] {
                if data != entry.data { merged.append(entry) }
            } else {
                known[entry.cid] = entry.data
                merged.append(entry)
            }
        }
        return ChildBlockProof(
            rootCID: rootCID,
            directoryPath: directoryPath + hop.directoryPath,
            entries: merged
        )
    }

    // MARK: - Verification

    /// Extract the terminal direct hop from this proof's sealed CAS entries.
    /// The returned proof is regenerated using the same canonical generation
    /// path as an originally single-hop proof.
    public func directHop() async -> DirectChildHop? {
        guard let directory = directoryPath.last,
              CIDIdentity.isStandard(rootCID) else { return nil }

        var uniqueEntries: [String: Data] = [:]
        for entry in entries {
            guard CIDIdentity.isCanonical(entry.cid),
                  uniqueEntries.updateValue(entry.data, forKey: entry.cid) == nil else {
                return nil
            }
        }
        let source = InMemoryContentSource(uniqueEntries)
        var carrier = BlockHeader(rawCID: rootCID)

        for directory in directoryPath.dropLast() {
            guard let block = try? await carrier.resolve(fetcher: source).node,
                  let children = try? await block.children.resolve(
                    paths: [[directory]: .targeted],
                    fetcher: source
                  ).node,
                  children.isWellFormed,
                  let next: BlockHeader = children[directory],
                  CIDIdentity.isStandard(next.rawCID) else { return nil }
            carrier = next
        }

        guard let hop = try? await Self.resolveHop(
                rootHeader: carrier,
                childDirectory: directory,
                fetcher: source
              ),
              let block = hop.block,
              let children = hop.children,
              children.isWellFormed,
              let child: BlockHeader = children[directory],
              CIDIdentity.isStandard(child.rawCID) else { return nil }
        let proof = hop.proof

        return DirectChildHop(
            proof: proof,
            childCID: child.rawCID,
            parentStateCID: block.prevState.rawCID
        )
    }

    /// Validate a sparse descendant witness used only for child scheduling.
    /// Targets are derived from content-bound blocks; callers never supply
    /// trusted target values beside the proof.
    public func schedulingTargets(
        root: Block,
        terminal: Block
    ) async -> ChildSchedulingTargets? {
        guard hasRepresentableDirectoryPath,
              !directoryPath.isEmpty,
              !entries.isEmpty,
              let rootHeader = try? BlockHeader(node: root),
              let terminalHeader = try? BlockHeader(node: terminal),
              rootCID == rootHeader.rawCID else { return nil }

        var proofEntries: [String: Data] = [:]
        for entry in entries {
            guard CIDIdentity.isCanonical(entry.cid),
                  proofEntries.updateValue(entry.data, forKey: entry.cid) == nil else {
                return nil
            }
        }
        guard let rootData = proofEntries[rootCID],
              case .success = contentBoundBlock(cid: rootCID, data: rootData) else {
            return nil
        }

        let fetcher = _TrackingProofFetcher(proofEntries)
        var current = root
        var deploymentTarget = root.target
        var canonicalEntries: [String: Data] = [:]

        for (index, directory) in directoryPath.enumerated() {
            guard let hop = try? await Self.resolveHop(
                rootHeader: BlockHeader(node: current),
                childDirectory: directory,
                fetcher: fetcher
            ) else { return nil }
            for entry in hop.proof.entries {
                if let existing = canonicalEntries[entry.cid], existing != entry.data {
                    return nil
                }
                canonicalEntries[entry.cid] = entry.data
            }
            guard let children = hop.children,
                  children.isWellFormed,
                  let childHeader: BlockHeader = children[directory] else {
                return nil
            }

            if index == directoryPath.count - 1 {
                guard childHeader.rawCID == terminalHeader.rawCID,
                      terminal.parentState.rawCID == current.prevState.rawCID,
                      canonicalEntries == proofEntries else { return nil }
                return ChildSchedulingTargets(
                    searchTarget: terminal.target,
                    deploymentTarget: terminal.parent == nil
                        ? min(deploymentTarget, terminal.target)
                        : nil
                )
            }

            guard let data = proofEntries[childHeader.rawCID],
                  case .success(let next) = contentBoundBlock(cid: childHeader.rawCID, data: data),
                  next.parentState.rawCID == current.prevState.rawCID else { return nil }
            deploymentTarget = min(deploymentTarget, next.target)
            current = next
        }
        return nil
    }

    private func verifiedRoot() -> Result<(block: Block, hash: UInt256), ChildProofVerificationFailure> {
        let rootEntries = entries.filter { $0.cid == rootCID }
        guard rootEntries.count == 1, let rootData = rootEntries.first?.data else {
            return .failure(.malformedEvidence)
        }
        return contentBoundBlock(cid: rootCID, data: rootData).map { ($0, $0.proofOfWorkHash()) }
    }

    /// Verify the complete root-to-child directory commitment and derive its
    /// physical work. Carrier validity, admission, connectivity, and canonicity
    /// are intentionally outside this proof.
    public func verifySecuringWork(
        child: Block,
        chainPath: [String]
    ) async -> Result<VerifiedChildEvidence, ChildProofVerificationFailure> {
        guard chainPath.first == DEFAULT_ROOT_DIRECTORY,
              hasRepresentableDirectoryPath,
              chainPath.count == directoryPath.count + 1,
              directoryPath == Array(chainPath.dropFirst()),
              !entries.isEmpty,
              !directoryPath.isEmpty else {
            return .failure(.malformedEvidence)
        }
        let root: (block: Block, hash: UInt256)
        switch verifiedRoot() {
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
        let fetcher = _TrackingProofFetcher(proofEntries)
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

                // A grind is priced by the HIGHEST chain it legitimately
                // participated in: walk the carriers root-ward (index 0 is the
                // mined root) and take the first whose target this hash
                // actually beat.
                //
                // Previously this was a `max` over every met target. The two
                // agree unless some carrier's target is harder than both the
                // ROOT-MOST met target and the terminal's own — and that
                // is NOT an exotic shape. `ChainSpec.targetBlockTime` is a free
                // per-chain field and retarget drives each chain toward its own
                // block time, so a chain with far less hashrate than its parent
                // but a much longer block time sits at a HARDER target. An
                // inverted hierarchy is a configuration choice an operator may
                // make without intending it.
                //
                // Where they differ, the old max credited MORE. This is the
                // conservative variant: it removes an over-credit the maximum
                // allowed on an inverted hierarchy.
                //
                // It is NOT an anti-fabrication measure, and must not be
                // described as one. A carrier need not be valid
                // (`verifiedRoot()` only content-binds and re-hashes), so a
                // prover fabricating a ladder picks the pricing target just as
                // freely here as under the max — they simply build it
                // root-hardest instead of leaf-hardest. The adversarial
                // maximum is unchanged; only non-optimal, i.e. honest, ladder
                // shapes are repriced.
                //
                // This does not weaken the fabrication bound. A prover who
                // fabricates carriers would set the ROOT-most target hard too,
                // and `validateProofOfWork(nexusHash:)` still requires the hash
                // to beat whatever target is claimed, so no credit is created
                // that the hash did not earn.
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

    // MARK: - Serialization

    public func serialize() throws -> Data {
        var out = Data()
        let rootCIDBytes = Data(rootCID.utf8)
        guard rootCIDBytes.count <= Int(UInt16.max),
              hasRepresentableDirectoryPath,
              entries.count <= Int(UInt16.max) else {
            throw ChildProofSerializationError.valueTooLarge
        }
        writeU16(&out, UInt16(rootCIDBytes.count))
        out.append(rootCIDBytes)
        writeU16(&out, UInt16(directoryPath.count))
        for dir in directoryPath {
            let db = Data(dir.utf8)
            writeU16(&out, UInt16(db.count))
            out.append(db)
        }
        writeU16(&out, UInt16(entries.count))
        for (cid, data) in entries {
            let cb = Data(cid.utf8)
            guard cb.count <= Int(UInt16.max),
                  UInt64(data.count) <= UInt64(UInt32.max) else {
                throw ChildProofSerializationError.valueTooLarge
            }
            writeU16(&out, UInt16(cb.count))
            out.append(cb)
            writeU32(&out, UInt32(data.count))
            out.append(data)
        }
        return out
    }

    public static func deserialize(_ data: Data) -> ChildBlockProof? {
        var pos = data.startIndex
        guard let rootCIDLen = readU16(data, &pos),
              data.distance(from: pos, to: data.endIndex) >= Int(rootCIDLen),
              let rootCID = String(data: data[pos..<data.index(pos, offsetBy: Int(rootCIDLen))], encoding: .utf8)
        else { return nil }
        pos = data.index(pos, offsetBy: Int(rootCIDLen))

        guard let pathCount = readU16(data, &pos) else { return nil }
        var directoryPath: [String] = []
        for _ in 0..<Int(pathCount) {
            guard let dirLen = readU16(data, &pos),
                  data.distance(from: pos, to: data.endIndex) >= Int(dirLen),
                  let dir = String(data: data[pos..<data.index(pos, offsetBy: Int(dirLen))], encoding: .utf8)
            else { return nil }
            directoryPath.append(dir)
            pos = data.index(pos, offsetBy: Int(dirLen))
        }

        guard let count = readU16(data, &pos) else { return nil }
        var entries: [(String, Data)] = []
        var previousCID: String?
        for _ in 0..<Int(count) {
            guard let cidLen = readU16(data, &pos),
                  data.distance(from: pos, to: data.endIndex) >= Int(cidLen),
                  let cid = String(data: data[pos..<data.index(pos, offsetBy: Int(cidLen))], encoding: .utf8)
            else { return nil }
            pos = data.index(pos, offsetBy: Int(cidLen))

            guard let dataLen = readU32(data, &pos),
                  data.distance(from: pos, to: data.endIndex) >= Int(dataLen)
            else { return nil }
            if let previousCID, previousCID >= cid { return nil }
            entries.append((cid, Data(data[pos..<data.index(pos, offsetBy: Int(dataLen))])))
            previousCID = cid
            pos = data.index(pos, offsetBy: Int(dataLen))
        }
        guard pos == data.endIndex else { return nil }
        return ChildBlockProof(rootCID: rootCID, directoryPath: directoryPath, entries: entries)
    }
}

// MARK: - Internal helpers

public final class _CollectingStorer: Storer, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [String: Data] = [:]
    public init() {}
    public func store(entries: [String: Data]) async {
        lock.withLock { storedEntries.merge(entries) { _, new in new } }
    }
    public var entries: [(cid: String, data: Data)] {
        lock.withLock {
            storedEntries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
    }
}

private actor _TrackingProofFetcher: Fetcher {
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

/// The carrier `data` names, bound to `cid`. Bytes that are not the
/// content `cid` names are a proof-of-work failure (blame); bytes that are,
/// but are not a well-formed Lattice block (a non-standard link, a malformed
/// recipient), are structural: dropped without blame (spec §9.9).
private func contentBoundBlock(cid: String, data: Data) -> Result<Block, ChildProofVerificationFailure> {
    guard CIDIdentity.standardCID(of: data) == cid else { return .failure(.malformedEvidence) }
    guard let block = Block(data: data), block.hasWellFormedRewardRecipient else {
        return .failure(.protocolInvalid)
    }
    return .success(block)
}


private func writeU16(_ out: inout Data, _ v: UInt16) {
    out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8))
}
private func writeU32(_ out: inout Data, _ v: UInt32) {
    out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8(v >> 24))
}
private func readU16(_ data: Data, _ pos: inout Data.Index) -> UInt16? {
    guard data.distance(from: pos, to: data.endIndex) >= 2 else { return nil }
    let v = UInt16(data[pos]) | (UInt16(data[data.index(after: pos)]) << 8)
    pos = data.index(pos, offsetBy: 2); return v
}
private func readU32(_ data: Data, _ pos: inout Data.Index) -> UInt32? {
    guard data.distance(from: pos, to: data.endIndex) >= 4 else { return nil }
    let v = UInt32(data[pos]) | (UInt32(data[data.index(pos, offsetBy: 1)]) << 8)
              | (UInt32(data[data.index(pos, offsetBy: 2)]) << 16)
              | (UInt32(data[data.index(pos, offsetBy: 3)]) << 24)
    pos = data.index(pos, offsetBy: 4); return v
}
