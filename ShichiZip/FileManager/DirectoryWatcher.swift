import CoreServices
import Foundation

/// Monitors a filesystem directory for changes using FSEvents.
///
/// Mirrors the upstream Windows 7-Zip pattern where `CFSFolder::Init()` registers
/// a `FindFirstChangeNotification` handle, and `WasChanged()` returns whether the
/// handle has been signaled since the last check.  Here, FSEvents sets a flag and
/// the caller polls via ``wasChanged()`` on a timer tick.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var changed = false
    var onChange: (() -> Void)?

    init(directory: URL) {
        let pathString = directory.path as CFString
        let paths = [pathString] as CFArray

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.changed = true
                watcher.onChange?()
            },
            &context,
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

    deinit {
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
    }
}
