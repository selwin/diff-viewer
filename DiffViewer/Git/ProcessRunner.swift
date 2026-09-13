import Foundation
import os

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

/// Counts subprocesses between a successful launch and their exit, and remembers
/// the most that were alive at once. An observation for measurement, not a limit.
final class ProcessGauge: Sendable {
    struct Reading: Sendable, Equatable {
        var running = 0
        var peak = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: Reading())

    var reading: Reading { state.withLock { $0 } }

    fileprivate func launched() {
        state.withLock {
            $0.running += 1
            $0.peak = max($0.peak, $0.running)
        }
    }

    fileprivate func exited() {
        state.withLock { $0.running -= 1 }
    }
}

/// Runs a subprocess to completion off the main thread, draining stdout and stderr
/// concurrently so large outputs never deadlock on a full pipe.
enum ProcessRunner {
    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        qualityOfService: QualityOfService = .userInitiated,
        gauge: ProcessGauge? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qualityOfService.dispatchQoS).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectory
                process.qualityOfService = qualityOfService
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
                gauge?.launched()

                let group = DispatchGroup()
                nonisolated(unsafe) var stderrData = Data()
                group.enter()
                DispatchQueue.global(qos: qualityOfService.dispatchQoS).async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                gauge?.exited()
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

private extension QualityOfService {
    var dispatchQoS: DispatchQoS.QoSClass {
        switch self {
        case .userInteractive: .userInteractive
        case .userInitiated: .userInitiated
        case .utility: .utility
        case .background: .background
        case .default: .default
        @unknown default: .default
        }
    }
}
