import Foundation
import Testing

@testable import DiffViewer

struct CommandEnvironmentTests {
    private func client(
        resolved: [String: String], inheritance: ProcessEnvironment.Inheritance = .inherit,
        overrides: [String: String] = [:]
    ) -> GitClient {
        GitClient(
            repoRoot: FileManager.default.temporaryDirectory, environment: overrides,
            resolveCommandEnvironment: { ProcessEnvironment(variables: resolved, inheritance: inheritance) })
    }

    @Test func gitDefaultsBeatResolvedAndOverridesBeatBoth() async throws {
        let resolved = ["LC_ALL": "en_US.UTF-8", "GIT_PAGER": "less", "FROM_SHELL": "1"]
        let plain = try await client(resolved: resolved).commandEnvironment()
        #expect(plain.variables["LC_ALL"] == "C")
        #expect(plain.variables["GIT_PAGER"] == "cat")
        #expect(plain.variables["FROM_SHELL"] == "1")

        let overridden = try await client(resolved: resolved, overrides: ["LC_ALL": "de_DE", "FROM_SHELL": "2"])
            .commandEnvironment()
        #expect(overridden.variables["LC_ALL"] == "de_DE")
        #expect(overridden.variables["FROM_SHELL"] == "2")
    }

    @Test func remoteEnvironmentDisablesPromptsWhateverIsResolved() async throws {
        let environment = try await client(resolved: ["GIT_TERMINAL_PROMPT": "1"]).remoteEnvironment()
        #expect(environment.variables["GIT_TERMINAL_PROMPT"] == "0")
    }

    @Test func inheritanceIsPassedThrough() async throws {
        let replaced = try await client(resolved: [:], inheritance: .replace)
        #expect(try await replaced.commandEnvironment().inheritance == .replace)
        #expect(try await replaced.remoteEnvironment().inheritance == .replace)
        #expect(try await client(resolved: [:]).commandEnvironment().inheritance == .inherit)
    }

    @Test func replaceHandsTheChildOnlyTheGivenVariables() async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
            environment: ProcessEnvironment(variables: ["DIFFVIEWER_PROBE": "1"], inheritance: .replace))
        #expect(result.stdoutString.contains("DIFFVIEWER_PROBE=1"))
        #expect(!result.stdoutString.contains("HOME="))
    }

    /// The captured environment replaces the app's. HOME is what the test process always has,
    /// so a regression to `.inherit` would leak it into the hook and fail the test.
    @Test func capturedEnvironmentReplacesTheAppsInAHook() async throws {
        try #require(ProcessInfo.processInfo.environment["HOME"] != nil)

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DiffViewerCommandEnvironment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // A zsh whose only startup file unsets HOME.
        let zdotdir = scratch.appendingPathComponent("zdotdir", isDirectory: true)
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        try Data("unset HOME\n".utf8).write(to: zdotdir.appendingPathComponent(".zshrc"))
        let shell = scratch.appendingPathComponent("shell")
        try Data("#!/bin/sh\nZDOTDIR='\(zdotdir.path)' exec /bin/zsh \"$@\"\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)

        let repo = try await committedRepo(["file.txt": "main\n"])
        try await repo.git(["checkout", "-b", "side"])
        try await repo.git(["checkout", "main"])
        let root = RepositoryRoot(repo.url).url

        let configured = try? await repo.git(["config", "core.hooksPath"])
        let hooks =
            configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, relativeTo: root) }
            ?? root.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let probe = scratch.appendingPathComponent("probe.txt")
        let hook = hooks.appendingPathComponent("post-checkout")
        try Data("#!/bin/sh\nprintf '%s\\n' \"${HOME-unset}\" > '\(probe.path)'\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let cache = RepositoryShellEnvironmentCache(
            resolve: { await ShellEnvironment.resolve(shell: shell.path, directory: $0, timeout: .seconds(10)) },
            fallback: {
                Issue.record("the shell's environment should have been captured")
                return ProcessEnvironment(variables: [:], inheritance: .inherit)
            })
        let client = GitClient(
            repoRoot: root, environment: GitCommandTests.Repo.environment,
            resolveCommandEnvironment: { try await cache.environment(for: root) })

        try await client.switchBranch(to: "side")

        try #require(FileManager.default.fileExists(atPath: probe.path), "the post-checkout hook did not run")
        let recorded = try String(contentsOf: probe, encoding: .utf8)
        #expect(recorded.trimmingCharacters(in: .whitespacesAndNewlines) == "unset")
    }
}
