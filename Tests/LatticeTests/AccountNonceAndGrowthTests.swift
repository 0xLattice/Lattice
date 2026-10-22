import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeValidation
import UInt256
import cashew
import Foundation

private func tx(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    let h = try! HeaderImpl<TransactionBody>(node: body)
    let sig = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: sig], body: h)
}

private func id(_ pubKey: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
}

private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private func body(_ accountActions: [AccountAction], signers: [String], nonce: UInt64) -> TransactionBody {
    TransactionBody(
        accountActions: accountActions, actions: [], depositActions: [], receiptActions: [],
        withdrawalActions: [], signers: signers, nonce: nonce, chainPath: ["Nexus"]
    )
}

@MainActor
final class AccountNonceAndGrowthTests: XCTestCase {

    private func nonce(_ state: AccountStateHeader, _ signer: String) throws -> UInt64? {
        try state.node?.get(key: AccountStateHeader.nonceTrackingKey(signer))
    }

    // MARK: - Only the first signer's nonce is checked and advanced

    func testCoSignerNonceIsNeitherCheckedNorAdvanced() async throws {
        let fetcher = StorableFetcher()
        let empty = try AccountStateHeader(node: AccountState())
        try await empty.storeRecursively(storer: fetcher)
        // A has used nonces 0...3 (next 4); B has never transacted (next 0).
        let (aUsed, _) = try await empty.proveAndUpdateState(
            allAccountActions: [], transactionBodies: (0...3).map { body([], signers: ["A"], nonce: $0) },
            fetcher: fetcher
        )
        try await aUsed.storeRecursively(storer: fetcher)

        let (joint, _) = try await aUsed.proveAndUpdateState(
            allAccountActions: [], transactionBodies: [body([], signers: ["A", "B"], nonce: 4)],
            fetcher: fetcher
        )
        XCTAssertEqual(try nonce(joint, "A"), 4)
        XCTAssertNil(try nonce(joint, "B"))

        do {
            _ = try await aUsed.proveAndUpdateState(
                allAccountActions: [], transactionBodies: [body([], signers: ["B", "A"], nonce: 4)],
                fetcher: fetcher
            )
            XCTFail("the first signer's own floor (B: 0) decides")
        } catch StateErrors.nonceGap {}

        do {
            _ = try await aUsed.proveAndUpdateState(
                allAccountActions: [], transactionBodies: [body([], signers: ["A", "_nonce_A"], nonce: 4)],
                fetcher: fetcher
            )
            XCTFail("a reserved co-signer is still refused")
        } catch StateErrors.conflictingActions {}
    }

    // MARK: - Account entries count toward state growth

    func testAccountTransitionMeasuresEntriesCreatedAndRemoved() async throws {
        let fetcher = StorableFetcher()
        let empty = try AccountStateHeader(node: AccountState())
        try await empty.storeRecursively(storer: fetcher)

        // Creates balance "ab" (2 + 8) and nonce "_nonce_ab" (9 + 8).
        let (funded, _, created) = try await empty.proveAndUpdateStateMeasuringGrowth(
            allAccountActions: [AccountAction(owner: "ab", delta: 5)],
            transactionBodies: [body([], signers: ["ab"], nonce: 0)],
            fetcher: fetcher
        )
        XCTAssertEqual(created, 10 + 17)
        try await funded.storeRecursively(storer: fetcher)

        // Removes "ab" (-10) and creates "cdef" (+12); the nonce only changes.
        let (_, _, moved) = try await funded.proveAndUpdateStateMeasuringGrowth(
            allAccountActions: [AccountAction(owner: "ab", delta: -5), AccountAction(owner: "cdef", delta: 5)],
            transactionBodies: [body([], signers: ["ab"], nonce: 1)],
            fetcher: fetcher
        )
        XCTAssertEqual(moved, -10 + 12)

        // A balance change alone counts nothing.
        let (_, _, changed) = try await funded.proveAndUpdateStateMeasuringGrowth(
            allAccountActions: [AccountAction(owner: "ab", delta: 7)],
            fetcher: fetcher
        )
        XCTAssertEqual(changed, 0)
    }

    func testGrowthFloorCreditsOnlyNetDebitedOwners() throws {
        let write = Action(key: "k", oldValue: nil, newValue: "v")  // +2
        func floor(_ accountActions: [AccountAction]) throws -> Int? {
            try TransactionBody.stateGrowthFloor(of: [TransactionBody(
                accountActions: accountActions, actions: [write], depositActions: [], receiptActions: [],
                withdrawalActions: [], signers: ["ab"], nonce: 0, chainPath: ["Nexus"]
            )])
        }
        // "ab" might be emptied, freeing (2 + 8); a credit can free nothing.
        XCTAssertEqual(try floor([AccountAction(owner: "ab", delta: -5), AccountAction(owner: "cdef", delta: 5)]), 2 - 10)
        XCTAssertEqual(try floor([AccountAction(owner: "cdef", delta: 5)]), 2)
        // A debit offset by a credit to the same owner nets to a credit.
        XCTAssertEqual(try floor([AccountAction(owner: "ab", delta: -5), AccountAction(owner: "ab", delta: 7)]), 2)
    }

    func testBlockCreatingAccountsPastTheLimitIsInvalid() async throws {
        let fetcher = StorableFetcher()
        let funder = CryptoUtils.generateKeyPair()
        let funderAddr = id(funder.publicKey)
        // The limit is exactly what genesis grows: the funder's balance and nonce.
        let genesisGrowth = (funderAddr.utf8.count + 8) + ("_nonce_".utf8.count + funderAddr.utf8.count + 8)
        let spec = ChainSpec.test(maxStateGrowth: genesisGrowth, premine: 1000)
        let base = now() - 10_000
        let genesis = try await buildAndStoreGenesis(
            spec: spec,
            transactions: [tx(body(
                [AccountAction(owner: funderAddr, delta: Int64(spec.premineAmount()))],
                signers: [funderAddr], nonce: 0
            ), funder)],
            timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let genesisValid = try await genesis.validateGenesis(fetcher: fetcher, chainPath: [DEFAULT_ROOT_DIRECTORY]).0
        XCTAssertTrue(genesisValid, "genesis fits its own limit exactly")

        // Each new 20-character account counts 28 bytes; its actions count 0.
        func payout(_ count: Int) -> Transaction {
            let names = (0..<count).map { String(format: "new-account-%08d", $0) }
            return tx(body(
                [AccountAction(owner: funderAddr, delta: -Int64(count))]
                    + names.map { AccountAction(owner: $0, delta: 1) },
                signers: [funderAddr], nonce: 1
            ), funder)
        }
        let fits = genesisGrowth / 28
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [payout(fits)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let fitsValid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(fitsValid, "control: \(fits) accounts fit")

        await assertThrows(StateErrors.stateGrowthExceeded, "the builder refuses what validation would") {
            try await buildAndStoreBlock(
                previous: genesis, transactions: [payout(fits + 1)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
        }
        let tooMany = try await buildAndStoreBlock(
            previous: genesis, transactions: [payout(fits + 1)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            allowStateGrowthViolation: true, fetcher: fetcher
        )
        let tooManyValid = try await tooMany.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(tooManyValid)
    }
}
