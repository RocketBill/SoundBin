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

/// A file in a favourites list or collection. These can come from any folder, so each keeps its own bookmark.
nonisolated struct SavedFile: Codable, Identifiable, Hashable, Sendable {
    var path: String
    var bookmark: Data
    var added: Date

    var id: String { path }
}

/// A user-made group of sounds from anywhere on disk. Nothing moves on disk until it's made into a real folder.
nonisolated struct SavedCollection: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var files: [SavedFile]
}

/// The user's folders, collections, favourites and labels, persisted as JSON in Application Support.
@Observable
final class Library {
    private(set) var folders: [SavedFolder] = []
    private(set) var collections: [SavedCollection] = []
    private(set) var favourites: [SavedFile] = []
    private(set) var favouritePaths: Set<String> = []
    /// Labels by file path. Labels only filter what's on screen, so unlike favourites they need no bookmarks.
    private(set) var fileLabels: [String: Set<SoundLabel>] = [:]
    /// Names the user has given labels, in label order; empty entries fall back to the colour's name.
    private(set) var labelNames: [String] = []

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
                favourites.append(SavedFile(path: path, bookmark: bookmark, added: .now))
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

    // MARK: Labels

    func labels(for url: URL) -> Set<SoundLabel> {
        fileLabels[url.standardizedFileURL.path] ?? []
    }

    func setLabel(_ label: SoundLabel, _ isOn: Bool, for urls: [URL]) {
        var changed = false
        for url in urls {
            let path = url.standardizedFileURL.path
            var labels = fileLabels[path] ?? []
            let wasOn = labels.contains(label)
            guard wasOn != isOn else { continue }
            if isOn { labels.insert(label) } else { labels.remove(label) }
            fileLabels[path] = labels.isEmpty ? nil : labels
            changed = true
        }
        if changed { save() }
    }

    func clearLabels(for urls: [URL]) {
        var changed = false
        for url in urls where fileLabels.removeValue(forKey: url.standardizedFileURL.path) != nil {
            changed = true
        }
        if changed { save() }
    }

    func name(of label: SoundLabel) -> String {
        let index = label.rawValue
        guard index < labelNames.count, !labelNames[index].isEmpty else { return label.defaultName }
        return labelNames[index]
    }

    /// An empty name puts the colour's own name back.
    func renameLabel(_ label: SoundLabel, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = labelNames + Array(repeating: "", count: max(0, SoundLabel.allCases.count - labelNames.count))
        let stored = name == label.defaultName ? "" : name
        guard names[label.rawValue] != stored else { return }
        names[label.rawValue] = stored
        labelNames = names
        save()
    }

    // MARK: Collections

    func collection(id: SavedCollection.ID) -> SavedCollection? {
        collections.first { $0.id == id }
    }

    /// Creates an empty collection with a name that isn't taken yet.
    func addCollection(named name: String = "Untitled Collection") -> SavedCollection {
        let collection = SavedCollection(id: UUID(), name: uniqueCollectionName(name), files: [])
        collections.append(collection)
        save()
        return collection
    }

    func renameCollection(id: SavedCollection.ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = collections.firstIndex(where: { $0.id == id }),
              collections[index].name != name else { return }
        collections[index].name = name
        save()
    }

    func removeCollection(id: SavedCollection.ID) {
        collections.removeAll { $0.id == id }
        save()
    }

    func moveCollections(from source: IndexSet, to destination: Int) {
        collections.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Adds files to a collection, skipping any already in it, and returns the URLs that were added.
    /// Must be called while the files are accessible, so their bookmarks can be created.
    @discardableResult
    func addFiles(_ urls: [URL], toCollection id: SavedCollection.ID) -> [URL] {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return [] }
        var paths = Set(collections[index].files.map(\.path))
        var added: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !paths.contains(path), let bookmark = try? url.bookmarkData(options: Self.bookmarkOptions) else { continue }
            collections[index].files.append(SavedFile(path: path, bookmark: bookmark, added: .now))
            paths.insert(path)
            added.append(url)
        }
        if !added.isEmpty { save() }
        return added
    }

    func removeFiles(_ urls: [URL], fromCollection id: SavedCollection.ID) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        let paths = Set(urls.map(\.standardizedFileURL.path))
        let count = collections[index].files.count
        collections[index].files.removeAll { paths.contains($0.path) }
        if collections[index].files.count != count { save() }
    }

    /// Resolves every file in a collection, along with the names of any that can no longer be found.
    /// Files that have moved since they were added are followed, and their stored paths updated.
    /// The caller is responsible for starting security-scoped access.
    func resolveFiles(inCollection id: SavedCollection.ID) -> (found: [URL], missing: [String]) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return ([], []) }
        var found: [URL] = []
        var missing: [String] = []
        var changed = false
        for (fileIndex, file) in collections[index].files.enumerated() {
            guard let (url, isStale) = Self.resolve(file.bookmark) else {
                missing.append(URL(filePath: file.path).lastPathComponent)
                continue
            }
            found.append(url)
            let path = url.standardizedFileURL.path
            if path != file.path {
                collections[index].files[fileIndex].path = path
                changed = true
            }
            if isStale {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let fresh = try? url.bookmarkData(options: Self.bookmarkOptions) {
                    collections[index].files[fileIndex].bookmark = fresh
                    changed = true
                }
            }
        }
        if changed { save() }
        return (found, missing)
    }

    /// Paths of a collection's files, as they were when added.
    func paths(inCollection id: SavedCollection.ID) -> Set<String> {
        Set(collection(id: id)?.files.map(\.path) ?? [])
    }

    /// "Drums", then "Drums 2", "Drums 3"… as Finder names copies.
    private func uniqueCollectionName(_ name: String) -> String {
        let taken = Set(collections.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    // MARK: Persistence

    private struct Stored: Codable {
        var folders: [SavedFolder]
        var favourites: [SavedFile]
        /// Missing from libraries saved before collections existed.
        var collections: [SavedCollection]?
        /// Missing from libraries saved before labels existed.
        var fileLabels: [String: Set<SoundLabel>]?
        var labelNames: [String]?
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
        collections = stored.collections ?? []
        fileLabels = stored.fileLabels ?? [:]
        labelNames = stored.labelNames ?? []
        favouritePaths = Set(stored.favourites.map(\.path))
    }

    private func save() {
        let stored = Stored(folders: folders, favourites: favourites, collections: collections,
                            fileLabels: fileLabels, labelNames: labelNames)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
