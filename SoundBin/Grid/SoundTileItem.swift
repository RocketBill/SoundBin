import AppKit
import Symbols

/// One tile in the grid. Views are recycled as you scroll, so all per-file state is reset in `configure`.
final class SoundTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("SoundTileItem")

    private(set) var file: AudioFile?
    private var waveformToken: BackgroundLoader<Waveform>.Token?
    private weak var waveformLoader: BackgroundLoader<Waveform>?
    private var artworkToken: BackgroundLoader<Artwork>.Token?
    private weak var artworkLoader: BackgroundLoader<Artwork>?
    private var showsArtwork = false

    var tile: SoundTileView { view as! SoundTileView }

    override func loadView() {
        view = SoundTileView()
    }

    override var isSelected: Bool {
        didSet { tile.isSelected = isSelected }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { tile.isHighlighted = highlightState == .forSelection }
    }

    /// Pass `artworks` as nil when artwork display is turned off.
    func configure(with file: AudioFile, name: String, isFavourite: Bool, labels: Set<SoundLabel>,
                   waveforms: BackgroundLoader<Waveform>, artworks: BackgroundLoader<Artwork>?) {
        let isNewFile = self.file != file
        self.file = file
        tile.show(file, name: name)
        tile.isFavourite = isFavourite
        tile.labels = labels
        if isNewFile || tile.waveformView.waveform == nil {
            loadWaveform(for: file, from: waveforms)
        }
        if isNewFile || showsArtwork != (artworks != nil) {
            loadArtwork(for: file, from: artworks, animated: !isNewFile)
        }
    }

    private func loadWaveform(for file: AudioFile, from waveforms: BackgroundLoader<Waveform>) {
        cancelWaveformRequest()
        if let cached = waveforms.cached(file) {
            tile.waveformView.setWaveform(cached, animated: false)
            return
        }
        tile.waveformView.setWaveform(nil, animated: false)
        waveformLoader = waveforms
        waveformToken = waveforms.request(file) { [weak self] waveform in
            guard let self, self.file == file else { return }
            waveformToken = nil
            tile.waveformView.setWaveform(waveform, animated: true)
        }
    }

    private func loadArtwork(for file: AudioFile, from artworks: BackgroundLoader<Artwork>?, animated: Bool) {
        cancelArtworkRequest()
        showsArtwork = artworks != nil
        guard let artworks else {
            tile.setArtwork(nil, animated: animated)
            return
        }
        if let cached = artworks.cached(file) {
            tile.setArtwork(cached.image, animated: animated)
            return
        }
        // Files without art are the common case, so the plain waveform shows until art turns up.
        tile.setArtwork(nil, animated: false)
        artworkLoader = artworks
        artworkToken = artworks.request(file) { [weak self] artwork in
            guard let self, self.file == file, showsArtwork else { return }
            artworkToken = nil
            tile.setArtwork(artwork.image, animated: true)
        }
    }

    /// `progress` is nil when this tile isn't the current sound.
    func setPlayback(progress: Double?, isPlaying: Bool) {
        tile.setPlayback(progress: progress, isPlaying: isPlaying)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelWaveformRequest()
        cancelArtworkRequest()
        file = nil
        tile.cancelEditingName()
        tile.setPlayback(progress: nil, isPlaying: false)
        tile.isHovered = false
    }

    private func cancelWaveformRequest() {
        if let waveformToken { waveformLoader?.cancel(waveformToken) }
        waveformToken = nil
    }

    private func cancelArtworkRequest() {
        if let artworkToken { artworkLoader?.cancel(artworkToken) }
        artworkToken = nil
    }
}

// MARK: - Tile view

final class SoundTileView: NSView, NSTextFieldDelegate {
    static let padding: CGFloat = 8
    static let textHeight: CGFloat = 38

    static func height(forWidth width: CGFloat) -> CGFloat {
        padding + waveformHeight(forWidth: width) + 6 + textHeight + 2
    }

    static func waveformHeight(forWidth width: CGFloat) -> CGFloat {
        ((width - padding * 2) * 0.46).rounded()
    }

    let waveformView = TileWaveformView()
    private let artworkView = ArtworkView()
    private(set) var artwork: CGImage?
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let playingIcon = NSImageView()
    private let starIcon = NSImageView()
    private let labelDots = LabelDotsView()
    private var showsPlayingIcon = false
    private var isAnimatingIcon = false
    /// Made the first time the tile's name is edited, then kept hidden between edits.
    private var nameEditor: NSTextField?
    private var onNameEditEnd: ((String?) -> Void)?
    private var cancelsNameEdit = false

    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true } } }
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            updateStar()
        }
    }
    var isFavourite = false { didSet { if isFavourite != oldValue { updateStar() } } }
    var labels: Set<SoundLabel> {
        get { labelDots.labels }
        set {
            guard newValue != labelDots.labels else { return }
            labelDots.labels = newValue
            needsLayout = true
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Nothing should ever draw outside the card, even mid-resize.
        clipsToBounds = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        playingIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing")
        playingIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        playingIcon.contentTintColor = .controlAccentColor
        playingIcon.isHidden = true

        starIcon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        starIcon.isHidden = true

        for view in [artworkView, waveformView, nameLabel, detailLabel, playingIcon, starIcon, labelDots] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// The tile handles clicks as one unit, so first-click behaviour doesn't depend on which subview is hit.
    /// The exception is the name while it's being edited, so the text can be clicked into.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, let nameEditor, !nameEditor.isHidden, hit.isDescendant(of: nameEditor) { return hit }
        return hit == nil ? nil : self
    }

    /// Clicking a tile while another app (say, a DAW) is in front plays it straight away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ file: AudioFile, name: String) {
        if nameLabel.stringValue != name {
            nameLabel.stringValue = name
            needsLayout = true
        }
        detailLabel.stringValue = file.summary
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(name), \(Format.duration(file.duration)), \(file.formatName)")
    }

    // MARK: Renaming

    /// Swaps the name for a text field, as Finder does. `onEnd` receives the edited name, or nil if
    /// editing was cancelled. Return or Tab keeps the edit, as does clicking elsewhere; Escape cancels.
    func beginEditingName(onEnd: @escaping (String?) -> Void) {
        let editor = nameEditor ?? makeNameEditor()
        editor.stringValue = nameLabel.stringValue
        editor.isHidden = false
        nameLabel.isHidden = true
        onNameEditEnd = onEnd
        cancelsNameEdit = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        if window?.makeFirstResponder(editor) != true { cancelEditingName() }
    }

    /// Abandons an edit in progress, as when the tile is reused for another sound.
    func cancelEditingName() {
        guard let nameEditor, !nameEditor.isHidden else { return }
        cancelsNameEdit = true
        if nameEditor.currentEditor() != nil { window?.makeFirstResponder(superview) }
        finishEditingName()
    }

    private func makeNameEditor() -> NSTextField {
        let editor = NSTextField(string: "")
        editor.font = nameLabel.font
        editor.isBordered = false
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.focusRingType = .exterior
        editor.usesSingleLineMode = true
        editor.cell?.isScrollable = true
        editor.cell?.wraps = false
        editor.delegate = self
        addSubview(editor)
        nameEditor = editor
        return editor
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(cancelOperation(_:)):
            cancelsNameEdit = true
            fallthrough
        case #selector(insertNewline(_:)), #selector(insertTab(_:)), #selector(insertBacktab(_:)):
            // Focus goes back to the grid, so the arrow keys carry on moving between sounds. That ends the edit.
            window?.makeFirstResponder(superview)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishEditingName()
    }

    private func finishEditingName() {
        guard let nameEditor, !nameEditor.isHidden else { return }
        let name = cancelsNameEdit ? nil : nameEditor.stringValue
        // Hidden rather than removed, as this can run while the field is still finishing its own editing.
        nameEditor.isHidden = true
        nameLabel.isHidden = false
        let onEnd = onNameEditEnd
        onNameEditEnd = nil
        onEnd?(name)
    }

    func setPlayback(progress: Double?, isPlaying: Bool) {
        waveformView.progress = progress
        let showIcon = progress != nil
        if showIcon != showsPlayingIcon {
            showsPlayingIcon = showIcon
            playingIcon.isHidden = !showIcon
            needsLayout = true
        }
        if isPlaying != isAnimatingIcon {
            isAnimatingIcon = isPlaying
            if isPlaying {
                playingIcon.addSymbolEffect(.variableColor.iterative.dimInactiveLayers)
            } else {
                playingIcon.removeAllSymbolEffects()
            }
        }
    }

    /// With artwork, the image fills the thumbnail area and the waveform moves into a strip along its bottom.
    func setArtwork(_ image: CGImage?, animated: Bool) {
        guard image !== artwork else { return }
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            layer?.add(fade, forKey: "artwork")
        }
        artwork = image
        artworkView.image = image
        artworkView.isHidden = image == nil
        waveformView.style = image == nil ? .well : .strip
        starIcon.shadow = image == nil ? nil : Self.starShadow
        updateStar()
        needsLayout = true
    }

    private static let starShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        return shadow
    }()

    /// The star in the waveform's corner toggles favourites. Only live while it's visible.
    func isStarHit(at point: NSPoint) -> Bool {
        !starIcon.isHidden && starIcon.frame.insetBy(dx: -5, dy: -5).contains(point)
    }

    private func updateStar() {
        starIcon.isHidden = !(isFavourite || isHovered)
        starIcon.image = NSImage(systemSymbolName: isFavourite ? "star.fill" : "star",
                                 accessibilityDescription: isFavourite ? "Favourite" : "Add to Favourites")
        starIcon.contentTintColor = isFavourite ? .systemYellow : (artwork == nil ? .secondaryLabelColor : .white)
    }

    // MARK: Layout & drawing

    override func layout() {
        super.layout()
        let padding = Self.padding
        let width = bounds.width - padding * 2
        let waveHeight = Self.waveformHeight(forWidth: bounds.width)
        let thumbnail = NSRect(x: padding, y: padding, width: width, height: waveHeight)
        artworkView.frame = thumbnail
        if artwork == nil {
            waveformView.frame = thumbnail
        } else {
            let inset: CGFloat = 5
            let stripHeight = max(22, (waveHeight * 0.3).rounded())
            waveformView.frame = NSRect(x: thumbnail.minX + inset, y: thumbnail.maxY - stripHeight - inset,
                                        width: thumbnail.width - inset * 2, height: stripHeight)
        }

        let starSize: CGFloat = 16
        starIcon.frame = NSRect(x: thumbnail.maxX - starSize - 5, y: thumbnail.minY + 5,
                                width: starSize, height: starSize)

        let textTop = thumbnail.maxY + 7
        var nameX = padding + 1
        if showsPlayingIcon {
            playingIcon.frame = NSRect(x: nameX, y: textTop + 1, width: 16, height: 15)
            nameX += 18
        }
        // Label dots follow the name, Finder style; a long name gives way so they stay visible.
        let dotsWidth = labelDots.intrinsicContentSize.width
        let nameRoom = bounds.width - nameX - padding - (dotsWidth > 0 ? dotsWidth + 4 : 0)
        let nameWidth = min(ceil(nameLabel.attributedStringValue.size().width) + 4, max(0, nameRoom))
        nameLabel.frame = NSRect(x: nameX, y: textTop, width: nameWidth, height: 17)
        labelDots.frame = NSRect(x: nameLabel.frame.maxX + 2, y: textTop + 2.5, width: dotsWidth, height: 12)
        // While editing, the name gets the whole width, covering the label dots.
        nameEditor?.frame = NSRect(x: nameX, y: textTop, width: max(0, bounds.width - nameX - padding), height: 17)
        detailLabel.frame = NSRect(x: padding + 1, y: textTop + 18, width: width - 1, height: 15)
    }

    override func updateLayer() {
        let emphasized = (superview as? SoundCollectionView)?.isEmphasized ?? true
        // A labelled tile is washed in its first label's colour, and keeps that colour when selected so
        // the selection ring is what changes.
        let labelColor = labels.min { $0.rawValue < $1.rawValue }?.color
        if isSelected || isHighlighted {
            let accent = emphasized ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor
            if let labelColor {
                layer?.backgroundColor = labelColor.withAlphaComponent(0.3).cgColor
                layer?.borderColor = (emphasized ? accent : NSColor.secondaryLabelColor).cgColor
                layer?.borderWidth = 2
            } else {
                layer?.backgroundColor = accent.withAlphaComponent(emphasized ? 0.22 : 0.9).cgColor
                layer?.borderColor = (emphasized ? NSColor.controlAccentColor : .clear).cgColor
                layer?.borderWidth = emphasized ? 2 : 0
            }
        } else if let labelColor {
            layer?.backgroundColor = labelColor.withAlphaComponent(isHovered ? 0.26 : 0.18).cgColor
            layer?.borderWidth = 0
        } else {
            layer?.backgroundColor = (isHovered ? Palette.tileHover : Palette.tile).cgColor
            layer?.borderWidth = 0
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        (superview as? SoundCollectionView)?.setHovered(self)
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovered else { return }
        (superview as? SoundCollectionView)?.setHovered(nil)
    }
}

// MARK: - Label dots

/// Overlapping coloured dots for a sound's labels, each ringed in the tile colour so they read as separate.
final class LabelDotsView: NSView {
    static let diameter: CGFloat = 12
    static let step: CGFloat = 7

    var labels: Set<SoundLabel> = [] {
        didSet {
            guard labels != oldValue else { return }
            ordered = labels.sorted { $0.rawValue < $1.rawValue }
            isHidden = labels.isEmpty
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var ordered: [SoundLabel] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard !ordered.isEmpty else { return .zero }
        return NSSize(width: Self.diameter + Self.step * CGFloat(ordered.count - 1), height: Self.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The leftmost dot sits on top, as Finder stacks tags, so draw right to left.
        for (index, label) in ordered.enumerated().reversed() {
            let rect = NSRect(x: Self.step * CGFloat(index), y: 0, width: Self.diameter, height: Self.diameter)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            label.color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
        }
    }
}

// MARK: - Waveform view

final class TileWaveformView: NSView {
    /// Every tile draws the same number of bars, so resizing tiles scales the waveform rather than
    /// revealing more detail.
    static let barCount = 48

    enum Style {
        /// Fills the thumbnail area on a light/dark well.
        case well
        /// A compact dark strip laid over artwork.
        case strip
    }

    var style = Style.well {
        didSet {
            guard style != oldValue else { return }
            cachedPath = nil
            needsDisplay = true
        }
    }

    private(set) var waveform: Waveform?
    private var cachedPath: CGPath?
    private var cachedBounds: CGRect = .zero

    /// Playback position in 0...1, or nil when this isn't the current sound.
    var progress: Double? {
        didSet { if progress != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Redraw at the new size whenever tiles are resized. Otherwise AppKit keeps the drawing made at
        // the old size, which spills over the labels when tiles shrink.
        layerContentsRedrawPolicy = .duringViewResize
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func setWaveform(_ waveform: Waveform?, animated: Bool) {
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            layer?.add(fade, forKey: "waveform")
        }
        self.waveform = waveform
        cachedPath = nil
        needsDisplay = true
    }

    private var barsRect: CGRect {
        style == .well ? bounds.insetBy(dx: 8, dy: 10) : bounds.insetBy(dx: 7, dy: 5)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let isStrip = style == .strip
        (isStrip ? NSColor.black.withAlphaComponent(0.55) : Palette.well).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: isStrip ? 6 : 7, yRadius: isStrip ? 6 : 7).fill()

        let rect = barsRect
        if cachedPath == nil || cachedBounds != bounds {
            cachedPath = WaveformPath.make(waveform, in: rect, barCount: Self.barCount)
            cachedBounds = bounds
        }
        guard let path = cachedPath else { return }

        let barColor: NSColor = switch (isStrip, waveform == nil) {
        case (false, true): .quaternaryLabelColor
        case (false, false): .secondaryLabelColor
        case (true, true): .white.withAlphaComponent(0.3)
        case (true, false): .white.withAlphaComponent(0.8)
        }
        context.addPath(path)
        context.setFillColor(barColor.cgColor)
        context.fillPath()

        guard let progress else { return }
        let playheadX = (rect.minX + rect.width * progress).rounded()
        context.saveGState()
        context.clip(to: CGRect(x: bounds.minX, y: bounds.minY, width: playheadX - bounds.minX, height: bounds.height))
        context.addPath(path)
        context.setFillColor(NSColor.controlAccentColor.cgColor)
        context.fillPath()
        context.restoreGState()

        context.setFillColor((isStrip ? NSColor.white : NSColor.labelColor).cgColor)
        context.fill(CGRect(x: playheadX - 0.75, y: rect.minY - 3, width: 1.5, height: rect.height + 6))
    }
}

// MARK: - Artwork view

/// Shows cover art scaled to fill, clipped to the thumbnail's rounded corners.
final class ArtworkView: NSView {
    var image: CGImage? {
        didSet { if image !== oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
        // A hairline keeps pale artwork from bleeding into a light tile.
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

// MARK: - Colours

/// Tile colours tuned separately for light and dark mode.
nonisolated enum Palette {
    static let tile = dynamic(light: NSColor.black.withAlphaComponent(0.04), dark: NSColor.white.withAlphaComponent(0.06))
    static let tileHover = dynamic(light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.1))
    static let well = dynamic(light: NSColor.white.withAlphaComponent(0.85), dark: NSColor.black.withAlphaComponent(0.24))

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
