import Foundation

/// What each source contained when it was last scanned. Saved so a folder's sounds can be shown the
/// moment it's opened, even after relaunching, while a rescan checks for changes in the background.
nonisolated enum ListingStore {
    static let directory = CacheDirectory("Listings")
    /// Version 2: Ogg Vorbis lengths count every frame of the sound (see `AudioFileReader`).
    private static let version = 2

    private struct Stored: Codable {
        /// Missing from listings saved by version 1.
        var version: Int?
        /// The folder the listing was made from. A listing for a folder that has since moved is ignored.
        var root: String?
        var files: [AudioFile]
    }

    @concurrent
    static func load(_ source: BrowseSource, root: String?) async -> [AudioFile]? {
        guard let data = try? Data(contentsOf: file(for: source)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.root == root
        else { return nil }
        guard (stored.version ?? 1) < 2 else { return stored.files }
        // Rescans reuse listed files that haven't changed, so leave out Ogg files to have their lengths read again.
        return stored.files.filter { !["ogg", "oga"].contains($0.url.pathExtension.lowercased()) }
    }

    @concurrent
    static func save(_ files: [AudioFile], for source: BrowseSource, root: String?) async {
        guard let data = try? JSONEncoder().encode(Stored(version: version, root: root, files: files)) else { return }
        try? data.write(to: file(for: source), options: .atomic)
    }

    static func remove(_ source: BrowseSource) {
        try? FileManager.default.removeItem(at: file(for: source))
    }

    private static func file(for source: BrowseSource) -> URL {
        directory.file(named: "\(source.storageKey).json")
    }
}
