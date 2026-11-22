import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeValidation
@testable import LatticeBlockTree
@testable import LatticeImport
import cashew
import Crypto
import Foundation
import Multikey
import UInt256

/// The hex and key-normalization paths every transaction crosses (decode,
/// `Transaction(signatures:body:)`, signature verification, address
/// derivation) against Lattice 57.0.0's own code.
///
/// Two oracles:
/// - `Reference57` is 57.0.0's hex code, verbatim, run in process against
///   random and adversarial inputs.
/// - `transaction-encoding-differential.json` was written by 57.0.0 itself: a
///   corpus of transactions with valid, mutated, and invalid signatures, keys,
///   and bodies, and what that release concluded about each one, through
///   decode, signature checks, preflight, and the validation of a block
///   carrying it. Ed25519 signatures on Apple hosts are randomized, so the
///   signatures are part of the file: the test reads them back and recomputes
///   every conclusion.
final class TransactionEncodingDifferentialTests: XCTestCase {

    // MARK: - Lattice 57.0.0, verbatim

    enum Reference57 {
        /// `Data.hexString` (LatticePrimitives/CryptoUtils.swift).
        static func hexString(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }

        /// `Data(hex:)` (LatticePrimitives/CryptoUtils.swift); Multikey
        /// 1.0.0's private `Data(hexString:)` is the same code.
        static func data(hex: String) -> Data? {
            let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
            guard clean.count % 2 == 0 else { return nil }
            var data = Data(capacity: clean.count / 2)
            var index = clean.startIndex
            while index < clean.endIndex {
                let next = clean.index(index, offsetBy: 2)
                guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
                data.append(byte)
                index = next
            }
            return data
        }

        /// Multikey 1.0.0 `decode(fromHex:)`.
        static func multikey(fromHex hex: String) -> Multikey? {
            data(hex: hex).flatMap { try? Multikey.decode(from: $0) }
        }

        /// Multikey 1.0.0 `hexEncoded`.
        static func hexEncoded(_ key: Multikey) -> String {
            key.encode().map { String(format: "%02x", $0) }.joined()
        }

        static func normalizedPublicKey(_ value: String) -> String {
            multikey(fromHex: value).map(hexEncoded) ?? value
        }

        static func normalizedSignature(_ value: String) -> String {
            data(hex: value).map(hexString) ?? value
        }

        /// `Transaction.normalized`.
        static func normalized(_ signatures: [String: String]) -> [String: String]? {
            var result: [String: String] = [:]
            for (rawKey, rawSignature) in signatures {
                let key = normalizedPublicKey(rawKey)
                guard result[key] == nil else { return nil }
                result[key] = normalizedSignature(rawSignature)
            }
            return result
        }

        /// `CryptoUtils.verify`.
        static func verify(message: String, signature: String, publicKeyHex: String) -> Bool {
            guard let sigData = data(hex: signature),
                  hexString(sigData) == signature else { return false }
            let messageData = CryptoUtils.signaturePayload(message)
            guard let key = multikey(fromHex: publicKeyHex),
                  hexEncoded(key) == publicKeyHex else { return false }
            guard key.keyType == .ed25519, key.keyBytes.count == 32,
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key.keyBytes),
                  sigData.count == 64 else { return false }
            return publicKey.isValidSignature(sigData, for: messageData)
        }

        /// `CryptoUtils.createAddress`.
        static func createAddress(from publicKey: String) -> String {
            let publicKey = multikey(fromHex: publicKey).map(hexEncoded) ?? publicKey
            return try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
        }
    }

    // MARK: - Primitives against the verbatim oracle

    func testHexStringMatchesFormatSpelling() {
        var rng = SeededRNG(seed: 0x6865_7873)
        // Slices keep their parent's indices: `hexString` must not assume 0.
        let whole = Data(0...255)
        var inputs: [Data] = [Data(), Data([0]), Data([0xff]), whole, whole[7...], whole[100..<101], whole[255...]]
        for _ in 0..<4_000 {
            let count = Int.random(in: 0...80, using: &rng)
            inputs.append(Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        }
        for data in inputs {
            XCTAssertEqual(data.hexString, Reference57.hexString(data))
        }
    }

    /// Every spelling `Data(hex:)` might meet: the hex digits of both cases,
    /// the `0x`/`0X` prefixes, the signs `UInt8(_:radix:)` accepts, and
    /// non-ASCII text, including a combining mark that joins a digit into one
    /// Character and a CR LF pair that is one.
    func testHexDecodingMatchesTheStringParser() {
        let alphabet = [
            "0", "1", "7", "9", "a", "c", "f", "A", "C", "F", "x", "X", "+", "-",
            " ", "g", "G", "0x", "0X", "\u{301}", "é", "０", "٣", "\r\n", "\n", "\u{0}",
        ]
        var rng = SeededRNG(seed: 0x6465_636f)
        var inputs = [
            "", "0", "0x", "0X", "00", "0x00", "0X00", "+f", "-0", "-1", "+-", "0x+f",
            "0x\u{301}00", "0\u{301}0", "\r\n00", "ff", "FF", "fF", "0x0x00", "x0",
        ]
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...10, using: &rng)
            inputs.append((0..<length).map { _ in alphabet.randomElement(using: &rng)! }.joined())
        }
        for _ in 0..<2_000 {
            let bytes = Data((0..<Int.random(in: 0...40, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            var hex = Reference57.hexString(bytes)
            if Bool.random(using: &rng) { hex = hex.uppercased() }
            if Bool.random(using: &rng) { hex = "0x" + hex }
            inputs.append(hex)
        }
        // `hexBytes` is `Data(hex:)`: this module declares a `Data(hex:)` of
        // its own, which shadows Lattice's here.
        for input in inputs {
            XCTAssertEqual(hexBytes(input), Reference57.data(hex: input), "\(input.debugDescription)")
        }
    }

    /// Keys of every registered type, unregistered codes, non-minimal and
    /// truncated varints, and spellings, through each place a key is read.
    func testKeyAndSignatureNormalizationMatches() throws {
        var rng = SeededRNG(seed: 0x6b65_7973)
        let prefixes: [[UInt8]] = [
            [0xed, 0x01], [0xe7, 0x01], [0x80, 0x24], [0x81, 0x24], [0x85, 0x24], [0x87, 0x24],
            [0xed, 0x81, 0x00], [0xed, 0x81, 0x80, 0x00], [0x01], [0x00], [0x80], [],
            [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01],
            [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01],
        ]
        let signer = Curve25519.Signing.PrivateKey()
        let message = "lattice differential"
        let goodSignature = Reference57.hexString(try signer.signature(for: CryptoUtils.signaturePayload(message)))
        let goodKey = Reference57.hexEncoded(Multikey(keyType: .ed25519, keyBytes: signer.publicKey.rawRepresentation))
        var keys = [goodKey, goodKey.uppercased(), "0x" + goodKey, "0X" + goodKey, "", "zz", "+d01"]
        var signatures = [goodSignature, goodSignature.uppercased(), "0x" + goodSignature, "", "0", "zz"]
        for _ in 0..<1_500 {
            var bytes = prefixes.randomElement(using: &rng)!
            let length = Bool.random(using: &rng) ? 32 : Int.random(in: 0...40, using: &rng)
            bytes += (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            keys.append(Self.respell(Reference57.hexString(Data(bytes)), using: &rng))
            let signature = (0..<Int.random(in: 62...66, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            signatures.append(Self.respell(Reference57.hexString(Data(signature)), using: &rng))
        }
        signatures.append(contentsOf: (0..<200).map { _ in Self.respell(goodSignature, using: &rng) })
        keys.append(contentsOf: (0..<200).map { _ in Self.respell(goodKey, using: &rng) })

        for (index, key) in keys.enumerated() {
            let signature = signatures[index % signatures.count]
            XCTAssertEqual(CryptoUtils.createAddress(from: key), Reference57.createAddress(from: key), key)
            XCTAssertEqual(
                CryptoUtils.verify(message: message, signature: signature, publicKeyHex: key),
                Reference57.verify(message: message, signature: signature, publicKeyHex: key),
                "\(key) \(signature)"
            )
            XCTAssertEqual(
                CryptoUtils.verify(message: message, signature: signature, publicKeyHex: goodKey),
                Reference57.verify(message: message, signature: signature, publicKeyHex: goodKey),
                signature
            )
            let pair = Dictionary(
                [(key, signature), (goodKey, signatures[(index * 7) % signatures.count])],
                uniquingKeysWith: { first, _ in first }
            )
            XCTAssertEqual(Transaction.normalized(pair), Reference57.normalized(pair), "\(pair)")
        }
    }

    /// One spelling of `hex` that 57.0.0 reads as the same bytes or nearly so:
    /// a case change, a prefix, a sign, a dropped or added digit, a non-hex
    /// character.
    static func respell(_ hex: String, using rng: inout SeededRNG) -> String {
        var characters = Array(hex)
        switch Int.random(in: 0..<9, using: &rng) {
        case 0: return hex
        case 1: return hex.uppercased()
        case 2: return "0x" + hex
        case 3: return "0X" + hex
        case 4:
            if let pair = stride(from: 0, to: characters.count, by: 2).first(where: { characters[$0] == "0" }) {
                characters[pair] = Bool.random(using: &rng) ? "+" : "-"
            }
        case 5: if !characters.isEmpty { characters.removeLast() }
        case 6: characters.append("0")
        case 7: if !characters.isEmpty { characters[Int.random(in: 0..<characters.count, using: &rng)] = "é" }
        default:
            if !characters.isEmpty {
                let at = Int.random(in: 0..<characters.count, using: &rng)
                characters[at] = Array("0123456789abcdef").randomElement(using: &rng)!
            }
        }
        return String(characters)
    }

    // MARK: - The 57.0.0 corpus

    struct Entry: Codable, Equatable {
        let key: String
        let value: String
    }

    /// A transaction's encoding with its signature entries as given, in the
    /// order given: the bytes a peer could send.
    struct RawTransaction: Node {
        let signatures: [Entry]
        let body: HeaderImpl<TransactionBody>

        func get(property: PathSegment) -> (any cashew.Header)? { property == "body" ? body : nil }
        func properties() -> Set<PathSegment> { ["body"] }
        func set(properties: [PathSegment: any cashew.Header]) -> RawTransaction {
            RawTransaction(signatures: signatures, body: properties["body"] as? HeaderImpl<TransactionBody> ?? body)
        }
    }

    struct Record: Codable, Equatable {
        let name: String
        /// The signature entries, as given: the input.
        let input: [Entry]
        let bodyCID: String
        // `Transaction(signatures:body:)` over the entries.
        let constructed: [Entry]
        let constructedCID: String
        let constructedSignaturesValid: Bool
        let constructedSignaturesMatchSigners: Bool
        // Each entry read alone.
        let addresses: [String]
        let isAddressOfItsKey: [Bool]
        let verifies: [Bool]
        // The entries' encoding, decoded.
        let rawCID: String
        let decoded: [Entry]?
        let decodedCID: String?
        let decodedSignaturesValid: Bool?
        let decodedSignaturesMatchSigners: Bool?
        // Admission and execution.
        let preflight: String
        let preflightWithoutPolicies: String
        /// The block carrying the constructed transaction, and its verdict.
        let block: String
        /// The block carrying the raw encoding, and its verdict.
        let rawBlock: String
    }

    struct Corpus: Codable, Equatable {
        let genesis: String
        let records: [Record]
    }

    /// Fixed keys: the corpus is reproducible but for the signatures.
    static func keyPair(_ seed: UInt8) -> (privateKey: String, publicKey: String) {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        return (
            Reference57.hexString(key.rawRepresentation),
            Reference57.hexEncoded(Multikey(keyType: .ed25519, keyBytes: key.publicKey.rawRepresentation))
        )
    }

    static let alice = keyPair(1)
    static let bob = keyPair(2)
    static let carol = keyPair(3)

    static func body(signers: [(privateKey: String, publicKey: String)], amount: Int64 = 10) -> HeaderImpl<TransactionBody> {
        let payer = Reference57.createAddress(from: alice.publicKey)
        let payee = Reference57.createAddress(from: carol.publicKey)
        return try! HeaderImpl(node: TransactionBody(
            accountActions: [AccountAction(owner: payer, delta: -amount), AccountAction(owner: payee, delta: amount)],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: signers.map { Reference57.createAddress(from: $0.publicKey) },
            nonce: 0, chainPath: [DEFAULT_ROOT_DIRECTORY]
        ))
    }

    static func sign(_ body: HeaderImpl<TransactionBody>, _ key: (privateKey: String, publicKey: String)) -> String {
        TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey)!
    }

    /// Replace the first byte pair of `hex` that begins with `0` by `sign`
    /// and its second digit; nil when there is none.
    static func signed(_ hex: String, _ sign: Character, requiringZeroPair: Bool = false) -> String? {
        var characters = Array(hex)
        guard let pair = stride(from: 0, to: characters.count, by: 2).first(where: {
            characters[$0] == "0" && (!requiringZeroPair || characters[$0 + 1] == "0")
        }) else { return nil }
        characters[pair] = sign
        return String(characters)
    }

    /// The corpus's inputs: each case's body and signature entries.
    /// `signing: false` builds the bodies alone, with a placeholder for every
    /// signature: reading the corpus signs nothing. Regeneration signs until
    /// the signature has the byte pairs the sign spellings need; that takes a
    /// randomized signer (CryptoKit, on Apple hosts). A deterministic one
    /// (BoringSSL, on Linux) signs the same bytes every time, so it is given
    /// a bounded number of tries.
    static func freshInputs(signing: Bool = true) -> [(name: String, body: HeaderImpl<TransactionBody>, input: [Entry])] {
        let single = body(signers: [alice])
        let both = body(signers: [alice, bob])
        let placeholder = String(repeating: "00", count: 64)
        let sign = { (body: HeaderImpl<TransactionBody>, key: (privateKey: String, publicKey: String)) in
            signing ? Self.sign(body, key) : placeholder
        }
        var aliceSignature = sign(single, alice)
        var tries = 1
        while signed(aliceSignature, "+") == nil || signed(aliceSignature, "-", requiringZeroPair: true) == nil {
            precondition(tries < 1_000, "regenerate on a host whose Ed25519 signatures are randomized")
            aliceSignature = sign(single, alice)
            tries += 1
        }
        let a = alice.publicKey
        let flipped = String(aliceSignature.prefix(10))
            + (aliceSignature[aliceSignature.index(aliceSignature.startIndex, offsetBy: 10)] == "0" ? "1" : "0")
            + String(aliceSignature.dropFirst(11))
        let keyBytes = String(a.dropFirst(4))
        func entries(_ pairs: (String, String)...) -> [Entry] { pairs.map { Entry(key: $0.0, value: $0.1) } }
        var cases: [(String, HeaderImpl<TransactionBody>, [Entry])] = [
            ("valid", single, entries((a, aliceSignature))),
            ("valid-two-signers", both, entries((a, sign(both, alice)), (bob.publicKey, sign(both, bob)))),
            ("valid-two-signers-unsorted", both, entries((bob.publicKey, sign(both, bob)), (a, sign(both, alice)))),
            ("signature-bit-flipped", single, entries((a, flipped))),
            ("signature-uppercase", single, entries((a, aliceSignature.uppercased()))),
            ("signature-0x", single, entries((a, "0x" + aliceSignature))),
            ("signature-0X", single, entries((a, "0X" + aliceSignature))),
            ("signature-0x-uppercase", single, entries((a, "0x" + aliceSignature.uppercased()))),
            ("signature-plus-sign", single, entries((a, signed(aliceSignature, "+")!))),
            ("signature-minus-zero", single, entries((a, signed(aliceSignature, "-", requiringZeroPair: true)!))),
            ("signature-odd-length", single, entries((a, String(aliceSignature.dropLast())))),
            ("signature-63-bytes", single, entries((a, String(aliceSignature.dropLast(2))))),
            ("signature-65-bytes", single, entries((a, aliceSignature + "00"))),
            ("signature-empty", single, entries((a, ""))),
            ("signature-space", single, entries((a, " " + aliceSignature.dropFirst()))),
            ("signature-non-ascii", single, entries((a, "é" + aliceSignature.dropFirst()))),
            ("signature-fullwidth-digit", single, entries((a, "０" + aliceSignature.dropFirst()))),
            ("signature-crlf", single, entries((a, "\r\n" + aliceSignature.dropFirst(2)))),
            ("signature-combining-mark", single, entries((a, String(aliceSignature.prefix(1)) + "\u{301}" + aliceSignature.dropFirst()))),
            ("key-uppercase", single, entries((a.uppercased(), aliceSignature))),
            ("key-0x", single, entries(("0x" + a, aliceSignature))),
            ("key-0X", single, entries(("0X" + a, aliceSignature))),
            ("key-non-minimal-varint", single, entries(("ed8100" + keyBytes, aliceSignature))),
            ("key-secp256k1-code", single, entries(("e701" + keyBytes, aliceSignature))),
            ("key-unregistered-code", single, entries(("01" + keyBytes, aliceSignature))),
            ("key-bare-32-bytes", single, entries((keyBytes, aliceSignature))),
            ("key-truncated", single, entries((String(a.dropLast(2)), aliceSignature))),
            ("key-extended", single, entries((a + "00", aliceSignature))),
            ("key-odd-length", single, entries((String(a.dropLast()), aliceSignature))),
            ("key-empty", single, entries(("", aliceSignature))),
            ("key-non-hex", single, entries(("zz" + a.dropFirst(2), aliceSignature))),
            ("key-non-ascii", single, entries(("é" + a.dropFirst(1), aliceSignature))),
            ("duplicate-key-spellings", single, entries((a, aliceSignature), (a.uppercased(), aliceSignature))),
            ("duplicate-entry", single, entries((a, aliceSignature), (a, aliceSignature))),
            ("signed-by-the-wrong-key", single, entries((bob.publicKey, sign(single, bob)))),
            ("missing-a-declared-signer", both, entries((a, sign(both, alice)))),
            ("an-undeclared-signer", single, entries((a, aliceSignature), (bob.publicKey, sign(single, bob)))),
            ("no-signatures", single, []),
            ("signature-over-another-body", body(signers: [alice], amount: 9), entries((a, aliceSignature))),
        ]
        if let plusKey = signed(keyBytes, "+") {
            cases.append(("key-plus-sign", single, entries(("ed01" + plusKey, aliceSignature))))
        }
        return cases
    }

    static let corpusName = "transaction-encoding-differential.json"

    func testCorpusConclusionsMatchLattice57() async throws {
        let inputs: [(name: String, body: HeaderImpl<TransactionBody>, input: [Entry])]
        if GoldenFile.isRegenerating {
            inputs = Self.freshInputs()
        } else {
            let data = try XCTUnwrap(
                FileManager.default.contents(atPath: GoldenFile.url(Self.corpusName).path),
                "missing golden \(Self.corpusName)"
            )
            let golden = try JSONDecoder().decode(Corpus.self, from: data)
            // The bodies are rebuilt and checked against the file: only the
            // signatures are read from it.
            let bodies = Dictionary(uniqueKeysWithValues: Self.freshInputs(signing: false).map { ($0.name, $0.body) })
            inputs = try golden.records.map { record in
                (record.name, try XCTUnwrap(bodies[record.name], record.name), record.input)
            }
        }

        let fetcher = StorableFetcher()
        let genesis = try await fundedGenesis(fetcher: fetcher)
        let genesisCID = try BlockHeader(node: genesis).rawCID
        var records: [Record] = []
        for (name, body, input) in inputs {
            records.append(try await record(name: name, body: body, input: input, genesis: genesis, fetcher: fetcher))
        }
        try GoldenFile.assert(Corpus(genesis: genesisCID, records: records), matches: Self.corpusName) { expected, actual in
            var lines = expected.genesis == actual.genesis ? [] : ["genesis: \(expected.genesis) vs \(actual.genesis)"]
            for (e, a) in zip(expected.records, actual.records) where e != a {
                let fields = Mirror(reflecting: e).children.map(\.label)
                let actualFields = Mirror(reflecting: a).children.map { "\($0.value)" }
                for (index, value) in Mirror(reflecting: e).children.map({ "\($0.value)" }).enumerated()
                where value != actualFields[index] {
                    lines.append("\(e.name).\(fields[index] ?? "?"): expected \(value), actual \(actualFields[index])")
                }
            }
            if expected.records.count != actual.records.count {
                lines.append("records: \(expected.records.count) vs \(actual.records.count)")
            }
            return lines
        }
    }

    private func fundedGenesis(fetcher: StorableFetcher) async throws -> Block {
        let premine = TransactionBody(
            accountActions: [
                AccountAction(owner: Reference57.createAddress(from: Self.alice.publicKey), delta: 500),
                AccountAction(owner: Reference57.createAddress(from: Self.bob.publicKey), delta: 500),
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [], nonce: 0, chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        return try await buildAndStoreGenesis(
            spec: ChainSpec.test(premine: 1),
            transactions: [Transaction(signatures: [:], body: try HeaderImpl(node: premine))],
            timestamp: 1_000,
            target: UInt256.max,
            fetcher: fetcher
        )
    }

    private func record(
        name: String,
        body: HeaderImpl<TransactionBody>,
        input: [Entry],
        genesis: Block,
        fetcher: StorableFetcher
    ) async throws -> Record {
        let bodyNode = try XCTUnwrap(body.node)
        let sorted = { (signatures: [String: String]) in
            signatures.sorted { $0.key < $1.key }.map { Entry(key: $0.key, value: $0.value) }
        }
        let map = Dictionary(input.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        let constructed = Transaction(signatures: map, body: body)

        let raw = RawTransaction(signatures: input, body: body)
        let rawHeader = try VolumeImpl<RawTransaction>(node: raw)
        let rawData = try XCTUnwrap(raw.toData())
        let decoded = Transaction(data: rawData)

        let chain = try await testChain(genesis: genesis, fetcher: fetcher)
        let preflight = await chain.preflightTransaction(constructed, fetcher: fetcher)
        let tip = chain.transactionPreflightTip(at: nil)
        let unpoliced = await TransactionPreflight.classify(
            constructed,
            tipCID: tip.cid,
            snapshot: tip.snapshot,
            chainPath: [DEFAULT_ROOT_DIRECTORY],
            fetcher: fetcher,
            checksPolicies: false
        )

        // Each encoding goes into the store under its own CID, as a peer
        // would serve it.
        let constructedHeader = try VolumeImpl<Transaction>(node: constructed)
        fetcher.store(rawCid: constructedHeader.rawCID, data: try XCTUnwrap(constructed.toData()))
        fetcher.store(rawCid: rawHeader.rawCID, data: rawData)
        fetcher.store(rawCid: body.rawCID, data: try XCTUnwrap(bodyNode.toData()))
        let block = try await carrying(
            try BlockBuilder.buildTransactionsDictionary([constructed]),
            bodies: [bodyNode], on: genesis, fetcher: fetcher
        )
        let rawDictionary = try HeaderImpl(
            node: try MerkleDictionaryImpl<VolumeImpl<Transaction>>()
                .inserting(key: "0", value: VolumeImpl<Transaction>(rawCID: rawHeader.rawCID))
        )
        let rawBlock = try await carrying(rawDictionary, bodies: [bodyNode], on: genesis, fetcher: fetcher)

        return Record(
            name: name,
            input: input,
            bodyCID: body.rawCID,
            constructed: sorted(constructed.signatures),
            constructedCID: constructedHeader.rawCID,
            constructedSignaturesValid: constructed.signaturesAreValid(),
            constructedSignaturesMatchSigners: constructed.signaturesMatchSigners(),
            addresses: input.map { CryptoUtils.createAddress(from: $0.key) },
            isAddressOfItsKey: input.map {
                CryptoUtils.isAddress(Reference57.createAddress(from: Reference57.normalizedPublicKey($0.key)), of: $0.key)
            },
            verifies: input.map {
                TransactionSigning.verify(bodyHeader: body, signature: $0.value, publicKeyHex: $0.key)
            },
            rawCID: rawHeader.rawCID,
            decoded: decoded.map { sorted($0.signatures) },
            decodedCID: try decoded.map { try VolumeImpl<Transaction>(node: $0).rawCID },
            decodedSignaturesValid: decoded.map { Transaction(signatures: $0.signatures, body: body).signaturesAreValid() },
            decodedSignaturesMatchSigners: decoded.map { Transaction(signatures: $0.signatures, body: body).signaturesMatchSigners() },
            preflight: "\(preflight.disposition)",
            preflightWithoutPolicies: "\(unpoliced.disposition)",
            block: try await verdict(block, fetcher: fetcher),
            rawBlock: try await verdict(rawBlock, fetcher: fetcher)
        )
    }

    /// A block on `genesis` carrying `transactions`, assembled as
    /// `buildAndStoreBlock` forges one: the builder judges no transaction.
    private func carrying(
        _ transactions: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>,
        bodies: [TransactionBody],
        on genesis: Block,
        fetcher: StorableFetcher
    ) async throws -> Block {
        let header = try await BlockBuilder.buildBlockWithTransition(
            previous: genesis, transactions: [], timestamp: 2_000, target: UInt256.max, fetcher: fetcher
        ).block
        let (postState, _) = try await BlockBuilder.computePostState(
            prevState: genesis.postState, transactionBodies: bodies, coinbase: nil, fetcher: fetcher
        )
        let block = Block(
            version: header.version, parent: header.parent, transactions: transactions,
            target: header.target, nextTarget: header.nextTarget, spec: header.spec,
            parentState: header.parentState, prevState: header.prevState,
            postState: postState, children: header.children,
            height: header.height, timestamp: header.timestamp,
            rewardRecipient: nil, nonce: header.nonce
        )
        // The block's own boundary and its state; its transactions are in
        // the store already.
        let blockHeader = try BlockHeader(node: block)
        try await blockHeader.store(paths: [[TRANSACTIONS_PROPERTY]: .list, [CHILDREN_PROPERTY]: .targeted], storer: fetcher)
        if let state = postState.node {
            try await LatticeStateHeader(node: state).storeRecursively(storer: fetcher)
        }
        return block
    }

    private func verdict(_ block: Block, fetcher: StorableFetcher) async throws -> String {
        let cid = try BlockHeader(node: block).rawCID
        do {
            let (valid, diff, _) = try await block.validateNexus(fetcher: fetcher)
            return "\(cid) \(valid ? "valid" : "invalid") \(diff.isEmpty ? "-" : "diff")"
        } catch {
            return "\(cid) throws \(String(reflecting: type(of: error)))"
        }
    }
}
