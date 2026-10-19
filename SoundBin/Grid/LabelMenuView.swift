import AppKit

/// The row of label colours at the top of a sound's context menu, as in Finder. Clicking a colour toggles
/// that label on the selected sounds; hovering one shows its name underneath.
final class LabelMenuView: NSView {
    enum State {
        case off, mixed, on
    }

    private static let dotSize: CGFloat = 18
    private static let spacing: CGFloat = 7
    private static let inset: CGFloat = 14

    private let states: [SoundLabel: State]
    private let name: (SoundLabel) -> String
    private let onToggle: (SoundLabel) -> Void
    private let nameLabel = NSTextField(labelWithString: "")
    private var hovered: SoundLabel? {
        didSet {
            guard hovered != oldValue else { return }
            nameLabel.stringValue = hovered.map(name) ?? ""
            needsDisplay = true
        }
    }

    init(states: [SoundLabel: State], name: @escaping (SoundLabel) -> String, onToggle: @escaping (SoundLabel) -> Void) {
        self.states = states
        self.name = name
        self.onToggle = onToggle
        let count = CGFloat(SoundLabel.allCases.count)
        let width = Self.inset * 2 + count * Self.dotSize + (count - 1) * Self.spacing
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 46))

        nameLabel.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: Self.inset, y: 29, width: width - Self.inset * 2, height: 14)
        addSubview(nameLabel)

        setAccessibilityElement(false)
        setAccessibilityChildren(SoundLabel.allCases.map { label in
            LabelDotElement(title: name(label), isOn: states[label] == .on, frame: dotRect(for: label), parent: self) { [weak self] in
                self?.choose(label)
            }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func dotRect(for label: SoundLabel) -> NSRect {
        NSRect(x: Self.inset + CGFloat(label.rawValue) * (Self.dotSize + Self.spacing), y: 7,
               width: Self.dotSize, height: Self.dotSize)
    }

    private func label(at point: NSPoint) -> SoundLabel? {
        SoundLabel.allCases.first { dotRect(for: $0).insetBy(dx: -Self.spacing / 2, dy: -4).contains(point) }
    }

    private func choose(_ label: SoundLabel) {
        onToggle(label)
        enclosingMenuItem?.menu?.cancelTracking()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = label(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    override func mouseUp(with event: NSEvent) {
        if let label = label(at: convert(event.locationInWindow, from: nil)) {
            choose(label)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for label in SoundLabel.allCases {
            let rect = dotRect(for: label)
            let isHovered = label == hovered
            label.color.setFill()
            NSBezierPath(ovalIn: isHovered ? rect : rect.insetBy(dx: 1.5, dy: 1.5)).fill()

            let mark: String? = switch states[label] ?? .off {
            case .on: isHovered ? "xmark" : "checkmark"
            case .mixed: isHovered ? "checkmark" : "minus"
            case .off: isHovered ? "plus" : nil
            }
            guard let mark,
                  let symbol = NSImage(systemSymbolName: mark, accessibilityDescription: nil)?
                      .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)
                          .applying(.init(paletteColors: [.white])))
            else { continue }
            let size = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height))
        }
    }
}

/// Exposes each colour to VoiceOver as its own checkbox.
nonisolated private final class LabelDotElement: NSAccessibilityElement {
    private let press: @MainActor () -> Void

    init(title: String, isOn: Bool, frame: NSRect, parent: NSView, press: @escaping @MainActor () -> Void) {
        self.press = press
        super.init()
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn ? 1 : 0)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frame)
    }

    override func accessibilityPerformPress() -> Bool {
        let press = press
        MainActor.assumeIsolated { press() }
        return true
    }
}
