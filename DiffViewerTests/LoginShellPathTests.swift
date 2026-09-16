import Foundation
import Testing

@testable import DiffViewer

/// Drives the resolver with stand-in shells, because the two failures that matter cannot be
/// reproduced with the developer's own shell: a login shell that never exits, and one that
/// refuses to die when asked. Neither may keep the app waiting.
@Suite struct LoginShellPathTests {
    /// An executable `sh` script in a directory of its own, to be passed as the shell.
    private func makeShell(_ body: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DiffViewerLoginShell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("shell")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func remove(_ script: URL) {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
    }

    /// Polls pgrep to verify a process matching the pattern has exited.
    private func expectGone(_ pattern: String) async throws {
        var gone = false
        for attempt in 0..<40 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(200)) }
            let found = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-f", pattern])
            if found.status == 1 {
                gone = true
                break
            } else if found.status != 0 {
                Issue.record("pgrep failed: \(found.stderrString)")
                break
            }
        }
        #expect(gone, "process matching \(pattern) outlived SIGKILL")
    }

    /// Startup files that greet the user are ordinary, so only what the markers enclose can
    /// be taken for the PATH.
    @Test func aChattyLoginShellYieldsOnlyThePath() async throws {
        let shell = try makeShell("printf 'Welcome\\n'; exec /bin/sh \"$@\"")
        defer { remove(shell) }

        let resolved = await LoginShellPath.resolve(shell: shell.path, timeout: .seconds(10))

        let path = try #require(resolved)
        #expect(!path.isEmpty)
        #expect(!path.contains("Welcome"), "\(path)")
        #expect(!path.contains("\n"), "\(path)")
    }

    /// A background child keeps stdout open while the shell waits for it, so the shell
    /// never exits and only the deadline can end the run.
    @Test func aShellHoldingItsOutputPipeOpenTimesOut() async throws {
        let shell = try makeShell("sleep 30 & wait")
        defer { remove(shell) }

        let elapsed = await ContinuousClock().measure {
            let resolved = await LoginShellPath.resolve(shell: shell.path, timeout: .milliseconds(300))
            #expect(resolved == nil)
        }
        #expect(elapsed < .seconds(15), "\(elapsed)")
    }

    /// The shell's own exit is the answer; waiting for end of file would time out here,
    /// because the background child holds stdout well past the deadline. A reader that
    /// waited for EOF would hit the 3 s deadline first.
    @Test func aShellThatExitsWhileAChildHoldsThePipeStillAnswers() async throws {
        let shell = try makeShell("sleep 5 & exec /bin/sh \"$@\"")
        defer { remove(shell) }

        let resolved = await LoginShellPath.resolve(shell: shell.path, timeout: .seconds(3))

        let path = try #require(resolved)
        #expect(!path.isEmpty)
    }

    /// A chatty startup file must not cost an unbounded buffer or make the app wait the
    /// full deadline.
    @Test func aShellThatFloodsStdoutIsAbandoned() async throws {
        let shell = try makeShell("head -c 2097152 /dev/zero; exec /bin/sh \"$@\"")
        defer { remove(shell) }

        let elapsed = await ContinuousClock().measure {
            let resolved = await LoginShellPath.resolve(shell: shell.path, timeout: .seconds(10))
            #expect(resolved == nil)
        }
        #expect(elapsed < .seconds(5), "\(elapsed)")
    }

    /// SIGTERM is a request; the SIGKILL that follows it a second later is not.
    @Test func aShellThatIgnoresTerminationIsKilled() async throws {
        let shell = try makeShell("trap \"\" TERM; sleep 3071")
        defer { remove(shell) }

        let elapsed = await ContinuousClock().measure {
            let resolved = await LoginShellPath.resolve(shell: shell.path, timeout: .milliseconds(300))
            #expect(resolved == nil)
        }
        #expect(elapsed < .seconds(15), "\(elapsed)")

        try await expectGone(shell.path)
    }

    /// The shell dies on SIGTERM, so the later SIGKILL must still reach the group; that
    /// only works while the shell's zombie is unreaped.
    @Test func aChildThatIgnoresTerminationIsStillKilled() async throws {
        let shell = try makeShell("sh -c 'trap \"\" TERM; sleep 3072' & wait")
        defer { remove(shell) }

        let resolved = await LoginShellPath.resolve(shell: shell.path, timeout: .milliseconds(300))
        #expect(resolved == nil)

        try await expectGone("sleep 3072")
    }

    /// A shell that exits without an answer may leave startup-file children running,
    /// and giving up on it must take the group down.
    @Test func aFailedShellTakesItsChildrenWithIt() async throws {
        let shell = try makeShell("sleep 3073 & exit 1")
        defer { remove(shell) }

        let elapsed = await ContinuousClock().measure {
            let resolved = await LoginShellPath.resolve(shell: shell.path, timeout: .seconds(3))
            #expect(resolved == nil)
        }
        #expect(elapsed < .seconds(2), "\(elapsed)")

        try await expectGone("sleep 3073")
    }
}
