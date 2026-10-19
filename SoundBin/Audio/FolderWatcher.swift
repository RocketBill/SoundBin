import CoreServices
import Foundation

/// Reports changes anywhere inside a folder, subfolders included, so new sounds appear without reloading.
///
/// FSEvents batches changes over a short window, so a burst (copying in a pack of samples, say)
/// arrives as one call rather than hundreds.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let rootPath: String
    private let onChange: () -> Void

    /// Changes are delivered on the main actor, at most about twice a second.
    init?(url: URL, onChange: @escaping () -> Void) {
        rootPath = url.standardizedFileURL.path
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(nil, folderWatcherCallback, &context, [url.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               FSEventStreamCreateFlags(flags))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    isolated deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func handle(_ paths: [String]) {
        // Finder rewrites .DS_Store just from browsing a folder; hidden files never show up in the grid anyway.
        let relevant = paths.contains { path in
            let inside = path.hasPrefix(rootPath) ? path.dropFirst(rootPath.count) : Substring(path)
            return !inside.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        if relevant { onChange() }
    }
}

/// FSEvents takes a C function pointer, so the callback can't capture anything; the watcher comes through `info`.
private nonisolated func folderWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    // The stream is scheduled on the main queue, and stopped before the watcher is released.
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
    MainActor.assumeIsolated {
        watcher.handle(paths)
    }
}
