import cashew

public typealias AccountState = VolumeMerkleDictionaryImpl<UInt64>
public typealias AccountStateHeader = VolumeImpl<AccountState>

/// The fixed size a balance or nonce entry's value counts toward
/// `maxStateGrowth` (a uint64), whatever its stored spelling (spec §6.6).
package let ACCOUNT_ENTRY_VALUE_BYTES = 8

public extension AccountStateHeader {
    /// THE consensus nonce floor rule: the nonce a signer's next transaction
    /// must carry, given the trie's stored nonce (`nil` — the account has never
    /// transacted — floors at 0; otherwise stored + 1). Consumed by the state
    /// transition's contiguity check in `proveAndUpdateState` and by node-side
    /// admission — one definition so the two cannot drift.
    static func nextExpectedNonce(afterStored currentNonce: UInt64?) throws -> UInt64 {
        guard let currentNonce else { return 0 }
        let (next, overflow) = currentNonce.addingReportingOverflow(1)
        guard !overflow else { throw StateErrors.nonceGap }
        return next
    }

    /// Public read API over the floor rule: resolve `account`'s stored nonce
    /// from this account-state trie and return the next expected nonce.
    func nextExpectedNonce(for account: String, fetcher: Fetcher) async throws -> UInt64 {
        guard isValidAccountAtom(account) else {
            throw StateErrors.conflictingActions
        }
        let nonceKey = Self.nonceTrackingKey(account)
        let resolved = try await resolve(paths: [[nonceKey]: ResolutionStrategy.targeted], fetcher: fetcher)
        let currentNonce: UInt64? = resolved.node.flatMap { try? $0.get(key: nonceKey) }
        return try Self.nextExpectedNonce(afterStored: currentNonce)
    }

    static let nonceKeyPrefix = "_nonce_"

    static func nonceTrackingKey(_ account: String) -> String {
        nonceKeyPrefix + account
    }

    static func isReservedAccountKey(_ key: String) -> Bool {
        key.hasPrefix(nonceKeyPrefix)
    }
}
