import Foundation

/// difftastic `--display json` output for one file.
struct DifftFile: Decodable, Sendable {
    struct LinePair: Decodable, Sendable {
        let lhs: Line?
        let rhs: Line?
    }

    struct Line: Decodable, Sendable {
        let lineNumber: Int
        let changes: [Change]

        enum CodingKeys: String, CodingKey {
            case lineNumber = "line_number"
            case changes
        }
    }

    struct Change: Decodable, Sendable {
        /// UTF-8 byte offsets within the line.
        let start: Int
        let end: Int
        let content: String
        let highlight: String
    }

    let language: String
    let path: String
    let status: String
    let chunks: [[LinePair]]?

    var allPairs: [LinePair] { (chunks ?? []).flatMap { $0 } }
}

/// Token-level hints extracted from difftastic, keyed by 0-based line index.
struct DifftHints: Sendable {
    /// Lines difftastic paired with each other (both sides changed).
    var pairs: [(old: Int, new: Int)] = []
    /// UTF-8 byte ranges of changed tokens per old line.
    var oldChanges: [Int: [Range<Int>]] = [:]
    /// UTF-8 byte ranges of changed tokens per new line.
    var newChanges: [Int: [Range<Int>]] = [:]

    init() {}

    init(file: DifftFile) {
        for pair in file.allPairs {
            if let lhs = pair.lhs {
                let ranges = lhs.changes.filter { $0.end > $0.start }.map { $0.start..<$0.end }
                if !ranges.isEmpty { oldChanges[lhs.lineNumber, default: []] += ranges }
            }
            if let rhs = pair.rhs {
                let ranges = rhs.changes.filter { $0.end > $0.start }.map { $0.start..<$0.end }
                if !ranges.isEmpty { newChanges[rhs.lineNumber, default: []] += ranges }
            }
            if let lhs = pair.lhs, let rhs = pair.rhs {
                pairs.append((lhs.lineNumber, rhs.lineNumber))
            }
        }
    }
}

enum DifftRunner {
    enum Failure: Error, LocalizedError {
        case binaryNotFound
        case badOutput(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound: "The difft binary was not found in the app bundle or on PATH."
            case let .badOutput(detail): "Could not read difft output: \(detail)"
            }
        }
    }

    /// The bundled difft, falling back to common Homebrew locations.
    static let executable: URL? = {
        var candidates: [URL] = []
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(dir.appendingPathComponent("difft"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/difft"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/difft"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    /// Runs difft on the two texts, using `fileName` so language detection works.
    static func run(old: Data, new: Data, fileName: String, qualityOfService: QualityOfService = .userInitiated) async throws -> DifftFile {
        guard let executable else { throw Failure.binaryNotFound }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffViewer", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let safeName = fileName.isEmpty ? "file" : fileName
        let oldURL = dir.appendingPathComponent("old", isDirectory: true).appendingPathComponent(safeName)
        let newURL = dir.appendingPathComponent("new", isDirectory: true).appendingPathComponent(safeName)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try old.write(to: oldURL)
        try new.write(to: newURL)

        let result = try await ProcessRunner.run(
            executable,
            arguments: ["--display", "json", "--context", "0", "--color", "never", oldURL.path, newURL.path],
            environment: [
                "DFT_UNSTABLE": "yes",
                "DFT_BYTE_LIMIT": "8000000",
                "DFT_GRAPH_LIMIT": "6000000",
                "DFT_PARSE_ERROR_LIMIT": "5",
            ],
            qualityOfService: qualityOfService
        )
        guard result.status == 0 else {
            throw ProcessError.failed(command: "difft", status: result.status, stderr: result.stderrString)
        }
        do {
            return try JSONDecoder().decode(DifftFile.self, from: result.stdout)
        } catch {
            throw Failure.badOutput(error.localizedDescription)
        }
    }
}
