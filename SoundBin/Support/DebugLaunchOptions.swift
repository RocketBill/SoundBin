#if DEBUG
import AppKit
import SwiftUI

/// Development-only automation, compiled out of release builds.
///
///   -SBAppearance dark|light
///   -SBScript "open /path; wait 1; snap grid; key down; key space; snap playing; quit"
///
/// Script commands: open <path>, source favourites, wait <seconds>, snap <name>, key <name|char>,
/// click <section> <item>, search <text>, tile <width>, subfolders on|off, collapse <section>,
/// sort <key> [desc], drag <tile width>, quit.
/// Snapshots are written to the app container's tmp folder.
enum DebugLaunchOptions {
    static func apply(to model: AppModel) {
        let defaults = UserDefaults.standard
        if let appearance = defaults.string(forKey: "SBAppearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let script = defaults.string(forKey: "SBScript") {
            Task { await run(script, model: model) }
        }
    }

    private static func run(_ script: String, model: AppModel) async {
        try? await Task.sleep(for: .milliseconds(800))
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
        for line in script.split(separator: ";") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard let command = parts.first else { continue }
            let argument = parts.count > 1 ? parts[1] : ""
            print("[script] \(command) \(argument)")

            switch command {
            case "open":
                let start = ContinuousClock.now
                model.open(URL(filePath: argument, directoryHint: .isDirectory))
                print("[time] \(model.totalCount) files on screen immediately, scanning \(model.isScanning)")
                await waitForLoad(model)
                print("[time] scanned \(model.totalCount) files in \(ContinuousClock.now - start - .milliseconds(500))")
            case "clearcache":
                model.clearCaches()
            case "artwork":
                model.showsArtwork = argument == "on"
            case "waveforms":
                let start = ContinuousClock.now
                while !model.waveforms.debugIsIdle || !model.artworks.debugIsIdle {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                print("[time] \(model.waveforms.debugCachedCount) waveforms, \(model.artworks.debugCachedCount) artwork lookups ready after \(ContinuousClock.now - start)")
            case "source" where argument == "favourites":
                model.source = .favourites
                print("[time] \(model.totalCount) files on screen immediately, scanning \(model.isScanning)")
                await waitForLoad(model)
            case "sort":
                let parts = argument.split(separator: " ")
                model.sortKey = SortKey(rawValue: String(parts.first ?? "")) ?? .name
                model.sortAscending = parts.count < 2 || parts[1] != "desc"
            case "wait":
                try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
            case "snap" where argument.hasSuffix("-transport"):
                // Glass doesn't render offscreen; a solid backdrop stands in so the layout is visible.
                let renderer = ImageRenderer(content: TransportBar()
                    .environment(model)
                    .frame(width: 1000)
                    .padding(20)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
                renderer.scale = 2
                if let image = renderer.cgImage {
                    let url = URL(filePath: NSTemporaryDirectory()).appending(path: "\(argument).png")
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                    print("[script] wrote \(url.path)")
                }
            case "snap":
                snapshot(named: argument)
            case "key":
                sendKey(argument)
            case "click":
                let numbers = argument.split(separator: " ").compactMap { Int($0) }
                if numbers.count == 2 { click(section: numbers[0], item: numbers[1]) }
            case "seek":
                model.player.seek(to: Double(argument) ?? 0)
            case "loop":
                model.player.isLooping = argument == "on"
            case "playpause":
                model.player.togglePlayPause()
            case "playfile":
                if let file = model.sections.flatMap(\.files).first(where: { $0.displayName == argument }) {
                    model.play(file)
                }
            case "search":
                model.searchText = argument
            case "tile":
                model.tileSize = Double(argument) ?? model.tileSize
            case "drag":
                // Moves the tile size in small steps, like dragging the toolbar slider.
                let target = Double(argument) ?? model.tileSize
                let step: Double = target > model.tileSize ? 3 : -3
                while abs(target - model.tileSize) > abs(step) {
                    model.tileSize += step
                    try? await Task.sleep(for: .milliseconds(16))
                }
                model.tileSize = target
            case "subfolders":
                model.includeSubfolders = argument == "on"
            case "collapse":
                model.toggleCollapsed(argument)
            case "dump":
                dump(model)
            case "quit":
                NSApp.terminate(nil)
            default:
                print("[script] unknown command \(command)")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func waitForLoad(_ model: AppModel) async {
        try? await Task.sleep(for: .milliseconds(200))
        while model.isScanning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(500))
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }
    }

    private static func snapshot(named name: String) {
        // "snap grid-only" renders just the collection view, which avoids SwiftUI layers the renderer can't draw.
        let gridOnly = name.hasSuffix("-grid")
        let tileOnly = name.hasSuffix("-tile")
        guard let window = mainWindow else { return }
        let collectionView = findCollectionView(in: window.contentView)
        let target: NSView? = if tileOnly {
            collectionView?.visibleItems().min { $0.view.frame.minY < $1.view.frame.minY }?.view
        } else if gridOnly {
            collectionView?.enclosingScrollView
        } else {
            window.contentView?.superview
        }
        guard let frameView = target, let layer = frameView.layer else { return }
        frameView.layoutSubtreeIfNeeded()
        // Render the layer tree rather than using cacheDisplay, which skips layer-backed content.
        // Backdrop blurs (glass, sidebar material) don't render this way and appear flat.
        let scale = window.backingScaleFactor
        let size = frameView.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        var background = CGColor.black
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.scaleBy(x: scale, y: scale)
        if layer.contentsAreFlipped() || frameView.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        if gridOnly, let collectionView, let scrollView = collectionView.enclosingScrollView {
            // Composite tiles and headers individually; rendering the scroll view's tree in one pass
            // paints an opaque layer over the items.
            let kind = NSCollectionView.elementKindSectionHeader
            let headers = collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind)
                .compactMap { collectionView.supplementaryView(forElementKind: kind, at: $0) }
            for view in collectionView.visibleItems().map(\.view) + headers {
                guard let viewLayer = view.layer else { continue }
                let frame = view.convert(view.bounds, to: scrollView)
                context.saveGState()
                context.translateBy(x: frame.minX, y: frame.minY)
                viewLayer.render(in: context)
                context.restoreGState()
            }
        } else {
            layer.render(in: context)
        }
        guard let image = context.makeImage() else { return }
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "\(name).png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("[script] wrote \(url.path)")
    }

    private static func sendKey(_ name: String) {
        guard let window = mainWindow else { return }
        let keys: [String: (UInt16, String)] = [
            "up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "left": (123, "\u{F702}"),
            "right": (124, "\u{F703}"), "space": (49, " "), "escape": (53, "\u{1b}"),
            "return": (36, "\r"), "period": (47, "."),
        ]
        let (code, characters) = keys[name] ?? (0, name)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                window.sendEvent(event)
            }
        }
    }

    private static func click(section: Int, item: Int) {
        guard let window = mainWindow,
              let collectionView = findCollectionView(in: window.contentView),
              let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: item, section: section))?.frame
        else { return }
        // Aim at the waveform area, clear of the star in its corner.
        let point = collectionView.convert(NSPoint(x: frame.minX + frame.width * 0.3, y: frame.minY + 30), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    private static func dump(_ model: AppModel) {
        let player = model.player
        print("[dump] playing \(player.currentFile?.displayName ?? "-") isPlaying \(player.isPlaying) t \(String(format: "%.2f", player.currentTime))/\(String(format: "%.2f", player.duration)) loop \(player.isLooping) error \(player.lastError ?? "-")")
        print("[dump] selection \(model.selectedFiles.map(\.displayName)) favourites \(model.library.favourites.count) visible \(model.visibleCount)/\(model.totalCount) sections \(model.sections.map { "\($0.title)(\($0.files.count)\($0.isCollapsed ? ",collapsed" : ""))" })")
        guard let window = mainWindow, let collectionView = findCollectionView(in: window.contentView) else {
            print("[dump] no collection view")
            return
        }
        print("[dump] sections \(collectionView.numberOfSections), frame \(collectionView.frame), clip \(collectionView.enclosingScrollView?.contentView.bounds ?? .zero)")
        print("[dump] insets \(collectionView.enclosingScrollView?.contentInsets.top ?? -1), first responder \(String(describing: window.firstResponder))")
        for section in 0..<collectionView.numberOfSections {
            print("[dump]   section \(section): \(collectionView.numberOfItems(inSection: section)) items")
        }
        for case let item as SoundTileItem in collectionView.visibleItems().prefix(6) {
            print("[dump]   item \(item.file?.displayName ?? "-") frame \(item.view.frame) hidden \(item.view.isHidden) alpha \(item.view.alphaValue) waveform \(item.tile.waveformView.waveform != nil) artwork \(item.tile.artwork.map { "\($0.width)x\($0.height)" } ?? "-") super \(String(describing: item.view.superview.map { type(of: $0) }))")
        }
        let tiles = collectionView.visibleItems().compactMap { $0 as? SoundTileItem }
        print("[dump] visible names \(tiles.compactMap { $0.file?.displayName }.sorted { $0.localizedStandardCompare($1) == .orderedAscending })")
        print("[dump] visible items \(tiles.count), with artwork \(tiles.filter { $0.tile.artwork != nil }.count): \(tiles.filter { $0.tile.artwork != nil }.compactMap { $0.file?.displayName }.sorted())")
    }

    private static func findCollectionView(in view: NSView?) -> SoundCollectionView? {
        guard let view else { return nil }
        if let match = view as? SoundCollectionView { return match }
        for subview in view.subviews {
            if let match = findCollectionView(in: subview) { return match }
        }
        return nil
    }
}
#endif
