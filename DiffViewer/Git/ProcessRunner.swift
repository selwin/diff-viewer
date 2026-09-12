import Foundation

struct ProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessError: Error, LocalizedError {
    case failed(command: String, status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case let .failed(command, status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command) exited with status \(status)" + (detail.isEmpty ? "" : ": \(detail)")
        }
    }
}

/// Runs a subprocess to completion off the main thread, draining stdout and stderr
/// concurrently so large outputs never deadlock on a full pipe.
enum ProcessRunner {
    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectory
                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment { env[key] = value }
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let group = DispatchGroup()
                nonisolated(unsafe) var stderrData = Data()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                group.wait()

                continuation.resume(returning: ProcessResult(
                    stdout: stdoutData,
                    stderr: stderrData,
                    status: process.terminationStatus
                ))
            }
        }
    }

    /// Like `run`, but throws if the process exits non-zero.
    static func check(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) async throws -> ProcessResult {
        let result = try await run(executable, arguments: arguments, currentDirectory: currentDirectory, environment: environment)
        guard result.status == 0 else {
            let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
            throw ProcessError.failed(command: command, status: result.status, stderr: result.stderrString)
        }
        return result
    }
}
