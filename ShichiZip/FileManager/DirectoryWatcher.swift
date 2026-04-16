import CoreServices
import Foundation

/// Monitors a filesystem directory for changes using FSEvents.
///
/// Mirrors the upstream Windows 7-Zip pattern where `CFSFolder::Init()` registers
/// a `FindFirstChangeNotification` handle, and `WasChanged()` returns whether the
/// handle has been signaled since the last check.  Here, FSEvents sets a flag and
/// the caller polls via ``wasChanged()`` on a timer tick.
///
/// The class is isolated to the main actor: `FSEventStreamSetDispatchQueue(main)`
/// schedules the C callback on the main queue, and `stop()` must run there too
/// so that no callback can fire between invalidation and release.
@MainActor
final class DirectoryWatcher {
    /// Box that the FSEventStream owns a strong reference to for the
    /// lifetime of the stream. It holds a weak back-pointer to the
    /// watcher so a callback scheduled but not yet delivered safely
    /// observes "already torn down" instead of dereferencing a dead
    /// DirectoryWatcher.
    private final class CallbackContext {
        weak var owner: DirectoryWatcher?
        init(owner: DirectoryWatcher) { self.owner = owner }
    }

    private var stream: FSEventStreamRef?
    private var callbackContext: CallbackContext?
    private var changed = false
    var onChange: (() -> Void)?

    init(directory: URL) {
        let pathString = directory.path as CFString
        let paths = [pathString] as CFArray

        let context = CallbackContext(owner: self)
        callbackContext = context

        var streamContext = FSEventStreamContext()
        // passRetained hands the stream a +1 owning reference to the
        // context box; the matching release callback drops it when the
        // stream is invalidated. Using passUnretained (as the previous
        // implementation did) was a UAF: a callback already in flight
        // on the main queue could outlive a deinit that ran on a
        // different thread, and takeUnretainedValue would dereference
        // freed memory.
        streamContext.info = Unmanaged.passRetained(context).toOpaque()
        streamContext.retain = { info in
            guard let info else { return nil }
            _ = Unmanaged<CallbackContext>.fromOpaque(info).retain()
            return UnsafeRawPointer(info)
        }
        streamContext.release = { info in
            guard let info else { return }
            Unmanaged<CallbackContext>.fromOpaque(info).release()
        }

        stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
                // The stream's dispatch queue is the main queue
                // (set below), so this closure runs main-isolated.
                MainActor.assumeIsolated {
                    guard let watcher = context.owner else { return }
                    watcher.changed = true
                    watcher.onChange?()
                }
            },
            &streamContext,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer),
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    isolated deinit {
        stop()
    }

    /// Drains all pending change events and returns whether any occurred since
    /// the last call — analogous to upstream `CFSFolder::WasChanged()`.
    func wasChanged() -> Bool {
        guard changed else { return false }
        changed = false
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackContext = nil
    }
}
