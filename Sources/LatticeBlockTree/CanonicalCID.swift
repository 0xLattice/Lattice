import LatticePrimitives

/// A held block's identity.
typealias BlockID = CIDDigest
/// A grind's identity: the CID of the block or run its work was proven on.
typealias GrindID = CIDDigest
/// A post- or pre-state a block declares, when that state is a canonical CID.
typealias StateID = CIDDigest
