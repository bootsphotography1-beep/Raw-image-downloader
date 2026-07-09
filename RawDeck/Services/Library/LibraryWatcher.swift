import Foundation

/// One observed file system event, post-debounce. Always carries the URL of
/// the file that changed and the kind of change.
///
/// We collapse the FSEventStream's notion of events (which can have several
/// `kFSEventStreamEventFlag*` bits per path) into a small enum because
/// downstream code cares about *what to do*, not the precise flag set. The
/// current mapping is intentionally lossy — `.modified` covers both writes and
/// renames-into, `.removed` covers both deletion and rename-out, `.created`
/// covers new files, and `.unknown` is the catch-all for flag combinations
/// we don't yet classify.
enum WatcherEvent: Equatable {
    case created(URL)
    case modified(URL)   // write or attribute change (XMP edit)
    case removed(URL)
    case unknown(URL)

    var url: URL {
        switch self {
        case .created(let u), .modified(let u), .removed(let u), .unknown(let u):
            return u
        }
    }
}

/// Watches a directory tree for changes via `FSEventStream` (CoreServices).
///
/// Design notes:
/// - macOS 14+ only. Older macOS versions return `nil` from `start()` and
///   callers fall back to the manual-import UX. The 13.0 deployment target is
///   preserved via a `@available` guard on the entry point.
/// - We debounce events by ~250 ms so a burst (e.g. "phone just connected and
///   uploaded 30 photos") becomes a single scan rather than 30.
/// - The CoreServices callback runs on `DispatchQueue.main` so consumers can
///   safely hop straight to `@MainActor` work; we don't introduce a private
///   dispatch queue because the user-visible work is already serialized on
///   the main actor by `SyncCoordinator`.
/// - `stop()` is idempotent. Calling it on a non-started watcher is a no-op.
/// - The retention problem: FSEventStream keeps a *raw context pointer*, not
///   a Swift reference. We can't `unmanaged.retain()` because FSEvents holds
///   onto the pointer past the lifetime of `self`. Instead, we capture `self`
///   weakly inside the C-style callback via a class-bound `UserData`, and
///   `stop()` explicitly invalidates the stream.
final class LibraryWatcher {

    /// Fires debounced file system events. Always on the main thread.
    var onEvent: ((WatcherEvent) -> Void)?

    private var stream: FSEventStreamRef?
    private let rootURL: URL
    private let debounceInterval: TimeInterval
    private var debounceWorkItem: DispatchWorkItem?
    private var pendingEventURLs: Set<URL> = []
    private var pendingEventKinds: [URL: WatcherEvent] = [:]

    /// Construct against a root URL. The watcher is not started until
    /// `start()` is called.
    init(rootURL: URL, debounceInterval: TimeInterval = 0.25) {
        self.rootURL = rootURL
        self.debounceInterval = debounceInterval
    }

    deinit { stop() }

    /// Start watching. Returns `false` on invalid
    /// paths or if the stream creation fails. Caller should fall back
    /// to the manual-import UX in that case.
    @available(macOS 13.0, *)
    func start() -> Bool {
        // FSEventStreamCreate requires a non-nil path. Also guard against
        // double-start which would leak the prior stream.
        guard stream == nil else { return true }
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return false }

        // FSEvents flags:
        // - kFSEventStreamCreateFlagFileEvents: we want per-file events, not
        //   just per-directory.
        // - kFSEventStreamCreateFlagNoDefer: fire the first events as soon
        //   as the stream starts (otherwise we'd miss files added since the
        //   initial scan).
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue()
            // `eventPaths` is a `UnsafeMutableRawPointer` that, with the
            // standard `FSEventStreamCreate` (no `kFSEventStreamCreateFlagUseCFTypes`),
            // actually points to a C array of `const char *` UTF-8 strings —
            // i.e. `const char * const *`. Reinterpret it as a typed pointer
            // to an array of optional C-string pointers and walk it.
            // On macOS the strings are guaranteed to be valid UTF-8 from
            // FSEventStreamCreate — converting through `String(cString:)`
            // is the recommended path.
            // Use `withMemoryRebound` (not `bindMemory`) because the
            // pointer is handed to us already typed as `const char *const *`;
            // rebinding tells Swift to treat those bytes as our type for
            // the duration of the closure without any memory writes.
            let paths = eventPaths.withMemoryRebound(
                to: Optional<UnsafePointer<CChar>>.self,
                capacity: count
            ) { buf in
                Array(UnsafeBufferPointer(start: buf, count: count))
            }
            for index in 0..<count {
                guard let rawPath = paths[index] else { continue }
                let path = String(cString: rawPath)
                let url = URL(fileURLWithPath: path, isDirectory: false)
                let flags = eventFlags[index]
                watcher.handleRawEvent(at: url, flags: flags)
            }
        }

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,  // latency — 100 ms — combined with the 250 ms debounce
            UInt32(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer
            )
        ) else {
            return false
        }

        FSEventStreamSetDispatchQueue(newStream, .main)
        let started = FSEventStreamStart(newStream)
        if !started {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            return false
        }

        stream = newStream
        return true
    }

    /// Stop watching. Idempotent.
    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingEventURLs.removeAll()
        pendingEventKinds.removeAll()
    }

    // MARK: - Internal event handling

    /// Map FSEvents flag bits to one of our `WatcherEvent` cases. The mapping
    /// is intentionally simple — see `WatcherEvent` for the rationale.
    private func classify(flags: FSEventStreamEventFlags, at url: URL) -> WatcherEvent {
        if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
            return .removed(url)
        }
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
            return .created(url)
        }
        if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 {
            return .modified(url)
        }
        if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
            // We can't tell from this flag alone whether it's a rename-in or
            // rename-out. Most rename-outs also carry the
            // `kFSEventStreamEventFlagItemRemoved` flag in practice, so by the
            // time we get here with no Removed flag, treat as a modified.
            return .modified(url)
        }
        return .unknown(url)
    }

    private func handleRawEvent(at url: URL, flags: FSEventStreamEventFlags) {
        let event = classify(flags: flags, at: url)
        pendingEventURLs.insert(url)
        // If we got a removed event, that supersedes prior created/modified.
        if case .removed = event {
            pendingEventKinds[url] = .removed(url)
        } else if pendingEventKinds[url] == nil {
            pendingEventKinds[url] = event
        }

        // Reset the debounce window.
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingEvents()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func flushPendingEvents() {
        let events = pendingEventKinds.values
        pendingEventKinds.removeAll(keepingCapacity: true)
        pendingEventURLs.removeAll(keepingCapacity: true)
        for event in events {
            onEvent?(event)
        }
    }
}
