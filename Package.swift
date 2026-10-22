// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lattice",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Lattice",
            targets: ["Lattice"]),
        .library(name: "LatticePrimitives", targets: ["LatticePrimitives"]),
        .library(name: "LatticePoW", targets: ["LatticePoW"]),
        .library(name: "LatticeValidation", targets: ["LatticeValidation"]),
        .library(name: "LatticeProofs", targets: ["LatticeProofs"]),
        .library(name: "LatticeBlockTree", targets: ["LatticeBlockTree"]),
        .library(name: "LatticeImport", targets: ["LatticeImport"]),
        .executable(
            name: "LatticeDemo",
            targets: ["LatticeDemo"]),
        .executable(
            name: "lattice-determinism-check",
            targets: ["DeterminismCheck"]),
        .executable(
            name: "LatticeSim",
            targets: ["LatticeSim"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "4.0.0"),
        .package(url: "https://github.com/adalinxx/Multikey.git", from: "1.0.0"),
        .package(url: "https://github.com/adalinxx/cashew.git", exact: "5.0.2"),
        .package(url: "https://github.com/adalinxx/UInt256.git", from: "1.1.0"),
        .package(url: "https://github.com/swift-libp2p/swift-cid.git", from: "0.0.1"),
        .package(url: "https://github.com/swift-libp2p/swift-multicodec.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/JohnSundell/CollectionConcurrencyKit.git", from: "0.2.0"),
        // Exact: the policy engine decides verdicts, so an engine change is a consensus change.
        .package(url: "https://github.com/swiftwasm/WasmKit.git", exact: "0.2.2"),
    ],
    targets: [
        .target(
            name: "LatticePrimitives",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Multikey", package: "Multikey"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "CID", package: "swift-cid"),
                .product(name: "Multicodec", package: "swift-multicodec"),
                .product(name: "UInt256", package: "UInt256"),
                .product(name: "CollectionConcurrencyKit", package: "CollectionConcurrencyKit"),
            ]),
        .target(
            name: "LatticePoW",
            dependencies: [
                "LatticePrimitives",
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .target(
            name: "LatticeValidation",
            dependencies: [
                "LatticePrimitives",
                "LatticePoW",
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Multikey", package: "Multikey"),
                .product(name: "CollectionConcurrencyKit", package: "CollectionConcurrencyKit"),
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmParser", package: "WasmKit"),
            ]),
        .target(
            name: "LatticeProofs",
            dependencies: [
                "LatticePrimitives",
                "LatticePoW",
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .target(
            name: "LatticeBlockTree",
            dependencies: [
                "LatticePrimitives",
                "LatticePoW",
                .product(name: "cashew", package: "cashew"),
                .product(name: "CID", package: "swift-cid"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .target(
            name: "LatticeImport",
            dependencies: [
                "LatticePrimitives",
                "LatticePoW",
                "LatticeValidation",
                "LatticeProofs",
                "LatticeBlockTree",
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
                .product(name: "WasmKit", package: "WasmKit"),
            ]),
        // Umbrella: re-exports the six modules so `import Lattice` keeps working.
        .target(
            name: "Lattice",
            dependencies: [
                "LatticePrimitives",
                "LatticePoW",
                "LatticeValidation",
                "LatticeProofs",
                "LatticeBlockTree",
                "LatticeImport",
            ]),
        .executableTarget(
            name: "LatticeDemo",
            dependencies: ["Lattice"]),
        // — shared golden-vector source of truth, imported by
        // both the XCTest suite (macOS) and the determinism executable (Linux).
        .target(
            name: "DeterminismGoldens",
            dependencies: [
                "Lattice",
                .product(name: "WasmParser", package: "WasmKit"),
                .product(name: "WAT", package: "WasmKit"),
            ]),
        // — Linux host-determinism gate (no XCTest).
        .executableTarget(
            name: "DeterminismCheck",
            dependencies: ["DeterminismGoldens"]),
        // Wave-4: the consensus simulator / adversarial-scenario harness lives
        // outside the Lattice library product, so simulation-only code never
        // ships in the consensus library. Drives Lattice through its public
        // (simulation-facing) API only.
        .target(
            name: "LatticeSimulation",
            dependencies: ["Lattice"]),
        .executableTarget(
            name: "LatticeSim",
            dependencies: ["LatticeSimulation"]),
        // Restore-replay benchmark (not a product): `swift run -c release
        // LatticeReplayBench <blocks>`.
        .executableTarget(
            name: "LatticeReplayBench",
            dependencies: [
                "LatticePrimitives",
                "LatticePoW",
                "LatticeBlockTree",
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .testTarget(
            name: "LatticeTests",
            dependencies: [
                "Lattice",
                "LatticePrimitives",
                "LatticePoW",
                "LatticeValidation",
                "LatticeProofs",
                "LatticeBlockTree",
                "LatticeImport",
                "LatticeSimulation",
                "DeterminismGoldens",
                .product(name: "CID", package: "swift-cid"),
                .product(name: "WasmParser", package: "WasmKit"),
                .product(name: "WAT", package: "WasmKit"),
            ],
            // Checked-in golden expectations, read from the source tree via
            // `#filePath` (see GoldenFile.swift), not as bundle resources.
            exclude: ["Goldens"])
    ]
)
