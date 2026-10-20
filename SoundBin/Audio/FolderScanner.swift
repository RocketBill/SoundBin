import AVFoundation
import UniformTypeIdentifiers

/// Finds audio files on disk and reads their headers. All work happens off the main actor.
nonisolated enum FolderScanner {
    private struct Candidate: Sendable {
        let url: URL
        let folder: String
        let fileSize: Int64
        let modificationDate: Date
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .contentTypeKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// Recursively scans `root` for audio files. `progress` receives the number of files read so far.
    ///
    /// Files in `known` whose size and modification date haven't changed are reused rather than
    /// opened again, so rescanning a folder that's been seen before costs little more than a directory walk.
    @concurrent
    static func scan(root: URL, reusing known: [AudioFile] = [],
                     progress: @escaping @Sendable (Int) -> Void) async -> [AudioFile] {
        let candidates = findCandidates(in: root)
        return await resolve(candidates, reusing: known, progress: progress)
    }

    /// Reads the given files directly, for lists that don't come from one folder (favourites and collections).
    /// Each file is grouped under the name of its parent folder, or all together if `groupedByFolder` is false.
    @concurrent
    static func read(files urls: [URL], reusing known: [AudioFile] = [], groupedByFolder: Bool = true) async -> [AudioFile] {
        let candidates = urls.compactMap { url -> Candidate? in
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
            return Candidate(
                url: url,
                folder: groupedByFolder ? url.deletingLastPathComponent().lastPathComponent : "",
                fileSize: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? .distantPast
            )
        }
        return await resolve(candidates, reusing: known, progress: { _ in })
    }

    /// True for sound files SoundBin can list, such as files dropped from Finder.
    static func isAudioFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return false }
        return isAudio(values)
    }

    private static func isAudio(_ values: URLResourceValues) -> Bool {
        guard values.isRegularFile == true, let type = values.contentType else { return false }
        return type.conforms(to: .audio) && !type.conforms(to: .midi)
    }

    /// Groups files into sections by folder. Root files come first, then subfolders in Finder order.
    static func group(_ files: [AudioFile], rootTitle: String) -> [FileSection] {
        let byFolder = Dictionary(grouping: files, by: \.folder)
        return byFolder.keys
            .sorted { lhs, rhs in
                if lhs.isEmpty != rhs.isEmpty { return lhs.isEmpty }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { folder in
                let files = byFolder[folder] ?? []
                return FileSection(
                    id: folder,
                    title: folder.isEmpty ? rootTitle : folder.replacingOccurrences(of: "/", with: " › "),
                    files: files,
                    matchCount: files.count,
                    isCollapsed: false
                )
            }
    }

    // MARK: - Private

    /// Directory enumeration is synchronous, so it lives outside the async scan.
    private static func findCandidates(in root: URL) -> [Candidate] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path
        var candidates: [Candidate] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return [] }
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)), isAudio(values) else { continue }

            candidates.append(Candidate(
                url: url,
                folder: relativeFolder(of: url, rootPath: rootPath),
                fileSize: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? .distantPast
            ))
        }
        return candidates
    }

    private static func relativeFolder(of url: URL, rootPath: String) -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        guard parent.hasPrefix(rootPath) else { return url.deletingLastPathComponent().lastPathComponent }
        return String(parent.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func resolve(
        _ candidates: [Candidate],
        reusing known: [AudioFile],
        progress: @escaping @Sendable (Int) -> Void
    ) async -> [AudioFile] {
        guard !known.isEmpty else { return await readHeaders(of: candidates, progress: progress) }
        let knownByPath = Dictionary(known.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        var files: [AudioFile] = []
        var unknown: [Candidate] = []
        for candidate in candidates {
            if let file = knownByPath[candidate.url.path],
               file.fileSize == candidate.fileSize, file.modificationDate == candidate.modificationDate {
                files.append(file.inFolder(candidate.folder))
            } else {
                unknown.append(candidate)
            }
        }
        return files + (await readHeaders(of: unknown, progress: progress))
    }

    private static func readHeaders(
        of candidates: [Candidate],
        progress: @escaping @Sendable (Int) -> Void
    ) async -> [AudioFile] {
        var files: [AudioFile] = []
        files.reserveCapacity(candidates.count)

        await withTaskGroup(of: AudioFile?.self) { group in
            var remaining = candidates.makeIterator()
            let width = max(4, ProcessInfo.processInfo.activeProcessorCount)
            for _ in 0..<width {
                guard let candidate = remaining.next() else { break }
                group.addTask { readHeader(candidate) }
            }
            var completed = 0
            while let result = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                if let result { files.append(result) }
                completed += 1
                if completed % 64 == 0 { progress(completed) }
                if let candidate = remaining.next() {
                    group.addTask { readHeader(candidate) }
                }
            }
        }
        return files
    }

    /// Opens the file just far enough to learn its length and format. Files Core Audio can't decode are skipped.
    private static func readHeader(_ candidate: Candidate) -> AudioFile? {
        guard let file = try? AudioFileReader(forReading: candidate.url) else { return nil }
        let format = file.processingFormat
        return AudioFile(
            url: candidate.url,
            folder: candidate.folder,
            fileSize: candidate.fileSize,
            modificationDate: candidate.modificationDate,
            duration: Double(file.length) / format.sampleRate,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }
}
