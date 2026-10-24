import Foundation
import Testing

@testable import DiffViewer

/// Parses framed `env -0` output, and drives the resolver with stand-in shells that run zsh
/// against startup files of their own, so the developer's dotfiles never take part.
@Suite struct ShellEnvironmentTests {
    private let open = "OPEN-token"
    private let close = "CLOSE-token"

    /// `env -0` output framed the way the resolver's script frames it.
    private func framed(_ records: [String], banner: String = "") -> Data {
        var data = Data(banner.utf8)
        data.append(0)
        for record in [open] + records + [close] {
            data.append(contentsOf: Array(record.utf8))
            data.append(0)
        }
        return data
    }

    /// An executable `sh` script in a directory of its own, to be passed as the shell.
    private func makeShell(_ body: String) throws -> URL {
        let directory = try makeDirectory("DiffViewerShellEnvironment")
        let script = directory.appendingPathComponent("shell")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// A stand-in shell that runs zsh with `zshrc` as its only user startup file.
    private func makeZsh(zshrc: String = "", prelude: String = "") throws -> URL {
        let shell = try makeShell("")
        let zdotdir = shell.deletingLastPathComponent()
        try Data(zshrc.utf8).write(to: zdotdir.appendingPathComponent(".zshrc"))
        try Data("#!/bin/sh\n\(prelude)ZDOTDIR='\(zdotdir.path)' exec /bin/zsh \"$@\"\n".utf8).write(to: shell)
        return shell
    }

    private func makeDirectory(_ prefix: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func remove(_ script: URL) {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
    }

    @Test func interpretReadsOnlyTheFramedRecords() throws {
        let tricky = "a=b\nline two \(open) \(close)"
        let data = framed(
            [
                "TRICKY=\(tricky)", "HOME=/Users/me", "PWD=/x", "OLDPWD=/y", "SHLVL=2", "_=/usr/bin/env",
                "DIFFVIEWER_SHELL_DIRECTORY=/x",
            ], banner: "Welcome\n")

        guard case let .valid(environment) = ShellEnvironment.interpret(data, open: open, close: close) else {
            Issue.record("expected a valid environment")
            return
        }
        #expect(environment == ["TRICKY": tricky, "HOME": "/Users/me"])
    }

    @Test func interpretRejectsIncompleteAndMalformedOutput() {
        var truncated = framed(["HOME=/Users/me"])
        truncated.removeLast(close.utf8.count + 1)
        var notUTF8 = Data([0] + Array(open.utf8) + [0] + Array("BAD=".utf8) + [0xFF, 0])
        notUTF8.append(contentsOf: Array(close.utf8) + [0])

        let cases: [(Data, String)] = [
            (truncated, "incomplete"),
            (framed(["HOME=/Users/me", "NOEQUALS"]), "invalid"),
            (framed(["=value"]), "invalid"),
            (notUTF8, "invalid"),
            (framed(["PWD=/x", "SHLVL=1"]), "invalid"),
        ]
        for (data, expected) in cases {
            let result = ShellEnvironment.interpret(data, open: open, close: close)
            switch (result, expected) {
            case (.incomplete, "incomplete"), (.invalid, "invalid"): break
            default: Issue.record("expected \(expected), got \(result)")
            }
        }
    }

    /// The closing token counts only once its NUL arrives, since a read may end mid-token.
    @Test func interpretWaitsForTheClosingNUL() {
        let complete = framed(["HOME=/Users/me"])
        let withoutNUL = complete.dropLast()
        let midToken = complete.prefix(complete.count - 4)

        let cases: [(Data, String)] = [
            (Data(withoutNUL), "incomplete"),
            (Data(midToken), "incomplete"),
            (complete, "valid"),
            (framed(["HOME=/Users/me", ""]), "invalid"),
        ]
        for (data, expected) in cases {
            let result = ShellEnvironment.interpret(data, open: open, close: close)
            switch (result, expected) {
            case (.incomplete, "incomplete"), (.valid, "valid"), (.invalid, "invalid"): break
            default: Issue.record("expected \(expected), got \(result)")
            }
        }
    }

    /// The point of the resolver: a `chpwd` hook sees the repository root it changes into.
    @Test func aChpwdHookSeesTheRepositoryRoot() async throws {
        let marked = try makeDirectory("DiffViewerMarked")
        let other = try makeDirectory("DiffViewerOther")
        defer {
            try? FileManager.default.removeItem(at: marked)
            try? FileManager.default.removeItem(at: other)
        }
        let shell = try makeZsh(
            zshrc: """
                autoload -U add-zsh-hook
                f() { if [[ ${PWD:t} == '\(marked.lastPathComponent)' ]]; then export DIFFVIEWER_TEST_SENTINEL=yes; fi }
                add-zsh-hook chpwd f
                """)
        defer { remove(shell) }

        let inMarked = await ShellEnvironment.resolve(shell: shell.path, directory: marked, timeout: .seconds(10))
        let inOther = await ShellEnvironment.resolve(shell: shell.path, directory: other, timeout: .seconds(10))

        #expect(try #require(inMarked)["DIFFVIEWER_TEST_SENTINEL"] == "yes")
        #expect(try #require(inOther)["DIFFVIEWER_TEST_SENTINEL"] == nil)
    }

    /// The script's `cd` is the builtin, so a startup file's own `cd` cannot send it elsewhere.
    @Test func aCdFunctionDoesNotRedirectTheShell() async throws {
        let marked = try makeDirectory("DiffViewerMarked")
        defer { try? FileManager.default.removeItem(at: marked) }
        let shell = try makeZsh(
            zshrc: """
                autoload -U add-zsh-hook
                f() { if [[ ${PWD:t} == '\(marked.lastPathComponent)' ]]; then export DIFFVIEWER_TEST_SENTINEL=yes; fi }
                add-zsh-hook chpwd f
                cd() { builtin cd / }
                """)
        defer { remove(shell) }

        let resolved = await ShellEnvironment.resolve(shell: shell.path, directory: marked, timeout: .seconds(10))
        #expect(try #require(resolved)["DIFFVIEWER_TEST_SENTINEL"] == "yes")
    }

    @Test func completeFramingFromAFailedShellYieldsNothing() async throws {
        // Runs the resolver's whole script, then fails anyway.
        let shell = try makeShell("eval \"$4\"; exit 3")
        defer { remove(shell) }
        let directory = try makeDirectory("DiffViewerRoot")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await ShellEnvironment.resolve(shell: shell.path, directory: directory, timeout: .seconds(10)) == nil)
    }

    /// Malformed framing fails the run, and the failure takes the startup files' background
    /// children down with the shell.
    @Test func malformedCaptureKillsTheShellsChildren() async throws {
        let pidFile = try makeDirectory("DiffViewerPid").appendingPathComponent("pid")
        defer { try? FileManager.default.removeItem(at: pidFile.deletingLastPathComponent()) }
        // Drives the runner directly with this suite's tokens, rather than parsing the
        // resolver's fresh ones out of its script. The child keeps the pipe open, so only the
        // `.invalid` record can end the run before the deadline.
        let shell = try makeShell(
            """
            sleep 30 &
            echo $! > '\(pidFile.path)'
            /usr/bin/printf '\\0%s\\0NOEQUALS\\0%s\\0' '\(open)' '\(close)'
            exit 0
            """)
        defer { remove(shell) }

        let run = try #require(
            ShellRun<[String: String]>.spawn(shell: shell.path, arguments: [], extraEnvironment: [:]))
        var resolved: [String: String]?
        let elapsed = await ContinuousClock().measure {
            resolved = await run.result(timeout: .seconds(10), outputLimit: 1 << 20) { [open, close] data in
                ShellEnvironment.interpret(data, open: open, close: close)
            }
        }
        #expect(resolved == nil)
        // Ending well before the deadline is what proves `.invalid` ended the run, not a timeout.
        #expect(elapsed < .seconds(5), "\(elapsed)")

        let text = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        try #require(pid > 1)
        // Cleared the moment the child is gone, so a reused pid is never signalled.
        var stillOwned = true
        defer { if stillOwned { kill(pid, SIGKILL) } }
        for _ in 0..<60 {
            if kill(pid, 0) == -1, errno == ESRCH {
                stillOwned = false
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!stillOwned, "background child \(pid) outlived the failed run")
    }

    @Test func aDirectoryThatCannotBeEnteredYieldsNothing() async throws {
        let shell = try makeZsh()
        defer { remove(shell) }
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "missing-\(UUID().uuidString)")

        #expect(await ShellEnvironment.resolve(shell: shell.path, directory: missing, timeout: .seconds(10)) == nil)
    }

    /// The shell's exit with the closing token is the answer, even while a background child
    /// still holds stdout well past the deadline.
    @Test func aChildHoldingThePipeDoesNotDelayTheAnswer() async throws {
        let shell = try makeZsh(prelude: "sleep 30 & ")
        defer { remove(shell) }
        let directory = try makeDirectory("DiffViewerRoot")
        defer { try? FileManager.default.removeItem(at: directory) }

        var resolved: [String: String]?
        let elapsed = await ContinuousClock().measure {
            resolved = await ShellEnvironment.resolve(shell: shell.path, directory: directory, timeout: .seconds(10))
        }
        #expect(resolved?["HOME"] != nil)
        #expect(elapsed < .seconds(5), "\(elapsed)")
    }

    /// A shell that exits 0 after only the opening token has nothing more to send.
    @Test func truncatedFramingFailsWithoutWaitingForTheDeadline() async throws {
        // Runs the resolver's script only up to `env`, so just the opening token is printed.
        let shell = try makeShell("eval \"${4%%&& /usr/bin/env*}\"")
        defer { remove(shell) }
        let directory = try makeDirectory("DiffViewerRoot")
        defer { try? FileManager.default.removeItem(at: directory) }

        let elapsed = await ContinuousClock().measure {
            let resolved = await ShellEnvironment.resolve(
                shell: shell.path, directory: directory, timeout: .seconds(10))
            #expect(resolved == nil)
        }
        #expect(elapsed < .seconds(5), "\(elapsed)")
    }
}
