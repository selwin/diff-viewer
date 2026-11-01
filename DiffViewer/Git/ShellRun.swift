import Foundation
import os

/// What a run's output adds up to so far, as judged by the caller of `ShellRun.result`.
enum ShellOutput<T: Sendable>: Sendable {
    /// Not the whole answer yet; worth waiting for only while the pipe is open.
    case incomplete
    case valid(T)
    /// Output that can never become an answer, so the run fails at once.
    case invalid
}

/// How a run that takes its whole output ended.
enum ShellRunOutcome: Equatable, Sendable {
    /// Everything written to stdout, once the process exited with status 0 and the pipe closed.
    case output(Data)
    /// -1 when the process didn't exit normally.
    case exited(status: Int32)
    case timedOut
    case outputTooLarge
}

/// Shared by every run: generic types cannot hold stored static properties.
private let shellRunReadQueue = DispatchQueue(label: "com.selwin.DiffViewer.ShellRun")

/// One spawned process with a deadline: a shell that runs the user's startup files, or a
/// command such as `gh`. Owns its pid until it reaps it, under the same lock that gates
/// signalling, so a signal can never reach a reused pid; and the process leads its own
/// process group, so a timeout takes its children down with it.
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
        var continuation: CheckedContinuation<Settlement, Never>?
        /// Also told whether the pipe is at EOF, so a run can wait for the whole output.
        var interpret: (@Sendable (Data, Bool) -> ShellOutput<T>)?
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

    /// How the run ended. Anything but `.answer` takes the process group down.
    private enum Settlement: Sendable {
        case answer(T)
        /// Exited with status 0, but `interpret` refused the output.
        case rejected
        case exited(status: Int32)
        case timedOut
        case outputTooLarge

        var isAnswer: Bool {
            if case .answer = self { true } else { false }
        }
    }

    /// What the shared state adds up to so far. `.wait` means someone still owes either the
    /// exit status or the rest of the output.
    private enum Outcome {
        case wait
        case done(Settlement)
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
        spawn(
            executable: shell, arguments: arguments,
            environment: ProcessEnvironment(variables: extraEnvironment, inheritance: .inherit))
    }

    /// Launches `executable arguments…` with stdout on a pipe and nothing else inherited, in
    /// `currentDirectory` when given; nil when it cannot be spawned, including when the
    /// directory can't be entered.
    static func spawn(
        executable: String, arguments: [String], environment: ProcessEnvironment, currentDirectory: URL? = nil
    ) -> ShellRun? {
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

        // Every call is checked: a process spawned with a half-built setup could inherit our
        // descriptors or land in our process group, which is worse than not spawning at all.
        // Its own process group is what a timeout signals, and CLOEXEC_DEFAULT keeps the
        // rest of the app's descriptors out of a shell that runs arbitrary startup files.
        guard posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
            posix_spawn_file_actions_adddup2(&actions, writeFD, 1) == 0,
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0,
            posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
            posix_spawnattr_setpgroup(&attrs, 0) == 0
        else { return abandonSetup() }
        if let currentDirectory {
            guard posix_spawn_file_actions_addchdir(&actions, currentDirectory.path) == 0 else {
                return abandonSetup()
            }
        }

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = Self.environment(environment)

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attrs, argv, envp)

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

    /// `environment` as a nil-terminated `envp`: its variables, laid over the app's own
    /// environment under `.inherit`. Inherited entries are copied as raw bytes, so a value
    /// that is not UTF-8 passes through intact.
    private static func environment(_ environment: ProcessEnvironment) -> [UnsafeMutablePointer<CChar>?] {
        var entries: [UnsafeMutablePointer<CChar>?] = []
        if environment.inheritance == .inherit {
            var index = 0
            while let entry = environ[index] {
                let name = String(String(cString: entry).prefix { $0 != "=" })
                if environment.variables[name] == nil { entries.append(strdup(entry)) }
                index += 1
            }
        }
        for (name, value) in environment.variables { entries.append(strdup("\(name)=\(value)")) }
        return entries + [nil]
    }

    /// What `interpret` makes of the output once the process has exited with status 0; nil
    /// on any other exit, `.invalid` or `.incomplete` output, overflow, or the deadline.
    func result(
        timeout: Duration, outputLimit: Int, interpret: @escaping @Sendable (Data) -> ShellOutput<T>
    ) async -> T? {
        let settlement = await settlement(timeout: timeout, outputLimit: outputLimit) { data, _ in
            interpret(data)
        }
        if case let .answer(value) = settlement { return value }
        return nil
    }

    private func settlement(
        timeout: Duration, outputLimit: Int, interpret: @escaping @Sendable (Data, Bool) -> ShellOutput<T>
    ) async -> Settlement {
        await withCheckedContinuation { (continuation: CheckedContinuation<Settlement, Never>) in
            let deadline = Deadline(item: DispatchWorkItem { [self] in abandon(.timedOut) })
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
            // A process that overflowed is still running and would block on a pipe nobody
            // drains once we stop reading, so it takes the same exit as the deadline.
            if overflowed { abandon(.outputTooLarge) } else { settle() }
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
            // Counted whether or not `waitid` succeeded: either way the process is gone from our side.
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

    /// Signals the process's whole group, so children it left behind, such as a startup
    /// file's, go with it. The reap happens under this lock too, so an unreaped leader means
    /// the group id is still ours and the signal can never reach another process's group.
    private func signal(_ sig: Int32) {
        state.withLock { state in
            guard !state.reaped else { return }
            kill(-pid, sig)
        }
    }

    /// Gives up on the process. Not being an answer is the whole decision: `deliver` reads it
    /// as "take the group down" and holds the reap back until the last signal has been sent.
    private func abandon(_ reason: Settlement) {
        deliver(reason)
    }

    /// The pipe and the exit are observed on separate queues, in either order, so neither side
    /// decides on its own: whichever runs last settles it.
    private func settle() {
        let outcome = state.withLock { state -> Outcome in
            guard state.output.count <= state.outputLimit else { return .done(.outputTooLarge) }
            guard let status = state.exitStatus else { return .wait }
            guard status == 0 else { return .done(.exited(status: status)) }
            guard let interpret = state.interpret else { return .done(.rejected) }
            switch interpret(state.output, state.eof) {
            case let .valid(value): return .done(.answer(value))
            case .invalid: return .done(.rejected)
            // The rest of the output may still be in flight unless the pipe is already at
            // EOF. The deadline bounds the wait.
            case .incomplete: return state.eof ? .done(.rejected) : .wait
            }
        }
        if case let .done(settlement) = outcome { deliver(settlement) }
    }

    /// Answers the caller exactly once and, with the same decision, settles the group: an
    /// answer we accepted leaves the process's children alone, anything else takes the group
    /// down. Taking the continuation out is what makes both happen only once.
    private func deliver(_ settlement: Settlement) {
        let taken = state.withLock { state -> (CheckedContinuation<Settlement, Never>, Deadline?)? in
            guard let continuation = state.continuation else { return nil }
            state.continuation = nil
            state.cleanup = settlement.isAnswer ? .none : .terminating
            let deadline = state.deadline
            state.deadline = nil
            return (continuation, deadline)
        }
        guard let (continuation, deadline) = taken else { return }
        continuation.resume(returning: settlement)
        // The answer is out: nothing wants more output, and nothing is left to time out.
        source.cancel()
        deadline?.item.cancel()
        if settlement.isAnswer { reapIfReady() } else { terminateGroup() }
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

extension ShellRun where T == Data {
    /// Everything the process writes to stdout, once it has exited with status 0 and closed
    /// the pipe; otherwise why not.
    func output(timeout: Duration, outputLimit: Int) async -> ShellRunOutcome {
        let settlement = await settlement(timeout: timeout, outputLimit: outputLimit) { data, eof in
            eof ? .valid(data) : .incomplete
        }
        switch settlement {
        case let .answer(data): return .output(data)
        // Never reached: the whole output is always the answer once the pipe closes.
        case .rejected: return .exited(status: 0)
        case let .exited(status): return .exited(status: status)
        case .timedOut: return .timedOut
        case .outputTooLarge: return .outputTooLarge
        }
    }
}

extension Duration {
    /// Seconds as a `Double`, for the `DispatchTime` arithmetic the deadline needs.
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
