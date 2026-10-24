import Foundation
import os

/// What a shell's output adds up to so far, as judged by the caller of `ShellRun.result`.
enum ShellOutput<T: Sendable>: Sendable {
    /// Not the whole answer yet; worth waiting for only while the pipe is open.
    case incomplete
    case valid(T)
    /// Output that can never become an answer, so the run fails at once.
    case invalid
}

/// Shared by every run: generic types cannot hold stored static properties.
private let shellRunReadQueue = DispatchQueue(label: "com.selwin.DiffViewer.ShellRun")

/// One spawned shell that runs the user's startup files. Owns its pid until it reaps it,
/// under the same lock that gates signalling, so a signal can never reach a reused pid; and
/// the shell leads its own process group, so a timeout takes the startup files' children
/// down with it.
///
/// Spawns and owns the process itself rather than going through `ProcessRunner`, which reads
/// stdout to EOF and reaps without coordinating with the deadline: a startup file that leaves
/// a background child holding the pipe would never let it reach EOF.
///
/// `@unchecked Sendable` because all mutable state lives under `state`, reads are serialised
/// on the source's queue, and the descriptor closes in the cancel handler.
final class ShellRun<T: Sendable>: @unchecked Sendable {
    /// Everything the reader, the waiter and the deadline share. The continuation lives here
    /// too: taking it out is what makes delivery exactly once.
    private struct State {
        var output = Data()
        var eof = false
        /// Set once `waitid` observes the exit, before any reap.
        var exitStatus: Int32?
        var continuation: CheckedContinuation<T?, Never>?
        var interpret: (@Sendable (Data) -> ShellOutput<T>)?
        var outputLimit = Int.max
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

    /// What the shared state adds up to so far. `.wait` means someone still owes either the
    /// exit status or the rest of the output.
    private enum Outcome {
        case wait
        case done(T?)
    }

    private let pid: pid_t
    private let readFD: Int32
    private let source: DispatchSourceRead
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init(pid: pid_t, readFD: Int32) {
        self.pid = pid
        self.readFD = readFD
        self.source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: shellRunReadQueue)
    }

    /// Launches `shell arguments…` with stdout on a pipe and nothing else inherited, in the
    /// app's environment plus `extraEnvironment`; nil when the shell cannot be spawned.
    static func spawn(shell: String, arguments: [String], extraEnvironment: [String: String]) -> ShellRun? {
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

        let argv: [UnsafeMutablePointer<CChar>?] = ([shell] + arguments).map { strdup($0) } + [nil]
        let envp = environment(adding: extraEnvironment)

        var pid: pid_t = 0
        let status = posix_spawn(&pid, shell, &actions, &attrs, argv, envp)

        for argument in argv { free(argument) }
        for entry in envp { free(entry) }
        posix_spawnattr_destroy(&attrs)
        posix_spawn_file_actions_destroy(&actions)
        close(writeFD)

        guard status == 0 else {
            close(readFD)
            return nil
        }
        ProcessRunner.allProcesses.launched()
        return ShellRun(pid: pid, readFD: readFD)
    }

    /// The app's environment with `extra` laid over it, as a nil-terminated `envp`. Inherited
    /// entries are copied as raw bytes, so a value that is not UTF-8 passes through intact.
    private static func environment(adding extra: [String: String]) -> [UnsafeMutablePointer<CChar>?] {
        var entries: [UnsafeMutablePointer<CChar>?] = []
        var index = 0
        while let entry = environ[index] {
            let name = String(String(cString: entry).prefix { $0 != "=" })
            if extra[name] == nil { entries.append(strdup(entry)) }
            index += 1
        }
        for (name, value) in extra { entries.append(strdup("\(name)=\(value)")) }
        return entries + [nil]
    }

    /// What `interpret` makes of the output once the shell has exited with status 0; nil on
    /// any other exit, `.invalid` or `.incomplete` output, overflow, or the deadline.
    func result(
        timeout: Duration, outputLimit: Int, interpret: @escaping @Sendable (Data) -> ShellOutput<T>
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let deadline = Deadline(item: DispatchWorkItem { [self] in abandon() })
            state.withLock { state in
                state.continuation = continuation
                state.interpret = interpret
                state.outputLimit = outputLimit
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
                return state.output.count > state.outputLimit
            }
            // A shell that overflowed is still running and would block on a pipe nobody
            // drains once we stop reading, so it takes the same exit as the deadline.
            if overflowed { abandon() } else { settle() }
        }
        // Dispatch runs this after any in-flight event handler, which is what makes closing
        // the descriptor here safe.
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
            // Counted whether or not `waitid` succeeded: either way the shell is gone from our side.
            ProcessRunner.allProcesses.exited()
            // Read out of the mutable locals here: the locked closure is `@Sendable`.
            let failed = observed != 0
            let status = info.si_code == CLD_EXITED ? info.si_status : -1
            state.withLock { state in
                state.exitStatus = failed ? -1 : status
                // A failure (ECHILD and the like) means someone else reaped it: the pid is no
                // longer ours to signal, nor the group id ours to hold.
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

    /// Signals the shell's whole process group, so children a startup file left behind go with
    /// it. The reap happens under this lock too, so an unreaped leader means the group id is
    /// still ours and the signal can never reach another process's group.
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

    /// The pipe and the exit are observed on separate queues, in either order, so neither side
    /// decides on its own: whichever runs last settles it.
    private func settle() {
        let outcome = state.withLock { state -> Outcome in
            guard state.output.count <= state.outputLimit else { return .done(nil) }
            guard let status = state.exitStatus else { return .wait }
            guard status == 0, let interpret = state.interpret else { return .done(nil) }
            switch interpret(state.output) {
            case let .valid(value): return .done(value)
            case .invalid: return .done(nil)
            // The rest of the output may still be in flight unless the pipe is already at
            // EOF. The deadline bounds the wait.
            case .incomplete: return state.eof ? .done(nil) : .wait
            }
        }
        if case let .done(value) = outcome { deliver(value) }
    }

    /// Answers the caller exactly once and, with the same decision, settles the group: an
    /// answer we accepted leaves the startup files' children alone, a nil takes the group
    /// down. Taking the continuation out is what makes both happen only once.
    private func deliver(_ value: T?) {
        let taken = state.withLock { state -> (CheckedContinuation<T?, Never>, Deadline?)? in
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
    /// SIGKILL is what reaches anything that ignored the SIGTERM, so the leader is not reaped
    /// until then: its zombie is what keeps the group id ours in the meantime.
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

extension Duration {
    /// Seconds as a `Double`, for the `DispatchTime` arithmetic the deadline needs.
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
