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
    func stop()
}

/// Watches a repository directory (including its .git folder) with FSEvents and
/// reports changes, debounced, on the main actor.
@MainActor
final class RepoWatcher: RepoWatching {
    private var stream: FSEventStreamRef?
    private let debouncer: Debouncer
    private let queue = DispatchQueue(label: "com.selwin.DiffViewer.RepoWatcher")

    init(root: URL, interval: Duration = .milliseconds(400), onChange: @escaping @MainActor () -> Void) {
        debouncer = Debouncer(interval: interval, action: onChange)
        start(root: root)
    }

    private func start(root: URL) {
        let unmanaged = Unmanaged.passUnretained(self)
        var context = FSEventStreamContext(version: 0, info: unmanaged.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in watcher.debouncer.call() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        debouncer.cancel()
    }

    deinit {
        // Streams are stopped explicitly by the owner; nothing else to release here.
    }
}
