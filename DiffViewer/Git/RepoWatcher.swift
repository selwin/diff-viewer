import CoreServices
import Foundation

/// Coalesces rapid calls into one, `interval` after the last call.
@MainActor
final class Debouncer {
    private let interval: Duration
    private var task: Task<Void, Never>?
    private let action: @MainActor () -> Void

    init(interval: Duration, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    func call() {
        task?.cancel()
        task = Task { [interval, action] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Something that reports repository changes until stopped.
@MainActor
protocol RepoWatching: AnyObject {
    /// Files outside the filter's own rules whose edits matter: the commit template. Each
    /// call replaces the previous set.
    func setDependencies(_ paths: Set<String>)
    func stop()
}

/// Watches a repository directory (including its .git folder) with FSEvents and reports
/// what changed, classified and debounced, on the main actor. Events the app never acts
/// on (`.git/objects`, `.git/logs`, `index.lock`) are dropped before the debounce.
@MainActor
final class RepoWatcher: RepoWatching {
    /// The side of the watcher the FSEvents callback touches. It runs on the stream's
    /// queue, so the pending set lives under a lock, and the stream retains the sink so a
    /// callback in flight after `stop()` still has something to write to.
    final class EventSink: @unchecked Sendable {
        /// Symlink-resolved with `realpath`: FSEvents reports `/private/tmp/…` for `/tmp/…`,
        /// an unresolved prefix would match nothing, and Foundation's resolver strips
        /// `/private` back off.
        private let root: String
        private let lock = NSLock()
        private var pending: Set<RepoChange> = []
        private var dependencies: Set<String> = []
        private var stopped = false
        /// Weak: the debouncer's action holds the sink, and the watcher owns both.
        private weak var debouncer: Debouncer?

        init(root: URL) {
            self.root = Self.canonicalEventPath(root.path)
        }

        /// `path` as FSEvents would report it: the nearest existing ancestor through
        /// `realpath`, with the missing components appended. A template whose directory
        /// does not exist yet is still recognised when both are created.
        private static func canonicalEventPath(_ path: String) -> String {
            var existing = path
            while existing.count > 1, existing.hasSuffix("/") { existing.removeLast() }
            var missing: [String] = []
            while existing.count > 1, realpath(existing, nil) == nil {
                let url = URL(fileURLWithPath: existing)
                missing.insert(url.lastPathComponent, at: 0)
                existing = url.deletingLastPathComponent().path
            }
            guard let resolved = realpath(existing, nil) else { return path }
            defer { free(resolved) }
            return ([String(cString: resolved)] + missing).joined(separator: "/")
        }

        /// Each dependency is watched at two paths: the configured one, canonicalised
        /// through its directory so the link itself counts when it is replaced, deleted or
        /// retargeted; and its current target, so an edit through the link counts too.
        func setDependencies(_ paths: Set<String>) {
            var watched: Set<String> = []
            for path in paths {
                let url = URL(fileURLWithPath: path)
                let directory = Self.canonicalEventPath(url.deletingLastPathComponent().path)
                watched.insert(directory + "/" + url.lastPathComponent)
                watched.insert(Self.canonicalEventPath(path))
            }
            lock.withLock { dependencies = watched }
        }

        func attach(_ debouncer: Debouncer) {
            lock.withLock { self.debouncer = debouncer }
        }

        /// What the callback does with one batch: classify, and if anything relevant
        /// survived, arm the debounce on the main actor.
        func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
            guard receive(paths: paths, flags: flags) else { return }
            Task { @MainActor in
                // `stop()` may have run while this hop was queued.
                let debouncer = self.lock.withLock { self.stopped ? nil : self.debouncer }
                debouncer?.call()
            }
        }

        /// Classifies each event and merges the survivors into `pending`. Returns whether
        /// anything survived and the watcher is still running.
        func receive(paths: [String], flags: [FSEventStreamEventFlags]) -> Bool {
            let dependencies = lock.withLock { self.dependencies }
            var changes: Set<RepoChange> = []
            for (path, flag) in zip(paths, flags) {
                let change = RepoEventFilter.classify(path: path, flags: flag, root: root, dependencies: dependencies)
                if let change { changes.insert(change) }
            }
            guard !changes.isEmpty else { return false }
            return lock.withLock {
                guard !stopped else { return false }
                pending.formUnion(changes)
                return true
            }
        }

        /// Returns and clears everything received since the last take.
        func take() -> Set<RepoChange> {
            lock.withLock {
                let taken = pending
                pending = []
                return taken
            }
        }

        func stop() {
            lock.withLock {
                stopped = true
                pending = []
            }
        }
    }

    private var stream: FSEventStreamRef?
    private let sink: EventSink
    private let debouncer: Debouncer
    private let queue = DispatchQueue(label: "com.selwin.DiffViewer.RepoWatcher")

    init(root: URL, interval: Duration = .milliseconds(400), onChange: @escaping @MainActor (Set<RepoChange>) -> Void) {
        let sink = EventSink(root: root)
        self.sink = sink
        debouncer = Debouncer(interval: interval) {
            let changes = sink.take()
            if !changes.isEmpty { onChange(changes) }
        }
        sink.attach(debouncer)
        start(root: root)
    }

    /// Exactly what the FSEvents callback does with one batch, for tests without a stream.
    nonisolated func simulate(paths: [String], flags: [FSEventStreamEventFlags]) {
        sink.deliver(paths: paths, flags: flags)
    }

    func setDependencies(_ paths: Set<String>) {
        sink.setDependencies(paths)
    }

    private func start(root: URL) {
        // The stream retains the sink through these callbacks for as long as its own
        // callback can fire; the watcher itself is never handed to C.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(), retain: retainSink, release: releaseSink,
            copyDescription: nil)
        // `FileEvents` for per-file paths to classify; `WatchRoot` so a moved or deleted
        // root is reported at all.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf
                | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                nil, handleEvents, &context, [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        // The sink first, so a callback racing the teardown arms nothing.
        sink.stop()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debouncer.cancel()
    }

    deinit {
        // Streams are stopped explicitly by the owner; nothing else to release here.
    }
}

// The C callbacks are free functions: a closure written inside the `@MainActor` watcher
// would be isolated to it and trap when FSEvents calls it on its own queue.

private func retainSink(_ info: UnsafeRawPointer?) -> UnsafeRawPointer? {
    UnsafeRawPointer(Unmanaged<RepoWatcher.EventSink>.fromOpaque(info!).retain().toOpaque())
}

private func releaseSink(_ info: UnsafeRawPointer?) {
    Unmanaged<RepoWatcher.EventSink>.fromOpaque(info!).release()
}

// FSEvents dictates the six parameters.
// swiftlint:disable:next function_parameter_count
private func handleEvents(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
    _ eventPaths: UnsafeMutableRawPointer, _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let sink = Unmanaged<RepoWatcher.EventSink>.fromOpaque(info).takeUnretainedValue()
    // `UseCFTypes`: `eventPaths` is a CFArray of CFString.
    guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray as? [String] else {
        return
    }
    sink.deliver(paths: paths, flags: Array(UnsafeBufferPointer(start: eventFlags, count: count)))
}
