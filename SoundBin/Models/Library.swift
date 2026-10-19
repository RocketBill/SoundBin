import Foundation
import Observation

/// A folder the user has opened, remembered with a security-scoped bookmark so the sandboxed app can reopen it.
nonisolated struct SavedFolder: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var path: String
    var bookmark: Data
    var soundCount: Int?
}

/// A starred file. Favourites can come from any folder, so each keeps its own bookmark.
nonisolated struct Favourite: Codable, Identifiable, Hashable, Sendable {
    var path: String
    var bookmark: Data
    var added: Date

    var id: String { path }
}

/// The user's folders and favourites, persisted as JSON in Application Support.
@Observable
final class Library {
    private(set) var folders: [SavedFolder] = []
    private(set) var favourites: [Favourite] = []
    private(set) var favouritePaths: Set<String> = []

    @ObservationIgnored private let storeURL: URL

    private static let maxFolders = 30

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appending(path: "Library.json")
        load()
    }

    // MARK: Folders

    func folder(id: SavedFolder.ID) -> SavedFolder? {
        folders.first { $0.id == id }
    }

    /// Adds a folder chosen by the user, or returns the existing entry for the same path.
    @discardableResult
    func addFolder(_ url: URL) -> SavedFolder? {
        let path = url.standardizedFileURL.path
        if let existing = folders.first(where: { $0.path == path }) {
            return existing
        }
        // Folders inside the app's own container can't carry a security scope; a plain bookmark still resolves.
        guard let bookmark = (try? url.bookmarkData(options: Self.bookmarkOptions)) ?? (try? url.bookmarkData())
        else { return nil }
        let folder = SavedFolder(id: UUID(), name: url.lastPathComponent, path: path, bookmark: bookmark)
        folders.insert(folder, at: 0)
        if folders.count > Self.maxFolders { folders.removeLast(folders.count - Self.maxFolders) }
        save()
        return folder
    }

    func removeFolder(id: SavedFolder.ID) {
        folders.removeAll { $0.id == id }
        save()
    }

    func moveFolders(from source: IndexSet, to destination: Int) {
        folders.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func setSoundCount(_ count: Int, for id: SavedFolder.ID) {
        guard let index = folders.firstIndex(where: { $0.id == id }), folders[index].soundCount != count else { return }
        folders[index].soundCount = count
        save()
    }

    /// Resolves a folder's bookmark, refreshing it if macOS reports it as stale.
    func resolve(_ folder: SavedFolder) -> URL? {
        guard let (url, isStale) = Self.resolve(folder.bookmark) else { return nil }
        if isStale, let index = folders.firstIndex(where: { $0.id == folder.id }) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData(options: Self.bookmarkOptions) {
                folders[index].bookmark = fresh
                folders[index].path = url.standardizedFileURL.path
                save()
            }
        }
        return url
    }

    // MARK: Favourites

    func isFavourite(_ url: URL) -> Bool {
        favouritePaths.contains(url.standardizedFileURL.path)
    }

    /// Stars or unstars files. Must be called while the files are accessible, so their bookmarks can be created.
    func setFavourite(_ isFavourite: Bool, for urls: [URL]) {
        var changed = false
        for url in urls {
            let path = url.standardizedFileURL.path
            if isFavourite, !favouritePaths.contains(path),
               let bookmark = try? url.bookmarkData(options: Self.bookmarkOptions) {
                favourites.append(Favourite(path: path, bookmark: bookmark, added: .now))
                changed = true
            } else if !isFavourite, favouritePaths.contains(path) {
                favourites.removeAll { $0.path == path }
                changed = true
            }
        }
        guard changed else { return }
        favouritePaths = Set(favourites.map(\.path))
        save()
    }

    /// Resolves every favourite that still exists. The caller is responsible for starting security-scoped access.
    func resolveFavourites() -> [URL] {
        favourites.compactMap { Self.resolve($0.bookmark)?.url }
    }

    // MARK: Persistence

    private struct Stored: Codable {
        var folders: [SavedFolder]
        var favourites: [Favourite]
    }

    private static let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]

    private static func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale)
        else { return nil }
        return (url, isStale)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        folders = stored.folders
        favourites = stored.favourites
        favouritePaths = Set(stored.favourites.map(\.path))
    }

    private func save() {
        let stored = Stored(folders: folders, favourites: favourites)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
