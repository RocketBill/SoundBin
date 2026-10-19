import AppKit

enum MoveDirection {
    case up, down, left, right
}

protocol SoundCollectionViewDelegate: AnyObject {
    /// Return true to swallow the click (e.g. it hit a tile's star) so selection doesn't change.
    func soundCollectionView(_ view: SoundCollectionView, mouseDownOnItemAt indexPath: IndexPath, with event: NSEvent) -> Bool
    func soundCollectionView(_ view: SoundCollectionView, move direction: MoveDirection, extendingSelection: Bool)
    func soundCollectionView(_ view: SoundCollectionView, menuForItemAt indexPath: IndexPath) -> NSMenu?
    func soundCollectionViewTogglePlayback(_ view: SoundCollectionView)
    func soundCollectionViewPlaySelection(_ view: SoundCollectionView)
    func soundCollectionViewStop(_ view: SoundCollectionView)
    func soundCollectionViewToggleFavourite(_ view: SoundCollectionView)
    func soundCollectionViewCopy(_ view: SoundCollectionView)
    /// Delete key. Return false if there's nothing to delete, so the key beeps.
    func soundCollectionViewDelete(_ view: SoundCollectionView) -> Bool
}

/// Adds sample-browser keyboard and mouse behaviour on top of NSCollectionView:
/// arrows move and audition, Space plays/stops, "." stars (as in Photos), Esc stops, Delete removes from a collection.
final class SoundCollectionView: NSCollectionView {
    weak var soundDelegate: SoundCollectionViewDelegate?

    /// Selection draws in the accent colour only while the grid has focus in the key window, as Finder does.
    private(set) var isEmphasized = false

    private var windowObservers: [NSObjectProtocol] = []
    private var scrollObserver: NSObjectProtocol?

    /// Only one tile shows hover state at a time. Tracking areas don't reliably send "exited" when
    /// tiles scroll out from under a still pointer, so hover is owned here and re-checked on scroll.
    private weak var hoveredTile: SoundTileView?

    func setHovered(_ tile: SoundTileView?) {
        if hoveredTile !== tile { hoveredTile?.isHovered = false }
        hoveredTile = tile
        tile?.isHovered = true
    }

    private func updateHoverAfterScroll() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let item = indexPathForItem(at: point).flatMap { self.item(at: $0) }
        setHovered(item?.view as? SoundTileView)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard let clipView = superview as? NSClipView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHoverAfterScroll() }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    /// Clicking a tile while another app (say, a DAW) is in front plays it straight away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateEmphasis()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        DispatchQueue.main.async { self.updateEmphasis() }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEmphasis() }
            })
        }
        updateEmphasis()
    }

    private func updateEmphasis() {
        let emphasized = window?.isKeyWindow == true && window?.firstResponder === self
        guard emphasized != isEmphasized else { return }
        isEmphasized = emphasized
        for item in visibleItems() {
            item.view.needsDisplay = true
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point),
           soundDelegate?.soundCollectionView(self, mouseDownOnItemAt: indexPath, with: event) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return soundDelegate?.soundCollectionView(self, menuForItemAt: indexPath)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else {
            super.keyDown(with: event)
            return
        }

        switch event.specialKey {
        case .upArrow: return move(.up, event)
        case .downArrow: return move(.down, event)
        case .leftArrow: return move(.left, event)
        case .rightArrow: return move(.right, event)
        case .carriageReturn, .enter:
            soundDelegate?.soundCollectionViewPlaySelection(self)
            return
        case .delete, .deleteForward:
            if soundDelegate?.soundCollectionViewDelete(self) == true { return }
        default: break
        }

        switch event.charactersIgnoringModifiers {
        case " ":
            soundDelegate?.soundCollectionViewTogglePlayback(self)
        case ".":
            soundDelegate?.soundCollectionViewToggleFavourite(self)
        case "\u{1b}":
            soundDelegate?.soundCollectionViewStop(self)
        default:
            super.keyDown(with: event)
        }
    }

    private func move(_ direction: MoveDirection, _ event: NSEvent) {
        soundDelegate?.soundCollectionView(self, move: direction, extendingSelection: event.modifierFlags.contains(.shift))
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) {
        soundDelegate?.soundCollectionViewCopy(self)
    }

}

extension SoundCollectionView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return !selectionIndexPaths.isEmpty
        }
        return true
    }
}
