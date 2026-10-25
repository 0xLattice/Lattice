import cashew
import UInt256
import LatticePrimitives
import LatticePoW
@testable import LatticeBlockTreeReference

// The frozen 50.0.1 oracle. `LiveSubject.swift` is this file's twin over the
// live module: keep the two identical apart from the import and the type name,
// so every difference the oracle reports is a difference in the block tree,
// never in how the harness drives or reads it.
// The one exception is `observeGraphQueries`, for queries 50.0.1 did not have.

struct ReferenceSubject: OracleSubject {
    var tree: ChainTree

    static func batch(_ batch: OracleBatch) -> BlockImportBatch {
        .staged(batch.facts.map { fact -> ChainFact in
            switch fact {
            case .block(let block):
                return .block(ChainBlockFact(
                    blockHash: block.hash,
                    parentBlockHash: block.parent,
                    blockHeight: block.height,
                    postStateCID: block.postState,
                    prevStateCID: block.prevState,
                    specCID: block.spec,
                    target: block.target,
                    nextTarget: block.nextTarget,
                    timestamp: block.timestamp,
                    stateDiff: .empty,
                    childCommitments: block.childCommitments
                ))
            case .work(let blockHash, let grindID, let work):
                return .work(ChainWorkFact(
                    blockHash: blockHash,
                    // VerifiedWorkContribution (live LatticePoW) canonicalizes the grind
                    // ID for both sides: it is the trusted boundary, as in production.
                    contribution: VerifiedWorkContribution(id: grindID, work: work)
                ))
            case .exclusion(let blockHash):
                return .exclusion(ChainExclusionFact(blockHash: blockHash))
            case .validation(let blockHash):
                return .validation(ChainValidationFact(blockHash: blockHash))
            }
        })
    }

    static func restoreRoot(
        _ log: [OracleBatch], specs: [ChainSpec]
    ) -> Result<Self, OracleRestoreFailure> {
        do {
            return .success(Self(tree: try ChainTree.restoreWithoutContext(
                replaying: log.map(batch), specs: specs
            )))
        } catch {
            return .failure(OracleRestoreFailure(text: "\(error)"))
        }
    }

    static func restoreChild(
        _ log: [OracleBatch],
        context: ChainRuntimeContext,
        specs: [ChainSpec],
        parent: Self
    ) -> Result<Self, OracleRestoreFailure> {
        do {
            return .success(Self(tree: try ChainTree.restore(
                replaying: log.map(batch), context: context, specs: specs, parent: parent.tree
            )))
        } catch {
            return .failure(OracleRestoreFailure(text: "\(error)"))
        }
    }

    mutating func apply(_ batch: OracleBatch, reserved: Bool) -> OracleOutcome {
        let staged = Self.batch(batch)
        do {
            let result: SubmissionResult?
            if reserved {
                guard tree.reserveImportRevision() else {
                    return OracleOutcome(rendered: "noReservation")
                }
                result = try tree.applyReservedStaged(staged)
            } else {
                result = try tree.apply(staged)
            }
            guard let result else { return OracleOutcome(rendered: "nil") }
            let weighed = result.weighed.sorted()
            return OracleOutcome(
                rendered: "block=\(result.addedBlock) contribution=\(result.addedContribution)"
                    + " extends=\(result.extendsCanonical) commit=\(Self.describe(result.commit))"
                    + " weighed=\(weighed.joined(separator: ","))",
                weighed: weighed
            )
        } catch {
            return OracleOutcome(rendered: "throw:\(error)")
        }
    }

    mutating func serveRuns(_ directory: String) {
        tree.serveRuns(for: directory)
    }

    mutating func applyParentRun(
        from parent: Self,
        directory: String,
        parentBlocks: Set<String>?,
        held: Set<String>
    ) -> OracleOutcome {
        let result = tree.applyParentRun(
            from: parent.tree, directory: directory, parentBlocks: parentBlocks, held: held
        )
        return OracleOutcome(
            rendered: "raised=\(result.raised.joined(separator: ",")) commit=\(Self.describe(result.commit))"
        )
    }

    mutating func reevaluate() -> OracleOutcome {
        OracleOutcome(rendered: Self.describe(tree.reevaluateForkChoice()))
    }

    mutating func observeTip() -> [String: String] {
        ["tip": tree.canonicalTip, "revision": "\(tree.currentRevision())"]
    }

    mutating func observe(_ probe: OracleProbe) -> [String: String] {
        var seen = observeTip()
        seen["height"] = "\(tree.getHighestBlockHeight())"
        seen["tipSnapshot"] = Self.describe(tree.tipSnapshot)
        seen["tipCumulativeWork"] = hex(tree.getTipCumulativeWork().toHexString())
        seen["specs"] = tree.specs.keys.sorted().joined(separator: ",")
        seen["preflight"] = Self.describe(tree.transactionPreflightTip())
        seen["unresolved"] = tree.unresolvedSameChainPredecessors()
            .map { "\($0.descendantCID)←\($0.predecessorCID)" }
            .joined(separator: ",")
        for height in 0...probe.maxHeight {
            seen["canonical@\(height)"] = tree.canonicalBlockHash(atHeight: height) ?? "nil"
        }

        for hash in probe.hashes {
            let key = "block \(hash)"
            seen["\(key) contains"] = "\(tree.contains(blockHash: hash))"
            seen["\(key) canonical"] = "\(tree.isCanonical(hash: hash))"
            seen["\(key) executed"] = "\(tree.isExecuted(blockHash: hash))"
            seen["\(key) executedAncestry"] = "\(tree.hasExecutedAncestry(blockHash: hash))"
            seen["\(key) excludedRoot"] = "\(tree.isExcludedRoot(hash))"
            seen["\(key) connected"] = "\(tree.hasConnectedAncestry(blockHash: hash))"
            seen["\(key) parentHash"] = tree.parentHash(of: hash) ?? "nil"
            seen["\(key) needs"] = tree.sameChainPredecessorRequirement(for: hash)
                .map { "\($0.descendantCID)←\($0.predecessorCID)" } ?? "nil"
            seen["\(key) weight"] = tree.forkChoiceWeight(of: hash).map { hex($0.toHexString()) } ?? "nil"
            let meta = tree.getConsensusBlock(hash: hash)
            seen["\(key) meta"] = meta == nil ? "nil" : "present"
            if let meta {
                // One key per field, so a deliberate change to how a block is
                // held shows exactly which consensus output moved. Child order
                // is an artifact of insertion: compared as a set.
                seen["\(key) meta.hash"] = meta.blockHash
                seen["\(key) meta.parent"] = meta.parentBlockHash ?? "nil"
                seen["\(key) meta.height"] = "\(meta.blockHeight)"
                seen["\(key) meta.anchor"] = render(meta.difficultyAnchor)
                seen["\(key) meta.work"] = hex(meta.work.toHexString())
                seen["\(key) meta.children"] = meta.childHashes.sorted().joined(separator: ",")
                seen["\(key) meta.contributions"] = meta.workContributions.values
                    .sorted { $0.id < $1.id }.map(render).joined(separator: ",")
                seen["\(key) meta.attributedRuns"] = meta.attributedRuns.sorted().joined(separator: ",")
                seen["\(key) meta.commitments"] = render(meta.childCommitments, only: probe.served)
            }
            // The descent from every genesis and every fork: which child each
            // fork prefers, and where that leads. A block with one child
            // descends exactly as that child does.
            if let meta, meta.parentBlockHash == nil || meta.childHashes.count > 1 {
                seen["\(key) descent"] = tree.forkChoiceSnapshot(startingAt: hash).map {
                    "from=\($0.startingHash) tip=\($0.tipHash) work=\(hex($0.subtreeWork.toHexString()))"
                        + " path=\($0.canonicalPath.sorted().joined(separator: ","))"
                } ?? "nil"
            }
            seen["\(key) cumulativeWork"] = tree.getCumulativeWork(forHash: hash)
                .map { hex($0.toHexString()) } ?? "nil"
            seen["\(key) subtreeWeight"] = tree.subtreeWeight(forHash: hash)
                .map { hex($0.toHexString()) } ?? "nil"
            seen["\(key) difficultyAnchor"] = render(tree.difficultyAnchor(forBlockHash: hash))
            seen["\(key) header"] = Self.describe(tree.headerSnapshot(of: hash))
            seen["\(key) strongestGrind"] = render(tree.strongestGrind(of: hash))
            seen["\(key) scheduleSpec"] = tree.scheduleSpec(underParent: hash)
                .map { "targetBlockTime=\($0.targetBlockTime)" } ?? "nil"
            seen["\(key) preflight"] = Self.describe(tree.transactionPreflightTip(at: hash))
            seen["\(key) commitments"] = render(tree.recordedChildCommitments(of: hash), only: probe.served)
            seen["\(key) runs"] = probe.directories.map {
                "\($0)=\(tree.nearestCarrier(of: hash, directory: $0) ?? "nil")"
            }.joined(separator: " ")
        }
        seen.merge(observeGraphQueries(probe)) { _, new in new }

        let other = probe.hashes.first ?? ""
        for grind in probe.grinds {
            seen["grind \(grind.id) at \(grind.hash)"] = [
                "accepts=\(tree.acceptsWorkLocation(of: grind.id, at: grind.hash))",
                "acceptsElsewhere=\(tree.acceptsWorkLocation(of: grind.id, at: other))",
                "credited=\(render(tree.workContribution(id: grind.id, at: grind.hash)))",
            ].joined(separator: " ")
        }

        for from in probe.states {
            seen["state \(from) produced"] = "\(tree.executedSetProduced(stateCID: from))"
            for to in probe.states {
                let key = "state \(from)→\(to)"
                seen["\(key) advanced"] = "\(tree.executedSetAdvanced(from: from, to: to))"
                seen["\(key) continuity"] = "\(tree.hasStateContinuity(from: from, to: to))"
            }
        }
        return seen
    }

    // MARK: Rendering of this module's types

    static func describe(_ commit: ChainCommit?) -> String {
        guard let commit else { return "nil" }
        let added = commit.canonicalBlocksAdded
            .sorted { $0.key < $1.key }
            .map { "\($0.key)@\($0.value)" }
        return "r\(commit.revision) tip=\(commit.tipHash)"
            + " added=\(added.joined(separator: ","))"
            + " removed=\(commit.canonicalBlocksRemoved.sorted().joined(separator: ","))"
    }

    static func describe(_ snapshot: TipBlockSnapshot?) -> String {
        guard let snapshot else { return "nil" }
        return "post=\(snapshot.postStateCID) prev=\(snapshot.prevStateCID)"
            + " spec=\(snapshot.specCID) target=\(hex(snapshot.target.toHexString()))"
            + " next=\(hex(snapshot.nextTarget.toHexString())) h=\(snapshot.tipHeight)"
            + " t=\(snapshot.timestamp)"
    }

    static func describe(_ preflight: (cid: String, snapshot: TipBlockSnapshot?)) -> String {
        "\(preflight.cid) \(describe(preflight.snapshot))"
    }
}

// MARK: - Graph queries added after 50.0.1

extension ReferenceSubject {
    /// The graph queries 50.0.1 did not have, answered from its API: the
    /// held block's parent, height and children, and the act-on tip by the
    /// node's own algorithm (lattice-node `ChainSelection.actOnTip`) over the
    /// index its boot walk builds. The live twin asks the new API directly.
    mutating func observeGraphQueries(_ probe: OracleProbe) -> [String: String] {
        var seen: [String: String] = [:]
        let index = NodeIndex(tree: &tree)
        var avoided: Set<String> = []
        var tips: [String] = []
        for _ in 0..<4 {
            let tip = index.actOnTip(avoiding: avoided, in: tree)
            tips.append(tip)
            guard avoided.insert(tip).inserted else { break }
        }
        seen["heaviestExecutedTip"] = tips.joined(separator: ",")
        for hash in probe.hashes {
            let key = "block \(hash)"
            let meta = tree.getConsensusBlock(hash: hash)
            seen["\(key) graph"] = "parent=\(tree.parentHash(of: hash) ?? "nil")"
                + " height=\(meta.map { "\($0.blockHeight)" } ?? "nil")"
                + " children=\((meta?.childHashes ?? []).sorted().joined(separator: ","))"
            seen["\(key) heaviestExecutedTip avoiding"] = index.actOnTip(avoiding: [hash], in: tree)
        }
        return seen
    }
}

/// The node's `WeighedIndex` as `ChainCore.init` builds it — the best
/// chain's genesis root and everything under it — and its act-on descent,
/// transcribed from lattice-node `ChainSelection.swift`.
private struct NodeIndex {
    var parent: [String: String] = [:]
    var height: [String: UInt64] = [:]
    var children: [String: [String]] = [:]

    init(tree: inout ChainTree) {
        var stack = tree.canonicalBlockHash(atHeight: 0).map { [$0] } ?? []
        while let hash = stack.popLast() {
            guard let meta = tree.getConsensusBlock(hash: hash) else { continue }
            if height.updateValue(meta.blockHeight, forKey: hash) == nil, let parent = meta.parentBlockHash {
                self.parent[hash] = parent
                children[parent, default: []].append(hash)
            }
            stack += meta.childHashes
        }
    }

    func actOnTip(of tree: ChainTree) -> String {
        var tip = executedPrefix(of: tree)
        guard !tip.isEmpty else { return tip }
        while let next = byWeight((children[tip] ?? []).filter(tree.isExecuted(blockHash:)), in: tree).first {
            tip = next
        }
        return tip
    }

    func actOnTip(avoiding avoided: Set<String>, in tree: ChainTree) -> String {
        var tip = actOnTip(of: tree)
        guard let floor = avoided.compactMap({ height[$0] }).min() else { return tip }
        var deepest: String?
        var cid: String? = tip
        while let block = cid, let blockHeight = self.height[block], blockHeight >= floor {
            if avoided.contains(block) { deepest = block }
            cid = parent[block]
        }
        guard let deepest, let base = parent[deepest] else { return tip }
        tip = base
        while let next = byWeight((children[tip] ?? []).filter {
            tree.isExecuted(blockHash: $0) && !avoided.contains($0)
        }, in: tree).first {
            tip = next
        }
        return tip
    }

    func byWeight(_ siblings: [String], in tree: ChainTree) -> [String] {
        guard siblings.count > 1 else { return siblings }
        return siblings
            .map { (hash: $0, work: tree.forkChoiceWeight(of: $0) ?? .zero) }
            .sorted { $0.work != $1.work ? $0.work > $1.work : forkChoicePrefersBlock($0.hash, over: $1.hash) }
            .map(\.hash)
    }

    func executedPrefix(of tree: ChainTree) -> String {
        guard let genesis = tree.canonicalBlockHash(atHeight: 0), tree.isExecuted(blockHash: genesis) else { return "" }
        let tipHeight = tree.headerSnapshot(of: tree.canonicalTip)?.tipHeight ?? 0
        var low: UInt64 = 0
        var high = tipHeight
        while low < high {
            let middle = low + (high - low + 1) / 2
            if let hash = tree.canonicalBlockHash(atHeight: middle),
               tree.hasExecutedAncestry(blockHash: hash) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return tree.canonicalBlockHash(atHeight: low) ?? tree.canonicalTip
    }
}
