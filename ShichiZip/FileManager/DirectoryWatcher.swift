import CoreServices
import Foundation

/// Monitors a directory with FSEvents and exposes a pollable change flag.
/// Runs on the main actor because callbacks are delivered on the main queue.
@MainActor
final class DirectoryWatcher {
    /// Stream-owned context that weakly references the watcher.
    private final class CallbackContext {
        weak var owner: DirectoryWatcher?
        init(owner: DirectoryWatcher) {
            self.owner = owner
        }
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
        // Give the stream an owned context so queued callbacks stay safe during teardown.
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

    /// Returns whether any events arrived since the last poll.
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
