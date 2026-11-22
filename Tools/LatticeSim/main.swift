import Foundation
import LatticeSimulation

@main
struct LatticeSimCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let seed = try parseSeed(args) ?? LatticeConsensusSimulator.defaultSeed

            if args.contains("--adversarial") {
                let report = await LatticeConsensusSimulator.runAdversarialReport(seed: seed)
                let json = try LatticeConsensusSimulator.encodeAdversarialJSON(report)
                let markdown = LatticeConsensusSimulator.renderAdversarialMarkdown(report)
                if let outDir = outputDir(args) {
                    let fm = FileManager.default
                    try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
                    try json.write(to: URL(fileURLWithPath: outDir + "/adversarial-report.json"))
                    try Data(markdown.utf8).write(to: URL(fileURLWithPath: outDir + "/adversarial-report.md"))
                } else {
                    FileHandle.standardOutput.write(Data(markdown.utf8))
                }
                return
            }

            // Regenerate the committed adversarial report so a plain
            // `swift run LatticeSim --seed 42` reproduces the checked-in artifact.
            let report = await LatticeConsensusSimulator.runAdversarialReport(seed: seed)
            let reportDir = outputDir(args) ?? "docs/consensus"
            let fm = FileManager.default
            try fm.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
            try LatticeConsensusSimulator.encodeAdversarialJSON(report)
                .write(to: URL(fileURLWithPath: reportDir + "/adversarial-report.json"))
            try Data(LatticeConsensusSimulator.renderAdversarialMarkdown(report).utf8)
                .write(to: URL(fileURLWithPath: reportDir + "/adversarial-report.md"))

            let traces = await LatticeConsensusSimulator.runDefaultScenarios(seed: seed)
            let data = try LatticeConsensusSimulator.encodeJSON(traces)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Foundation.exit(2)
        }
    }

    private static func parseSeed(_ args: [String]) throws -> UInt64? {
        guard let idx = args.firstIndex(of: "--seed"), idx + 1 < args.count else {
            if args.contains("--seed") {
                throw LatticeSimCLIError.invalidSeed("<missing>")
            }
            return nil
        }
        let raw = args[idx + 1]
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            guard let seed = UInt64(raw.dropFirst(2), radix: 16) else {
                throw LatticeSimCLIError.invalidSeed(raw)
            }
            return seed
        }
        guard let seed = UInt64(raw, radix: 10) else {
            throw LatticeSimCLIError.invalidSeed(raw)
        }
        return seed
    }

    private static func outputDir(_ args: [String]) -> String? {
        guard let idx = args.firstIndex(of: "--out"), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}

enum LatticeSimCLIError: Error, CustomStringConvertible {
    case invalidSeed(String)

    var description: String {
        switch self {
        case .invalidSeed(let raw):
            return "invalid --seed value: \(raw)"
        }
    }
}
