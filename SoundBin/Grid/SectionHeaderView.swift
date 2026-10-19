import AppKit

/// Folder header above each group of tiles. Clicking it collapses or expands the group.
final class SectionHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("SectionHeaderView")
    static let height: CGFloat = 34

    var onToggle: (() -> Void)?

    private let chevron = NSImageView()
    private let folderIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        chevron.contentTintColor = .tertiaryLabelColor

        folderIcon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        folderIcon.contentTintColor = .secondaryLabelColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = .secondaryLabelColor

        for view in [chevron, folderIcon, titleLabel, countLabel] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func configure(title: String, count: Int, isCollapsed: Bool, symbolName: String) {
        titleLabel.stringValue = title
        countLabel.stringValue = count.formatted()
        chevron.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
                                accessibilityDescription: isCollapsed ? "Expand" : "Collapse")
        folderIcon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        setAccessibilityLabel("\(title), \(Format.soundCount(count))")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        chevron.frame = NSRect(x: 22, y: midY - 7, width: 12, height: 14)
        folderIcon.frame = NSRect(x: 38, y: midY - 9, width: 20, height: 18)

        let countWidth = ceil(countLabel.attributedStringValue.size().width) + 6
        let titleX: CGFloat = 62
        let titleWidth = min(ceil(titleLabel.attributedStringValue.size().width) + 6, bounds.width - titleX - countWidth - 30)
        titleLabel.frame = NSRect(x: titleX, y: midY - 9, width: max(0, titleWidth), height: 18)
        countLabel.frame = NSRect(x: titleLabel.frame.maxX + 8, y: midY - 8, width: countWidth, height: 16)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }
}
