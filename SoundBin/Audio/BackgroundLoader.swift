import CryptoKit
import Foundation

/// Identifies one version of a file, so edited files get fresh waveforms and artwork.
nonisolated struct FileKey: Hashable, Sendable {
    let url: URL
    let fileSize: Int64
    let modificationDate: Date

    init(_ file: AudioFile) {
        url = file.url
        fileSize = file.fileSize
        modificationDate = file.modificationDate
    }
}

/// A folder in the app's Caches directory holding one small file per `FileKey`.
nonisolated struct CacheDirectory: Sendable {
    let url: URL

    init(_ name: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = caches.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(for key: FileKey, extension ext: String) -> URL {
        let identity = "v1|\(key.url.path)|\(key.fileSize)|\(key.modificationDate.timeIntervalSinceReferenceDate)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return url.appending(path: "\(name).\(ext)")
    }

    func file(named name: String) -> URL {
        url.appending(path: name)
    }

    func size() -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? []
        return files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0)
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Produces per-file values (waveforms, artwork) in the background and hands them to tiles.
///
/// Tiles on screen ask with `request`; those requests are served newest first so the tiles you're
/// looking at fill in before ones you scrolled past. Everything else in the folder is warmed at lower
/// priority via `prefetch`, so scrolling later finds values already cached.
final class BackgroundLoader<Value: Sendable> {
    typealias Load = @Sendable (FileKey) async -> Value?

    struct Token: Hashable {
        fileprivate let id: Int
        fileprivate let key: FileKey
    }

    private let load: Load
    private let fallback: Value
    private let maxConcurrent: Int
    private let memoryLimit: Int

    private var memory: [FileKey: Value] = [:]
    private var memoryOrder: [FileKey] = []
    private var waiters: [FileKey: [Int: (Value) -> Void]] = [:]
    private var urgent: [FileKey] = []
    private var background: [FileKey] = []
    private var backgroundIndex = 0
    private var running: Set<FileKey> = []
    private var nextTokenID = 0

    /// - Parameters:
    ///   - fallback: Handed to waiters when `load` fails (returns nil). Failures aren't cached, since
    ///     they're usually a folder whose access ended mid-prefetch, and the next request should retry.
    ///   - memoryLimit: Oldest values are dropped from memory beyond this count; they stay on disk.
    init(maxConcurrent: Int, memoryLimit: Int = .max, fallback: Value, load: @escaping Load) {
        self.maxConcurrent = maxConcurrent
        self.memoryLimit = memoryLimit
        self.fallback = fallback
        self.load = load
    }

    func cached(_ file: AudioFile) -> Value? {
        memory[FileKey(file)]
    }

    /// Calls `handler` on the main actor once the value is ready. Cancel the token if the caller goes away first.
    func request(_ file: AudioFile, handler: @escaping (Value) -> Void) -> Token {
        let key = FileKey(file)
        nextTokenID += 1
        let token = Token(id: nextTokenID, key: key)
        if let value = memory[key] {
            handler(value)
            return token
        }
        waiters[key, default: [:]][token.id] = handler
        if !running.contains(key) {
            urgent.append(key)
            pump()
        }
        return token
    }

    func cancel(_ token: Token) {
        waiters[token.key]?[token.id] = nil
        if waiters[token.key]?.isEmpty == true {
            waiters[token.key] = nil
        }
    }

    func value(for file: AudioFile) async -> Value {
        if let value = cached(file) { return value }
        return await withCheckedContinuation { continuation in
            _ = request(file) { continuation.resume(returning: $0) }
        }
    }

    /// Queues every file for low-priority loading, replacing any earlier prefetch.
    func prefetch(_ files: [AudioFile]) {
        background = files.map(FileKey.init).filter { memory[$0] == nil }
        backgroundIndex = 0
        pump()
    }

    /// Adds files to the end of the current prefetch, for ones that turned up after it started.
    func prefetchMore(_ files: [AudioFile]) {
        background.removeFirst(backgroundIndex)
        backgroundIndex = 0
        background += files.map(FileKey.init).filter { memory[$0] == nil }
        pump()
    }

    func cancelPrefetch() {
        background = []
        backgroundIndex = 0
    }

    func removeAllFromMemory() {
        memory = [:]
        memoryOrder = []
    }

    #if DEBUG
    var debugIsIdle: Bool { running.isEmpty && backgroundIndex >= background.count }
    var debugCachedCount: Int { memory.count }
    #endif

    // MARK: Scheduling

    private func nextKey() -> FileKey? {
        while let key = urgent.popLast() {
            if memory[key] == nil, !running.contains(key), waiters[key] != nil { return key }
        }
        while backgroundIndex < background.count {
            let key = background[backgroundIndex]
            backgroundIndex += 1
            if memory[key] == nil, !running.contains(key) { return key }
        }
        return nil
    }

    private func pump() {
        while running.count < maxConcurrent, let key = nextKey() {
            running.insert(key)
            let load = load
            Task {
                let value = await Self.run(load, key)
                self.finish(key, value)
            }
        }
    }

    private func finish(_ key: FileKey, _ value: Value?) {
        running.remove(key)
        if let value { remember(value, for: key) }
        if let handlers = waiters.removeValue(forKey: key) {
            for handler in handlers.values { handler(value ?? fallback) }
        }
        pump()
    }

    private func remember(_ value: Value, for key: FileKey) {
        guard memory.updateValue(value, forKey: key) == nil, memoryLimit < .max else { return }
        memoryOrder.append(key)
        while memory.count > memoryLimit, !memoryOrder.isEmpty {
            memory[memoryOrder.removeFirst()] = nil
        }
    }

    /// Runs the load function off the main actor.
    @concurrent
    private nonisolated static func run(_ load: Load, _ key: FileKey) async -> Value? {
        await load(key)
    }
}
