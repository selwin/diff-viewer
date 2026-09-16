import Foundation
import os

/// PATH as the user's login shell sets it, so hooks launched from a Finder-started app find
/// Homebrew tools. Reads login startup files only (`.zprofile`, `.bash_profile`, `.profile`);
/// a PATH set only in `.zshrc` is interactive-only and is not seen.
enum LoginShellPath {
    /// `["PATH": …]` once resolved, `[:]` when the shell failed or timed out.
    static let environment: @Sendable () async -> [String: String] = {
        guard let path = await resolved.value else { return [:] }
        return ["PATH": path]
    }

    /// Starts PATH resolution early to reduce the first commit's wait.
    static func warmUp() {
        _ = resolved
    }

    /// The one shared resolve: a login shell runs the user's startup files, which is slow
    /// enough to be worth doing once per launch.
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
    ///
    /// Spawns and owns the process itself rather than going through `ProcessRunner`, which
    /// reads stdout to EOF and reaps without coordinating with the deadline: a login shell
    /// that leaves a background child holding the pipe would never reach EOF.
    static func resolve(shell: String, timeout: Duration) async -> String? {
        let script = "printf \"\\n\(openMarker)%s\(closeMarker)\" \"$PATH\""
        guard let run = ShellRun.spawn(shell: shell, script: script) else { return nil }
        return await run.result(timeout: timeout)
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

    /// One spawned login shell. Owns its pid until it reaps it, under the same lock that
    /// gates signalling, so a signal can never reach a reused pid; and the shell leads its
    /// own process group, so a timeout takes the startup files' children down with it.
    ///
    /// `@unchecked Sendable` because all mutable state lives under `state`, reads are
    /// serialised on the source's queue, and the descriptor closes in the cancel handler.
    private final class ShellRun: @unchecked Sendable {
        /// Everything the reader, the waiter and the deadline share. The continuation lives
        /// here too: taking it out is what makes delivery exactly once.
        private struct State {
            var output = Data()
            var eof = false
            /// Set once `waitid` observes the exit, before any reap.
            var exitStatus: Int32?
            var continuation: CheckedContinuation<String?, Never>?
            var cleanup = Cleanup.undecided
            var reaped = false
            var deadline: Deadline?
        }

        /// The timeout's work item. `DispatchWorkItem` is not `Sendable`, and this one needs no
        /// checking: it is created once, handed to dispatch, and cancelled under the lock.
        private struct Deadline: @unchecked Sendable {
            let item: DispatchWorkItem
        }

        /// What happens to the process group once the answer is delivered.
        private enum Cleanup {
            case undecided
            case none
            case terminating
            case killed
        }

        /// What the shared state adds up to so far. `.wait` means someone still owes either
        /// the exit status or the rest of the output.
        private enum Outcome {
            case wait
            case done(String?)
        }

        private static let readQueue = DispatchQueue(label: "com.selwin.DiffViewer.LoginShellPath")

        private let pid: pid_t
        private let readFD: Int32
        private let source: DispatchSourceRead
        private let state = OSAllocatedUnfairLock(initialState: State())

        private init(pid: pid_t, readFD: Int32) {
            self.pid = pid
            self.readFD = readFD
            self.source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: Self.readQueue)
        }

        /// Launches `shell -l -c script` with stdout on a pipe and nothing else inherited;
        /// nil when the shell cannot be spawned.
        static func spawn(shell: String, script: String) -> ShellRun? {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { return nil }
            let readFD = fds[0]
            let writeFD = fds[1]

            var actions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else {
                close(readFD)
                close(writeFD)
                return nil
            }

            var attrs: posix_spawnattr_t?
            guard posix_spawnattr_init(&attrs) == 0 else {
                posix_spawn_file_actions_destroy(&actions)
                close(readFD)
                close(writeFD)
                return nil
            }

            /// Undoes the setup so far. Returns nil so a failed check can `return` it.
            func abandonSetup() -> ShellRun? {
                posix_spawnattr_destroy(&attrs)
                posix_spawn_file_actions_destroy(&actions)
                close(readFD)
                close(writeFD)
                return nil
            }

            // Every call is checked: a shell spawned with a half-built setup could inherit our
            // descriptors or land in our process group, which is worse than not spawning at all.
            // Its own process group is what a timeout signals, and CLOEXEC_DEFAULT keeps the
            // rest of the app's descriptors out of a shell that runs arbitrary startup files.
            guard posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
                posix_spawn_file_actions_adddup2(&actions, writeFD, 1) == 0,
                posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0,
                posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
                posix_spawnattr_setpgroup(&attrs, 0) == 0
            else { return abandonSetup() }

            let argv: [UnsafeMutablePointer<CChar>?] = [
                strdup(shell), strdup("-l"), strdup("-c"), strdup(script), nil,
            ]

            var pid: pid_t = 0
            let status = posix_spawn(&pid, shell, &actions, &attrs, argv, environ)

            for argument in argv { free(argument) }
            posix_spawnattr_destroy(&attrs)
            posix_spawn_file_actions_destroy(&actions)
            close(writeFD)

            guard status == 0 else {
                close(readFD)
                return nil
            }
            return ShellRun(pid: pid, readFD: readFD)
        }

        /// The PATH the shell printed, or nil once the deadline passes.
        func result(timeout: Duration) async -> String? {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                let deadline = Deadline(item: DispatchWorkItem { [self] in abandon() })
                state.withLock { state in
                    state.continuation = continuation
                    state.deadline = deadline
                }
                startReading()
                startWaiting()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds, execute: deadline.item)
            }
        }

        private func startReading() {
            source.setEventHandler { [self] in
                var buffer = [UInt8](repeating: 0, count: 64 << 10)
                let count = buffer.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { return }
                guard count > 0 else {
                    state.withLock { $0.eof = true }
                    source.cancel()
                    settle()
                    return
                }
                let chunk = Data(buffer[0..<count])
                let overflowed = state.withLock { state -> Bool in
                    state.output.append(chunk)
                    return state.output.count > LoginShellPath.outputLimit
                }
                // A shell that overflowed is still running and would block on a pipe nobody
                // drains once we stop reading, so it takes the same exit as the deadline.
                if overflowed { abandon() } else { settle() }
            }
            // Dispatch runs this after any in-flight event handler, which is what makes
            // closing the descriptor here safe.
            source.setCancelHandler { [self] in close(readFD) }
            source.resume()
        }

        /// Observes the exit without reaping: the zombie is what holds the pid, and the process
        /// group id with it, until every cleanup signal has been sent.
        private func startWaiting() {
            DispatchQueue.global().async { [self] in
                var info = siginfo_t()
                var observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
                while observed != 0, errno == EINTR {
                    observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
                }
                // Read out of the mutable locals here: the locked closure is `@Sendable`.
                let failed = observed != 0
                let status = info.si_code == CLD_EXITED ? info.si_status : -1
                state.withLock { state in
                    state.exitStatus = failed ? -1 : status
                    // A failure (ECHILD and the like) means someone else reaped it: the pid is
                    // no longer ours to signal, nor the group id ours to hold.
                    if failed { state.reaped = true }
                }
                settle()
                reapIfReady()
            }
        }

        /// Reaps the leader, but only once it has exited and nothing more will be signalled,
        /// because releasing the pid releases our claim on the group id. The exit is already
        /// observed, so `WNOHANG` finds the zombie at once and the lock is never held waiting.
        private func reapIfReady() {
            state.withLock { state in
                guard state.exitStatus != nil, !state.reaped else { return }
                guard state.cleanup == .none || state.cleanup == .killed else { return }
                var raw: Int32 = 0
                while waitpid(pid, &raw, WNOHANG) < 0, errno == EINTR {}
                state.reaped = true
            }
        }

        /// Signals the shell's whole process group, so children a startup file left behind go
        /// with it. The reap happens under this lock too, so an unreaped leader means the group
        /// id is still ours and the signal can never reach another process's group.
        private func signal(_ sig: Int32) {
            state.withLock { state in
                guard !state.reaped else { return }
                kill(-pid, sig)
            }
        }

        /// Gives up on the shell. The nil is the whole decision: `deliver` reads it as "take the
        /// group down" and holds the reap back until the last signal has been sent.
        private func abandon() {
            deliver(nil)
        }

        /// The pipe and the exit are observed on separate queues, in either order, so neither
        /// side decides on its own: whichever runs last settles it.
        private func settle() {
            let outcome = state.withLock { state -> Outcome in
                guard state.output.count <= LoginShellPath.outputLimit else { return .done(nil) }
                guard let status = state.exitStatus else { return .wait }
                guard status == 0 else { return .done(nil) }
                let text = String(decoding: state.output, as: UTF8.self)
                if text.contains(LoginShellPath.closeMarker) { return .done(LoginShellPath.path(in: text)) }
                // No closing marker yet: the rest of the output may still be in flight unless
                // the pipe is already at EOF. The deadline bounds the wait.
                return state.eof ? .done(nil) : .wait
            }
            if case let .done(value) = outcome { deliver(value) }
        }

        /// Answers the caller exactly once and, with the same decision, settles the group: an
        /// answer we accepted leaves the startup files' children alone, a nil takes the group
        /// down. Taking the continuation out is what makes both happen only once.
        private func deliver(_ value: String?) {
            let taken = state.withLock { state -> (CheckedContinuation<String?, Never>, Deadline?)? in
                guard let continuation = state.continuation else { return nil }
                state.continuation = nil
                state.cleanup = value == nil ? .terminating : .none
                let deadline = state.deadline
                state.deadline = nil
                return (continuation, deadline)
            }
            guard let (continuation, deadline) = taken else { return }
            continuation.resume(returning: value)
            // The answer is out: nothing wants more output, and nothing is left to time out.
            source.cancel()
            deadline?.item.cancel()
            if value == nil { terminateGroup() } else { reapIfReady() }
        }

        /// Takes the group down rather than leave it writing into a pipe nobody drains. The
        /// SIGKILL is what reaches anything that ignored the SIGTERM, so the leader is not
        /// reaped until then: its zombie is what keeps the group id ours in the meantime.
        private func terminateGroup() {
            signal(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                signal(SIGKILL)
                state.withLock { $0.cleanup = .killed }
                // A leader still running at this point is reaped by the waiter instead.
                reapIfReady()
            }
        }
    }
}

extension Duration {
    /// Seconds as a `Double`, for the `DispatchTime` arithmetic the deadline needs.
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
