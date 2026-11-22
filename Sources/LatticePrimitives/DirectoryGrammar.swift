import Foundation
import UInt256

// MARK: - State-trie key grammar (consensus)
//
// The grammar for every semantic atom used as a state-trie key, enforced on the
// block-validation path (`TransactionBody.stateAtomsAreValid`, chain-path
// construction in `ChainRuntimeContext`, account-state reads).
//
// There is intentionally NO length/count limit here — key size is a node
// storage concern, not a protocol rule. Two structural constraints remain, and
// neither is a "limit":
//   * Visible ASCII (0x21…0x7e): the state trie keys by Swift `String`, whose
//     Unicode canonical equivalence would otherwise let byte-distinct keys
//     collide and serialize nondeterministically across nodes. This dissolves
//     once cashew keys tries by raw bytes.
//   * No `DIRECTORY_KEY_SEPARATOR` ("/") in account/directory atoms: preserves
//     receipt-key injectivity across chains (a `/` would let a withdrawal settle
//     against the wrong chain's receipt).

package func isDeterministicKeyAtom(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.allSatisfy { (0x21...0x7e).contains($0) }
}

package func isValidAccountAtom(_ value: String) -> Bool {
    isDeterministicKeyAtom(value) && !value.contains(DIRECTORY_KEY_SEPARATOR)
}

package func isValidDirectoryAtom(_ value: String) -> Bool {
    isDeterministicKeyAtom(value) && !value.contains(DIRECTORY_KEY_SEPARATOR)
}

/// A name a block may carry a child under: a directory atom the child-proof
/// wire can carry. The one rule for `children` keys, applied where blocks are
/// built and where they are received.
package func isValidChildDirectory(_ value: String) -> Bool {
    isValidDirectoryAtom(value)
        && value.utf8.count <= ChildProofWireLimits.maximumDirectoryBytes
}

package func isValidGeneralAtom(_ value: String) -> Bool {
    isDeterministicKeyAtom(value)
}

package enum ChildProofWireLimits {
    // Structural serialized field width: a directory is length-prefixed with a
    // UInt16 in the proof wire format, so this is the encoding capacity, not a
    // policy limit on how long a directory may be.
    package static let maximumDirectoryBytes = Int(UInt16.max)
    // Structural serialized field width: the directory path is length-prefixed
    // with a UInt16 in the proof wire format, so this is the encoding capacity,
    // not a policy limit on how deeply a chain may nest. A node that wants a
    // tighter bound on proof-walk depth enforces it as a local resource choice.
    package static let maximumDepth = Int(UInt16.max)
}

public enum ChainRuntimeContextError: Error, Sendable, Equatable {
    case emptyPath
    case emptyDirectory
    case rootMustBeNexus
    case directoryContainsSeparator
    case invalidDirectory
    case directoryTooLong
    case pathTooDeep
    /// A root chain names its one genesis: the configured Nexus CID.
    case rootGenesisRequired
    /// Only the root chain pins a genesis; a child chain's roots compete.
    case childGenesisPinned
    case invalidGenesisCID
}

/// Immutable Nexus-rooted identity for one chain process.
public struct ChainRuntimeContext: Sendable, Equatable {
    public let path: [String]
    /// The root chain's configured genesis CID — the only genesis a root
    /// chain admits (§5.1). Nil for a child chain, whose genesis roots
    /// compete by fork choice.
    public let genesisCID: String?

    public init(path: [String], genesisCID: String? = nil) throws {
        guard !path.isEmpty else { throw ChainRuntimeContextError.emptyPath }
        guard path.allSatisfy({ !$0.isEmpty }) else {
            throw ChainRuntimeContextError.emptyDirectory
        }
        guard path.first == DEFAULT_ROOT_DIRECTORY else {
            throw ChainRuntimeContextError.rootMustBeNexus
        }
        guard path.dropFirst().count <= ChildProofWireLimits.maximumDepth else {
            throw ChainRuntimeContextError.pathTooDeep
        }
        // A directory must fit the proof wire format's UInt16 length prefix so
        // every chain path stays provable. This is a serialized field width, not
        // a policy limit.
        guard path.allSatisfy({
            $0.utf8.count <= ChildProofWireLimits.maximumDirectoryBytes
        }) else {
            throw ChainRuntimeContextError.directoryTooLong
        }
        guard path.allSatisfy({ !$0.contains(DIRECTORY_KEY_SEPARATOR) }) else {
            throw ChainRuntimeContextError.directoryContainsSeparator
        }
        guard path.allSatisfy(isValidDirectoryAtom) else {
            throw ChainRuntimeContextError.invalidDirectory
        }
        if path.count == 1 {
            guard let genesisCID else { throw ChainRuntimeContextError.rootGenesisRequired }
            guard let canonical = CIDIdentity.canonicalString(genesisCID) else {
                throw ChainRuntimeContextError.invalidGenesisCID
            }
            self.genesisCID = canonical
        } else {
            guard genesisCID == nil else { throw ChainRuntimeContextError.childGenesisPinned }
            self.genesisCID = nil
        }
        self.path = path
    }

    /// Whether `blockHash` may be a genesis root of this chain: on the root
    /// chain only the configured genesis; on a child chain, any.
    public func admitsGenesis(_ blockHash: String) -> Bool {
        genesisCID.map { $0 == blockHash } ?? true
    }

    public var isRoot: Bool { path.count == 1 }
}
