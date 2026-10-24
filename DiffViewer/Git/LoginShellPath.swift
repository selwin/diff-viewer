import Foundation

/// PATH as the user's login shell sets it, so hooks launched from a Finder-started app find
/// Homebrew tools. Reads login startup files only (`.zprofile`, `.bash_profile`, `.profile`);
/// a PATH set only in `.zshrc` is interactive-only and is not seen. This is the fallback
/// when a repository's interactive shell environment can't be captured.
enum LoginShellPath {
    /// `["PATH": …]` once resolved, `[:]` when the shell failed or timed out.
    static let environment: @Sendable () async -> [String: String] = {
        guard let path = await resolved.value else { return [:] }
        return ["PATH": path]
    }

    /// The one shared resolve, started lazily on first use: a login shell runs the user's
    /// startup files, which is slow enough to be worth doing once per launch.
    private static let resolved = Task<String?, Never> {
        await resolve(shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", timeout: .seconds(5))
    }

    private static let openMarker = "<DiffViewer-PATH>"
    private static let closeMarker = "</DiffViewer-PATH>"

    /// A shell that writes this much has something other than a PATH to say, and the answer
    /// is never worth an unbounded buffer.
    private static let outputLimit = 1 << 20

    /// Runs `shell -l -c <script>` and returns the PATH between the markers; nil on a
    /// non-zero exit, missing markers, or the deadline.
    static func resolve(shell: String, timeout: Duration) async -> String? {
        let script = "printf \"\\n\(openMarker)%s\(closeMarker)\" \"$PATH\""
        guard let run = ShellRun<String>.spawn(shell: shell, arguments: ["-l", "-c", script], extraEnvironment: [:])
        else { return nil }
        return await run.result(timeout: timeout, outputLimit: outputLimit) { data in
            let text = String(decoding: data, as: UTF8.self)
            // Until the closing marker arrives, the rest of the output may still be in flight.
            guard text.contains(closeMarker) else { return .incomplete }
            return path(in: text).map { .valid($0) } ?? .invalid
        }
    }

    /// The text between the last opening marker and the following closing one; nil when a
    /// marker is missing or the PATH is empty. The last one wins because a login shell may
    /// print a banner of its own before it.
    private static func path(in text: String) -> String? {
        guard let open = text.range(of: openMarker, options: .backwards),
            let close = text.range(of: closeMarker, range: open.upperBound..<text.endIndex)
        else { return nil }
        let path = String(text[open.upperBound..<close.lowerBound])
        return path.isEmpty ? nil : path
    }
}
