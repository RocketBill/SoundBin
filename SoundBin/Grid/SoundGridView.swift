import AppKit
import Observation
import SwiftUI

/// Hosts the AppKit grid inside SwiftUI. NSCollectionView handles thousands of tiles smoothly and
/// gives native selection, keyboard focus and drag-out for free.
struct SoundGridView: NSViewRepresentable {
    let model: AppModel
    let sections: [FileSection]
    let version: Int
    let source: BrowseSource?
    let tileWidth: CGFloat
    let showsHeaders: Bool
    let showsArtwork: Bool
    let bottomInset: CGFloat

    func makeCoordinator() -> SoundGridController {
        SoundGridController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            sections: sections, version: version, source: source,
            tileWidth: tileWidth, showsHeaders: showsHeaders, showsArtwork: showsArtwork, bottomInset: bottomInset
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: SoundGridController) {
        coordinator.invalidate()
    }
}

nonisolated struct PlaybackSnapshot: Equatable, Sendable {
    var url: URL?
    var isPlaying = false
    var progress: Double = 0
}

final class SoundGridController: NSObject, NSCollectionViewDelegate, SoundCollectionViewDelegate {
    let model: AppModel
    let scrollView = NSScrollView()
    let collectionView = SoundCollectionView()

    private var dataSource: NSCollectionViewDiffableDataSource<String, AudioFile>!
    private var sections: [FileSection] = []
    private var indexPaths: [URL: IndexPath] = [:]
    private var version = -1
    private var source: BrowseSource?
    private var tileWidth: CGFloat = 190
    private var showsHeaders = false
    private var showsArtwork = false
    private var bottomInset: CGFloat = 0
    /// Columns in the current layout, used for up/down arrow movement.
    private var columns = 1
    /// Where keyboard movement continues from; the most recently clicked or moved-to tile.
    private var cursor: IndexPath?
    private var playback = PlaybackSnapshot()
    /// The sound the selection last followed, so the highlight moves once per new sound rather than every tick.
    private var followedURL: URL?
    private var observers: [Task<Void, Never>] = []

    private static let sideInset: CGFloat = 20
    private static let spacing: CGFloat = 12

    init(model: AppModel) {
        self.model = model
        super.init()

        collectionView.collectionViewLayout = makeLayout()
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = self
        collectionView.soundDelegate = self
        collectionView.register(SoundTileItem.self, forItemWithIdentifier: SoundTileItem.identifier)
        collectionView.register(SectionHeaderView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: SectionHeaderView.identifier)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)

        // The collection view can outlive this controller briefly while SwiftUI tears the grid down,
        // so these callbacks hold it weakly.
        dataSource = NSCollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, file in
            let item = collectionView.makeItem(withIdentifier: SoundTileItem.identifier, for: indexPath) as! SoundTileItem
            self?.configure(item, with: file)
            return item
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeaderView.identifier,
                                                              for: indexPath) as! SectionHeaderView
            self?.configure(header, section: indexPath.section)
            return header
        }

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = true

        observePlayer()
        observeMarks()
    }

    func invalidate() {
        observers.forEach { $0.cancel() }
        observers = []
    }

    // MARK: Updates from SwiftUI

    func update(sections: [FileSection], version: Int, source: BrowseSource?,
                tileWidth: CGFloat, showsHeaders: Bool, showsArtwork: Bool, bottomInset: CGFloat) {
        var layoutChanged = false
        if showsArtwork != self.showsArtwork {
            self.showsArtwork = showsArtwork
            for case let item as SoundTileItem in collectionView.visibleItems() {
                if let file = item.file { configure(item, with: file) }
            }
        }
        if tileWidth != self.tileWidth {
            self.tileWidth = tileWidth
            layoutChanged = true
        }
        if showsHeaders != self.showsHeaders || bottomInset != self.bottomInset {
            self.showsHeaders = showsHeaders
            self.bottomInset = bottomInset
            scrollView.scrollerInsets.bottom = bottomInset
            layoutChanged = true
        }

        if version != self.version {
            let sourceChanged = source != self.source
            let sectionCountChanged = sections.count != self.sections.count
            self.version = version
            self.source = source
            self.sections = sections
            apply(sections, animated: !sourceChanged)
            if sourceChanged {
                cursor = nil
                scrollToTop()
                focusGrid()
            }
            layoutChanged = layoutChanged || sectionCountChanged
        }

        if layoutChanged {
            collectionView.collectionViewLayout?.invalidateLayout()
        }
    }

    private func apply(_ sections: [FileSection], animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<String, AudioFile>()
        indexPaths = [:]
        for (sectionIndex, section) in sections.enumerated() {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.files, toSection: section.id)
            for (itemIndex, file) in section.files.enumerated() {
                indexPaths[file.url] = IndexPath(item: itemIndex, section: sectionIndex)
            }
        }

        // Animating thousands of moves costs more than it shows; small changes (search, collapse) animate.
        let small = snapshot.numberOfItems < 1500 && dataSource.snapshot().numberOfItems < 1500
        dataSource.apply(snapshot, animatingDifferences: animated && small)

        refreshVisibleHeaders()
        restoreSelection()
    }

    /// Moves keyboard focus to the grid so arrow keys work straight after opening a folder.
    /// Deferred because the grid may not be in a window yet, and the sidebar list claims focus on click.
    private func focusGrid() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = collectionView.window, !(window.firstResponder is NSText) else { return }
            window.makeFirstResponder(collectionView)
        }
    }

    private func restoreSelection() {
        let wanted = Set(model.selection.compactMap { indexPaths[$0] })
        if collectionView.selectionIndexPaths != wanted {
            collectionView.selectionIndexPaths = wanted
        }
        if let cursor, !wanted.contains(cursor) { self.cursor = wanted.max() }
    }

    private func scrollToTop() {
        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: -scrollView.contentInsets.left, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: Layout

    private func makeLayout() -> NSCollectionViewLayout {
        let configuration = NSCollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .vertical
        return NSCollectionViewCompositionalLayout(sectionProvider: { [weak self] index, environment in
            self?.layoutSection(at: index, environment: environment)
        }, configuration: configuration)
    }

    private func layoutSection(at index: Int, environment: any NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let spacing = Self.spacing
        let available = max(tileWidth, environment.container.effectiveContentSize.width - Self.sideInset * 2)
        let columns = max(1, Int((available + spacing) / (tileWidth + spacing)))
        self.columns = columns
        // Stretch tiles to fill the row so the grid has no ragged right edge.
        let width = ((available - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        let height = SoundTileView.height(forWidth: width)

        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .absolute(width), heightDimension: .absolute(height)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
            subitem: item, count: columns)
        group.interItemSpacing = .fixed(spacing)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        let isLast = index == sections.count - 1
        section.contentInsets = NSDirectionalEdgeInsets(
            top: showsHeaders ? 4 : 16,
            leading: Self.sideInset,
            bottom: isLast ? 24 + bottomInset : 20,
            trailing: Self.sideInset)

        if showsHeaders {
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                   heightDimension: .absolute(SectionHeaderView.height)),
                elementKind: NSCollectionView.elementKindSectionHeader,
                alignment: .top)
            header.pinToVisibleBounds = true
            header.zIndex = 2
            section.boundarySupplementaryItems = [header]
            section.supplementariesFollowContentInsets = false
        }
        return section
    }

    // MARK: Cells

    private func configure(_ item: SoundTileItem, with file: AudioFile) {
        item.configure(with: file, isFavourite: model.isFavourite(file), labels: model.labels(of: file), waveforms: model.waveforms,
                       artworks: showsArtwork ? model.artworks : nil)
        if file.url == playback.url {
            item.setPlayback(progress: playback.progress, isPlaying: playback.isPlaying)
        } else {
            item.setPlayback(progress: nil, isPlaying: false)
        }
    }

    private func configure(_ header: SectionHeaderView, section index: Int) {
        guard sections.indices.contains(index) else { return }
        let section = sections[index]
        let symbol = section.id.isEmpty && model.source != .favourites ? "folder.fill" : "folder"
        header.configure(title: section.title, count: section.matchCount,
                         isCollapsed: section.isCollapsed, symbolName: symbol)
        let sectionID = section.id
        header.onToggle = { [weak self] in self?.model.toggleCollapsed(sectionID) }
    }

    private func refreshVisibleHeaders() {
        let kind = NSCollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            if let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? SectionHeaderView {
                configure(header, section: indexPath.section)
            }
        }
    }

    private func tile(for url: URL) -> SoundTileItem? {
        guard let indexPath = indexPaths[url] else { return nil }
        return collectionView.item(at: indexPath) as? SoundTileItem
    }

    private func file(at indexPath: IndexPath) -> AudioFile? {
        dataSource.itemIdentifier(for: indexPath)
    }

    // MARK: Observing the model

    private func observePlayer() {
        let player = model.player
        observers.append(Task { [weak self] in
            let snapshots = Observations {
                PlaybackSnapshot(url: player.currentFile?.url, isPlaying: player.isPlaying, progress: player.progress)
            }
            for await snapshot in snapshots {
                self?.applyPlayback(snapshot)
            }
        })
    }

    /// Favourite stars and label dots change without the files changing, so visible tiles are updated in place.
    private func observeMarks() {
        let library = model.library
        observers.append(Task { [weak self] in
            for await _ in Observations({ (library.favouritePaths, library.fileLabels) }) {
                self?.refreshMarks()
            }
        })
    }

    private func applyPlayback(_ snapshot: PlaybackSnapshot) {
        // A tile shows progress while its sound plays or is paused part-way through.
        var shown = snapshot
        if !snapshot.isPlaying, snapshot.progress == 0 { shown.url = nil }

        if shown.url != playback.url, let previous = playback.url {
            tile(for: previous)?.setPlayback(progress: nil, isPlaying: false)
        }
        playback = shown
        if let url = shown.url {
            tile(for: url)?.setPlayback(progress: shown.progress, isPlaying: shown.isPlaying)
        }

        if let url = snapshot.url, url != followedURL {
            followedURL = url
            selectPlaying(url)
        }
    }

    /// Moves the highlight to a sound that started playing without being selected (Play Next, for one),
    /// leaving the selection alone when the sound is already part of it.
    private func selectPlaying(_ url: URL) {
        guard !model.selection.contains(url), let indexPath = indexPaths[url] else { return }
        collectionView.selectionIndexPaths = [indexPath]
        cursor = indexPath
        syncSelection()
        scrollToReveal(indexPath)
    }

    private func refreshMarks() {
        for case let item as SoundTileItem in collectionView.visibleItems() {
            if let file = item.file {
                item.tile.isFavourite = model.isFavourite(file)
                item.tile.labels = model.labels(of: file)
            }
        }
    }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        syncSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncSelection()
    }

    private func syncSelection() {
        let selected = Set(collectionView.selectionIndexPaths.compactMap { file(at: $0)?.url })
        if model.selection != selected {
            model.selection = selected
        }
    }

    // MARK: Drag out

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        file(at: indexPath)?.url as NSURL?
    }

    // MARK: SoundCollectionViewDelegate

    func soundCollectionView(_ view: SoundCollectionView, mouseDownOnItemAt indexPath: IndexPath, with event: NSEvent) -> Bool {
        guard let file = file(at: indexPath) else { return false }
        if let item = view.item(at: indexPath) as? SoundTileItem,
           item.tile.isStarHit(at: item.view.convert(event.locationInWindow, from: nil)) {
            model.toggleFavourite([file])
            return true
        }

        let modifiers = event.modifierFlags.intersection([.command, .shift])
        if modifiers.isEmpty, event.clickCount == 1, model.playOnClick {
            model.player.toggle(file)
        }
        if modifiers.isEmpty { cursor = indexPath }
        return false
    }

    func soundCollectionView(_ view: SoundCollectionView, move direction: MoveDirection, extendingSelection: Bool) {
        let origin = cursor ?? collectionView.selectionIndexPaths.max()
        guard let target = indexPath(movingFrom: origin, direction: direction) else { return }

        if extendingSelection {
            collectionView.selectItems(at: [target], scrollPosition: [])
        } else {
            collectionView.selectionIndexPaths = [target]
        }
        cursor = target
        syncSelection()
        scrollToReveal(target)

        if model.playOnArrowKeys, let file = file(at: target) {
            model.play(file)
        }
    }

    func soundCollectionView(_ view: SoundCollectionView, menuForItemAt indexPath: IndexPath) -> NSMenu? {
        guard let file = file(at: indexPath) else { return nil }
        if !collectionView.selectionIndexPaths.contains(indexPath) {
            collectionView.selectionIndexPaths = [indexPath]
            cursor = indexPath
            syncSelection()
        }
        let targets = model.selectedFiles
        let player = model.player
        let isPlayingThis = player.isPlaying && player.currentFile?.id == file.id
        let allFavourites = targets.allSatisfy(model.isFavourite)

        let menu = NSMenu()
        menu.addItem(ActionMenuItem(isPlayingThis ? "Stop" : "Play", symbol: isPlayingThis ? "stop.fill" : "play.fill") { [model] in
            model.player.toggle(file)
        })
        menu.addItem(ActionMenuItem(allFavourites ? "Remove from Favourites" : "Add to Favourites",
                                    symbol: allFavourites ? "star.slash" : "star") { [model] in
            model.toggleFavourite(targets)
        })
        menu.addItem(collectionMenuItem(for: targets))
        if case .collection = model.source {
            menu.addItem(ActionMenuItem("Remove from Collection", symbol: "minus.circle") { [model] in
                model.removeFromCollection(targets)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Show in Finder", symbol: "folder") { [model] in
            model.revealInFinder(targets)
        })
        menu.addItem(ActionMenuItem(targets.count > 1 ? "Copy \(targets.count) Files" : "Copy", symbol: "doc.on.doc") { [model] in
            model.copyToPasteboard(targets)
        })
        menu.addItem(.separator())
        menu.addItem(labelMenuItem(for: targets))
        return menu
    }

    private func labelMenuItem(for targets: [AudioFile]) -> NSMenuItem {
        let applied = targets.map(model.labels(of:))
        var states: [SoundLabel: LabelMenuView.State] = [:]
        for label in SoundLabel.allCases {
            let count = applied.count { $0.contains(label) }
            states[label] = count == 0 ? .off : (count == targets.count ? .on : .mixed)
        }
        let item = NSMenuItem()
        item.view = LabelMenuView(states: states, name: { [model] in model.library.name(of: $0) }) { [model] label in
            model.toggleLabel(label, for: targets)
        }
        return item
    }

    /// "Add to Collection" with a submenu of every collection besides the one being shown.
    private func collectionMenuItem(for targets: [AudioFile]) -> NSMenuItem {
        let urls = targets.map(\.url)
        let submenu = NSMenu()
        for collection in model.library.collections where model.source != .collection(collection.id) {
            submenu.addItem(ActionMenuItem(collection.name, symbol: "rectangle.stack") { [model] in
                model.addToCollection(urls, collection.id)
            })
        }
        if !submenu.items.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(ActionMenuItem("New Collection with Selection", symbol: "rectangle.stack.badge.plus") { [model] in
            model.newCollection(with: targets)
        })
        let item = NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    func soundCollectionViewTogglePlayback(_ view: SoundCollectionView) {
        model.togglePlaybackForSelection()
    }

    func soundCollectionViewPlaySelection(_ view: SoundCollectionView) {
        if let file = model.selectedFiles.first { model.play(file) }
    }

    func soundCollectionViewStop(_ view: SoundCollectionView) {
        model.player.stop()
    }

    func soundCollectionViewToggleFavourite(_ view: SoundCollectionView) {
        model.toggleFavourite(model.selectedFiles)
    }

    func soundCollectionViewCopy(_ view: SoundCollectionView) {
        model.copyToPasteboard(model.selectedFiles)
    }

    func soundCollectionViewDelete(_ view: SoundCollectionView) -> Bool {
        guard case .collection = model.source, !model.selection.isEmpty else { return false }
        model.removeFromCollection(model.selectedFiles)
        return true
    }

    // MARK: Keyboard movement

    private func indexPath(movingFrom origin: IndexPath?, direction: MoveDirection) -> IndexPath? {
        let sectionCount = collectionView.numberOfSections
        func count(_ section: Int) -> Int { collectionView.numberOfItems(inSection: section) }
        func nextSection(after section: Int) -> Int? {
            (section + 1..<sectionCount).first { count($0) > 0 }
        }
        func previousSection(before section: Int) -> Int? {
            (0..<section).reversed().first { count($0) > 0 }
        }

        guard let origin, origin.section < sectionCount, origin.item < count(origin.section) else {
            return nextSection(after: -1).map { IndexPath(item: 0, section: $0) }
        }
        let section = origin.section
        let item = origin.item
        let itemCount = count(section)
        let column = item % columns

        switch direction {
        case .right:
            if item + 1 < itemCount { return IndexPath(item: item + 1, section: section) }
            return nextSection(after: section).map { IndexPath(item: 0, section: $0) }
        case .left:
            if item > 0 { return IndexPath(item: item - 1, section: section) }
            return previousSection(before: section).map { IndexPath(item: count($0) - 1, section: $0) }
        case .down:
            if item + columns < itemCount { return IndexPath(item: item + columns, section: section) }
            let lastRowStart = (itemCount - 1) / columns * columns
            if item < lastRowStart { return IndexPath(item: itemCount - 1, section: section) }
            return nextSection(after: section).map { IndexPath(item: min(column, count($0) - 1), section: $0) }
        case .up:
            if item - columns >= 0 { return IndexPath(item: item - columns, section: section) }
            return previousSection(before: section).map { previous in
                let previousCount = count(previous)
                let lastRowStart = (previousCount - 1) / columns * columns
                return IndexPath(item: min(lastRowStart + column, previousCount - 1), section: previous)
            }
        }
    }

    /// Scrolls just enough to show the tile clear of the pinned header and the transport bar.
    private func scrollToReveal(_ indexPath: IndexPath) {
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let top = (showsHeaders ? SectionHeaderView.height : 0) + 8
        let bottom = bottomInset + 8
        collectionView.scrollToVisible(NSRect(x: frame.minX, y: frame.minY - top,
                                              width: frame.width, height: frame.height + top + bottom))
    }
}

/// Menu item that runs a closure, for building context menus without selector plumbing.
nonisolated final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
