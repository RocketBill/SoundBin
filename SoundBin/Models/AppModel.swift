import AppKit
import Observation

nonisolated enum BrowseSource: Hashable, Sendable {
    case favourites
    case folder(SavedFolder.ID)

    /// A stable string form, used in preferences and cache file names.
    var storageKey: String {
        switch self {
        case .favourites: "favourites"
        case .folder(let id): id.uuidString
        }
    }

    init?(storageKey: String) {
        if storageKey == "favourites" {
            self = .favourites
        } else if let id = UUID(uuidString: storageKey) {
            self = .folder(id)
        } else {
            return nil
        }
    }
}

/// How a listing is sorted and titled. A cached arrangement is reused only while these still match.
nonisolated struct Arrangement: Equatable, Sendable {
    var key: SortKey
    var ascending: Bool
    var rootTitle: String
}

nonisolated enum Preferences {
    static let playOnClick = "playOnClick"
    static let playOnArrowKeys = "playOnArrowKeys"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [playOnClick: true, playOnArrowKeys: true])
    }
}

/// App-wide state: what's being browsed, how it's arranged, and what's selected.
@Observable
final class AppModel {
    let library = Library()
    let player = AudioPlayer()
    @ObservationIgnored let waveforms = BackgroundLoader<Waveform>(
        maxConcurrent: max(2, ProcessInfo.processInfo.activeProcessorCount - 2),
        fallback: .silent, load: WaveformCache.load)
    /// Cover art is bigger than a waveform, so only a few hundred are kept in memory; the rest come back from disk.
    @ObservationIgnored let artworks = BackgroundLoader<Artwork>(
        maxConcurrent: 3, memoryLimit: 300, fallback: .none, load: ArtworkCache.load)

    var source: BrowseSource? {
        didSet {
            guard source != oldValue else { return }
            saveLastSource()
            reload()
        }
    }

    /// Sections ready for the grid: filtered by search and the subfolder toggle, with collapsed ones emptied.
    private(set) var sections: [FileSection] = []
    /// Bumped whenever `sections` changes, so the grid can skip diffing when nothing moved.
    private(set) var sectionsVersion = 0
    private(set) var totalCount = 0
    private(set) var visibleCount = 0
    private(set) var isScanning = false
    private(set) var scannedCount = 0
    private(set) var folderIsMissing = false
    private(set) var rootTitle = ""

    var searchText = "" {
        didSet { if searchText != oldValue { applyFilter() } }
    }

    var sortKey: SortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: "sortKey") ?? "") ?? .name {
        didSet {
            UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey")
            rearrange()
        }
    }

    var sortAscending: Bool = UserDefaults.standard.object(forKey: "sortAscending") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: "sortAscending")
            rearrange()
        }
    }

    var includeSubfolders: Bool = UserDefaults.standard.object(forKey: "includeSubfolders") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(includeSubfolders, forKey: "includeSubfolders")
            applyFilter()
        }
    }

    var tileSize: Double = UserDefaults.standard.object(forKey: "tileSize") as? Double ?? 190 {
        didSet { UserDefaults.standard.set(tileSize, forKey: "tileSize") }
    }

    /// Show cover art embedded in files (MP3, M4A, FLAC…) on their tiles, with the waveform in a strip below.
    var showsArtwork: Bool = UserDefaults.standard.object(forKey: "showsArtwork") as? Bool ?? true {
        didSet {
            guard showsArtwork != oldValue else { return }
            UserDefaults.standard.set(showsArtwork, forKey: "showsArtwork")
            if showsArtwork {
                artworks.prefetch(arrangedSections.flatMap(\.files))
            } else {
                artworks.cancelPrefetch()
            }
        }
    }

    /// URLs of the selected tiles. The grid owns selection; this mirrors it for menus and commands.
    var selection: Set<URL> = []

    static let tileSizeRange: ClosedRange<Double> = 140...340

    /// A source's files as last seen, so switching back to it shows them straight away.
    private struct Listing {
        /// The folder the files came from; nil for favourites.
        var rootPath: String?
        var files: [AudioFile]
        /// Sections sorted for `arrangement`, or nil if they need sorting again.
        var arranged: [FileSection]?
        var arrangement: Arrangement?
    }

    @ObservationIgnored private var files: [AudioFile] = []
    @ObservationIgnored private var arrangedSections: [FileSection] = []
    @ObservationIgnored private var collapsedSections: Set<String> = []
    @ObservationIgnored private var listings: [BrowseSource: Listing] = [:]
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var scopedURLs: [URL] = []
    @ObservationIgnored private var scopedPaths: Set<String> = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var arrangeTask: Task<Void, Never>?
    /// Set when the folder changes during a scan, so another scan follows it.
    @ObservationIgnored private var needsRescan = false
    /// Identifies the current load, so results from a superseded scan are dropped.
    @ObservationIgnored private var loadGeneration = 0

    init() {
        Preferences.registerDefaults()
        source = restoreLastSource()
        reload()
        preloadListings()
    }

    // MARK: Presentation

    var title: String {
        rootTitle.isEmpty ? "SoundBin" : rootTitle
    }

    var subtitle: String {
        if isScanning { return "Scanning…" }
        guard source != nil, !folderIsMissing else { return "" }
        if !searchText.isEmpty { return "\(visibleCount.formatted()) of \(Format.soundCount(totalCount))" }
        return Format.soundCount(visibleCount)
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Headers only add noise when everything lives in one folder.
    var showsSectionHeaders: Bool {
        if source == .favourites { return true }
        if sections.count > 1 { return true }
        return sections.first.map { !$0.id.isEmpty } ?? false
    }

    /// True when files exist only in subfolders and the subfolder toggle is hiding them.
    var subfoldersAreHidingEverything: Bool {
        !includeSubfolders && totalCount > 0 && !arrangedSections.contains { $0.id.isEmpty }
    }

    var selectedFiles: [AudioFile] {
        guard !selection.isEmpty else { return [] }
        return sections.flatMap(\.files).filter { selection.contains($0.url) }
    }

    var playOnClick: Bool {
        get {
            access(keyPath: \.playOnClick)
            return UserDefaults.standard.bool(forKey: Preferences.playOnClick)
        }
        set {
            withMutation(keyPath: \.playOnClick) {
                UserDefaults.standard.set(newValue, forKey: Preferences.playOnClick)
            }
        }
    }

    var playOnArrowKeys: Bool {
        UserDefaults.standard.bool(forKey: Preferences.playOnArrowKeys)
    }

    // MARK: Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of sounds to browse."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Opens a folder the user picked, dropped or sent from Finder, adding it to the sidebar.
    func open(_ url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDirectory, let folder = library.addFolder(url) else { return }
        if source == .folder(folder.id) {
            reload()
        } else {
            source = .folder(folder.id)
        }
    }

    func removeFolder(_ id: SavedFolder.ID) {
        if source == .folder(id) { source = nil }
        library.removeFolder(id: id)
        listings[.folder(id)] = nil
        ListingStore.remove(.folder(id))
    }

    // MARK: Loading

    private var arrangement: Arrangement {
        Arrangement(key: sortKey, ascending: sortAscending, rootTitle: rootTitle)
    }

    private var rootPath: String? {
        root?.standardizedFileURL.path
    }

    /// Switches to the current source: shows its last known files straight away if there are any,
    /// then rescans in the background and folds in whatever has changed.
    func reload() {
        loadTask?.cancel()
        loadTask = nil
        arrangeTask?.cancel()
        watcher?.stop()
        watcher = nil
        needsRescan = false
        endAccess()
        waveforms.cancelPrefetch()
        artworks.cancelPrefetch()
        loadGeneration += 1

        files = []
        arrangedSections = []
        collapsedSections = []
        selection = []
        root = nil
        totalCount = 0
        scannedCount = 0
        folderIsMissing = false
        isScanning = false
        if !searchText.isEmpty { searchText = "" }

        switch source {
        case nil:
            rootTitle = ""
            applyFilter()
            return

        case .folder(let id):
            guard let folder = library.folder(id: id) else {
                source = nil
                return
            }
            rootTitle = folder.name
            guard let url = library.resolve(folder) else {
                folderIsMissing = true
                applyFilter()
                return
            }
            beginAccess(url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                folderIsMissing = true
                applyFilter()
                return
            }
            root = url
            watcher = FolderWatcher(url: url) { [weak self] in self?.rescan() }

        case .favourites:
            rootTitle = "Favourites"
        }

        let listing = cachedListing()
        if let listing {
            show(listing.files, arranged: listing.arranged ?? Self.arrangeNow(listing.files, arrangement))
            rememberListing(saving: false)
        } else {
            isScanning = true
            applyFilter()
        }
        // Scanning starts access to favourites, so it has to come before any waveform loads.
        rescan()
        if listing != nil {
            prefetch(arrangedSections.flatMap(\.files))
        }
    }

    /// Looks for changes in the current source without disturbing the view: search, collapsed groups,
    /// selection and scroll position all stay put. Files seen before aren't read again, so this
    /// costs little more than listing the folder.
    func rescan() {
        guard let source else { return }
        if folderIsMissing {
            reload()
            return
        }
        if loadTask != nil {
            needsRescan = true
            return
        }
        let generation = loadGeneration
        let progress: @Sendable (Int) -> Void = { [weak self] count in
            Task { @MainActor in self?.updateScanProgress(count, generation: generation) }
        }

        switch source {
        case .folder(let id):
            guard let root, let rootPath else { return }
            guard FileManager.default.fileExists(atPath: root.path) else {
                reload()
                return
            }
            let known = files
            loadTask = Task { [weak self] in
                var known = known
                // First visit since launch: show what was there last time while the scan runs.
                if known.isEmpty, let stored = await ListingStore.load(source, root: rootPath) {
                    guard let self, generation == loadGeneration else { return }
                    await update(with: stored, generation: generation, save: false)
                    known = stored
                }
                let found = await FolderScanner.scan(root: root, reusing: known, progress: progress)
                guard let self, !Task.isCancelled, generation == loadGeneration else { return }
                library.setSoundCount(found.count, for: id)
                await finishScan(found, generation: generation)
            }

        case .favourites:
            let urls = library.resolveFavourites()
            urls.forEach(beginAccess)
            let known = files.isEmpty ? (listings[.favourites]?.files ?? []) : files
            loadTask = Task { [weak self] in
                let found = await FolderScanner.read(files: urls, reusing: known)
                guard let self, !Task.isCancelled, generation == loadGeneration else { return }
                await finishScan(found, generation: generation)
            }
        }
    }

    private func updateScanProgress(_ count: Int, generation: Int) {
        guard generation == loadGeneration, isScanning else { return }
        scannedCount = count
    }

    private func finishScan(_ found: [AudioFile], generation: Int) async {
        await update(with: found, generation: generation, save: true)
        guard generation == loadGeneration else { return }
        loadTask = nil
        if needsRescan {
            needsRescan = false
            rescan()
        }
    }

    /// Shows a scan's result, or does nothing if the files are the same ones already on screen.
    private func update(with found: [AudioFile], generation: Int, save: Bool) async {
        let previous = files
        if !isScanning, found.count == previous.count, Set(found) == Set(previous) { return }
        let arranged = await Self.arrange(found, arrangement)
        guard generation == loadGeneration else { return }
        show(found, arranged: arranged)
        rememberListing(saving: save)

        if previous.isEmpty {
            prefetch(arranged.flatMap(\.files))
        } else {
            let old = Set(previous)
            let added = arranged.flatMap(\.files).filter { !old.contains($0) }
            waveforms.prefetchMore(added)
            if showsArtwork { artworks.prefetchMore(added) }
        }
    }

    private func show(_ files: [AudioFile], arranged: [FileSection]) {
        self.files = files
        totalCount = files.count
        arrangedSections = arranged
        isScanning = false
        applyFilter()
    }

    /// Warms waveforms (and artwork) in display order, so the top of the grid is ready first.
    private func prefetch(_ ordered: [AudioFile]) {
        waveforms.prefetch(ordered)
        if showsArtwork { artworks.prefetch(ordered) }
    }

    // MARK: Cached listings

    /// The current source's files from earlier in this session, if they're still valid.
    private func cachedListing() -> Listing? {
        guard let source, var listing = listings[source], listing.rootPath == rootPath else { return nil }
        if source == .favourites {
            let count = listing.files.count
            listing.files.removeAll { !isFavourite($0) }
            if listing.files.count != count { listing.arranged = nil }
        }
        if listing.arrangement != arrangement { listing.arranged = nil }
        return listing
    }

    /// Keeps what's on screen for instant switching back, and optionally on disk for next launch.
    private func rememberListing(saving: Bool) {
        guard let source else { return }
        listings[source] = Listing(rootPath: rootPath, files: files, arranged: arrangedSections, arrangement: arrangement)
        if saving {
            let (files, rootPath) = (files, rootPath)
            Task { await ListingStore.save(files, for: source, root: rootPath) }
        }
    }

    /// Reads the other sidebar entries' saved listings in the background, so the first switch to
    /// each one after launch is instant too.
    private func preloadListings() {
        let others: [(BrowseSource, String?, String)] = library.folders.map { (.folder($0.id), $0.path, $0.name) }
            + [(.favourites, nil, "Favourites")]
        Task { [weak self] in
            for (source, rootPath, title) in others {
                guard let self else { return }
                guard source != self.source, listings[source] == nil,
                      let files = await ListingStore.load(source, root: rootPath) else { continue }
                let arrangement = Arrangement(key: sortKey, ascending: sortAscending, rootTitle: title)
                let arranged = await Self.arrange(files, arrangement)
                guard source != self.source, listings[source] == nil else { continue }
                listings[source] = Listing(rootPath: rootPath, files: files, arranged: arranged, arrangement: arrangement)
            }
        }
    }

    // MARK: Sorting

    /// Re-sorts after the sort order changes. Sorting large folders happens off the main actor.
    /// Other cached listings are re-sorted too, so switching to them stays instant.
    private func rearrange() {
        arrangeTask?.cancel()
        let generation = loadGeneration
        let (current, files, arrangement) = (source, files, arrangement)
        let others = listings.filter { $0.key != current }.map { ($0.key, $0.value.files, $0.value.arrangement?.rootTitle) }
        arrangeTask = Task { [weak self] in
            if !files.isEmpty {
                let arranged = await Self.arrange(files, arrangement)
                guard let self, !Task.isCancelled else { return }
                if generation == loadGeneration {
                    arrangedSections = arranged
                    applyFilter()
                    rememberListing(saving: false)
                }
            }
            for (source, files, title) in others {
                guard let rootTitle = title ?? self?.rootTitle(for: source) else { continue }
                let other = Arrangement(key: arrangement.key, ascending: arrangement.ascending, rootTitle: rootTitle)
                let arranged = await Self.arrange(files, other)
                guard let self, !Task.isCancelled else { return }
                guard source != self.source, listings[source]?.files == files else { continue }
                listings[source]?.arranged = arranged
                listings[source]?.arrangement = other
            }
        }
    }

    private func rootTitle(for source: BrowseSource) -> String? {
        switch source {
        case .favourites: "Favourites"
        case .folder(let id): library.folder(id: id)?.name
        }
    }

    @concurrent
    private nonisolated static func arrange(_ files: [AudioFile], _ arrangement: Arrangement) async -> [FileSection] {
        arrangeNow(files, arrangement)
    }

    private nonisolated static func arrangeNow(_ files: [AudioFile], _ arrangement: Arrangement) -> [FileSection] {
        FolderScanner.group(files, rootTitle: arrangement.rootTitle).map { section in
            var section = section
            section.files = sort(section.files, by: arrangement.key, ascending: arrangement.ascending)
            return section
        }
    }

    private nonisolated static func sort(_ files: [AudioFile], by key: SortKey, ascending: Bool) -> [AudioFile] {
        files.sorted { lhs, rhs in
            var order: ComparisonResult = switch key {
            case .name: .orderedSame
            case .duration: compare(lhs.duration, rhs.duration)
            case .dateModified: compare(lhs.modificationDate, rhs.modificationDate)
            case .size: compare(lhs.fileSize, rhs.fileSize)
            case .format: lhs.formatName.compare(rhs.formatName)
            }
            if order == .orderedSame {
                order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private nonisolated static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    // MARK: Filtering

    private func applyFilter() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsSubfolders = includeSubfolders || source == .favourites
        var result: [FileSection] = []
        var visible = 0

        for section in arrangedSections where showsSubfolders || section.id.isEmpty {
            let matches = query.isEmpty ? section.files : section.files.filter {
                $0.displayName.localizedStandardContains(query) || section.title.localizedStandardContains(query)
            }
            guard !matches.isEmpty else { continue }
            // Searching expands everything so matches are never hidden in a collapsed group.
            let isCollapsed = query.isEmpty && collapsedSections.contains(section.id)
            result.append(FileSection(
                id: section.id,
                title: section.title,
                files: isCollapsed ? [] : matches,
                matchCount: matches.count,
                isCollapsed: isCollapsed
            ))
            visible += matches.count
        }

        sections = result
        visibleCount = visible
        sectionsVersion += 1
        if !selection.isEmpty {
            let shown = Set(result.flatMap(\.files).map(\.url))
            selection.formIntersection(shown)
        }
    }

    func toggleCollapsed(_ sectionID: String) {
        if collapsedSections.contains(sectionID) {
            collapsedSections.remove(sectionID)
        } else {
            collapsedSections.insert(sectionID)
        }
        applyFilter()
    }

    // MARK: Actions

    func zoomIn() {
        tileSize = min(Self.tileSizeRange.upperBound, tileSize + 30)
    }

    func zoomOut() {
        tileSize = max(Self.tileSizeRange.lowerBound, tileSize - 30)
    }

    func isFavourite(_ file: AudioFile) -> Bool {
        library.isFavourite(file.url)
    }

    /// Stars the files, or unstars them if they're all starred already.
    func toggleFavourite(_ targets: [AudioFile]) {
        guard !targets.isEmpty else { return }
        let makeFavourite = !targets.allSatisfy(isFavourite)
        library.setFavourite(makeFavourite, for: targets.map(\.url))
        let changed = targets.filter { isFavourite($0) == makeFavourite }
        let changedURLs = Set(changed.map(\.url))

        if source == .favourites {
            guard !makeFavourite else { return }
            files.removeAll { changedURLs.contains($0.url) }
            totalCount = files.count
            arrangedSections = arrangedSections.compactMap { section in
                var section = section
                section.files.removeAll { changedURLs.contains($0.url) }
                return section.files.isEmpty ? nil : section
            }
            applyFilter()
            rememberListing(saving: true)
        } else if var listing = listings[.favourites] {
            // Keep the cached favourites in step, so switching to them is instant and up to date.
            if makeFavourite {
                let existing = Set(listing.files.map(\.url))
                listing.files += changed
                    .filter { !existing.contains($0.url) }
                    .map { $0.inFolder($0.url.deletingLastPathComponent().lastPathComponent) }
            } else {
                listing.files.removeAll { changedURLs.contains($0.url) }
            }
            listing.arranged = nil
            listings[.favourites] = listing
            let files = listing.files
            Task { await ListingStore.save(files, for: .favourites, root: nil) }
        }
    }

    func play(_ file: AudioFile) {
        player.play(file)
    }

    /// Space bar: stops the selected sound if it's playing, otherwise plays the first selected sound.
    func togglePlaybackForSelection() {
        if let file = selectedFiles.first {
            player.toggle(file)
        } else {
            player.togglePlayPause()
        }
    }

    func revealInFinder(_ targets: [AudioFile]) {
        guard !targets.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
    }

    func copyToPasteboard(_ targets: [AudioFile]) {
        guard !targets.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(targets.map { $0.url as NSURL })
    }

    func revealFolder(_ folder: SavedFolder) {
        guard let url = library.resolve(folder) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Caches

    @concurrent
    nonisolated func cacheSize() async -> Int64 {
        WaveformCache.directory.size() + ArtworkCache.directory.size()
    }

    func clearCaches() {
        waveforms.removeAllFromMemory()
        artworks.removeAllFromMemory()
        WaveformCache.directory.removeAll()
        ArtworkCache.directory.removeAll()
    }

    // MARK: Security scope

    private func beginAccess(_ url: URL) {
        guard !scopedPaths.contains(url.path), url.startAccessingSecurityScopedResource() else { return }
        scopedURLs.append(url)
        scopedPaths.insert(url.path)
    }

    private func endAccess() {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs = []
        scopedPaths = []
    }

    // MARK: Last source

    private func saveLastSource() {
        UserDefaults.standard.set(source?.storageKey, forKey: "lastSource")
    }

    private func restoreLastSource() -> BrowseSource? {
        guard let value = UserDefaults.standard.string(forKey: "lastSource"),
              let source = BrowseSource(storageKey: value)
        else { return nil }
        if case .folder(let id) = source, library.folder(id: id) == nil { return nil }
        return source
    }
}
