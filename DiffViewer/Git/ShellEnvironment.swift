import Foundation

/// Captures exported variables from a short-lived interactive login shell after changing to the
/// repository root. Prompt-only and terminal-dependent setup may differ: direnv's bash hook, for
/// one, lives in `PROMPT_COMMAND`, which never runs under `-c`. zsh is the supported shell.
///
/// Startup files run in the shell's inherited directory, before the `cd`, so per-directory
/// setup such as a `chpwd` hook that activates `.venv` only sees the repository through it.
enum ShellEnvironment {
    /// The same bound as `LoginShellPath`: an environment is never worth an unbounded buffer.
    private static let outputLimit = 1 << 20

    /// Variables that describe the capturing shell rather than the user's setup.
    private static let droppedKeys: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "DIFFVIEWER_SHELL_DIRECTORY"]

    /// Runs `shell -l -i -c <script>` in `directory` and returns what `env` prints there; nil
    /// when the shell or the `cd` fails, the framing is incomplete, or the deadline passes.
    static func resolve(shell: String, directory: URL, timeout: Duration) async -> [String: String]? {
        // Fresh tokens per run, so nothing a startup file prints can pass for the framing.
        let open = "DiffViewer-env-open-" + UUID().uuidString
        let close = "DiffViewer-env-close-" + UUID().uuidString
        // The directory travels in the environment so the script never has to quote a path.
        // `builtin` keeps a user's `cd` alias or function out of it; zsh still runs `chpwd`.
        let script = """
            builtin cd -- "$DIFFVIEWER_SHELL_DIRECTORY" && /usr/bin/printf '\\0%s\\0' \(open) \
            && /usr/bin/env -0 && /usr/bin/printf '%s\\0' \(close)
            """
        guard
            let run = ShellRun<[String: String]>.spawn(
                shell: shell, arguments: ["-l", "-i", "-c", script],
                extraEnvironment: ["DIFFVIEWER_SHELL_DIRECTORY": directory.path])
        else { return nil }
        return await run.result(timeout: timeout, outputLimit: outputLimit) { data in
            interpret(data, open: open, close: close)
        }
    }

    /// The NUL-separated `KEY=VALUE` records between the `open` and `close` records. The
    /// leading NUL puts any banner a startup file printed into a record of its own. The `close`
    /// record counts only once its NUL arrives: until then it may be a prefix of the token.
    static func interpret(_ data: Data, open: String, close: String) -> ShellOutput<[String: String]> {
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        guard let start = records.firstIndex(where: { $0.elementsEqual(open.utf8) }),
            let end = records[(start + 1)...].firstIndex(where: { $0.elementsEqual(close.utf8) }),
            end < records.endIndex - 1
        else { return .incomplete }

        var environment: [String: String] = [:]
        for record in records[(start + 1)..<end] {
            // A variable that is not UTF-8 cannot be handed on faithfully, so the whole
            // capture is refused rather than passed on with replacement characters.
            guard let text = String(validating: record, as: UTF8.self),
                let equals = text.firstIndex(of: "="), equals != text.startIndex
            else { return .invalid }
            let key = String(text[..<equals])
            guard !droppedKeys.contains(key) else { continue }
            environment[key] = String(text[text.index(after: equals)...])
        }
        return environment.isEmpty ? .invalid : .valid(environment)
    }
}
