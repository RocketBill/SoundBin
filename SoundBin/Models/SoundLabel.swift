import AppKit

/// One of the seven label colours, as in Finder. Each can be renamed, and a sound can carry several.
nonisolated enum SoundLabel: Int, CaseIterable, Codable, Identifiable, Sendable {
    case red, orange, yellow, green, blue, purple, grey

    var id: Int { rawValue }

    var defaultName: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .grey: "Grey"
        }
    }

    var color: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .grey: .systemGray
        }
    }

    /// ⌥⌘1 to ⌥⌘7 toggle the labels in order.
    var shortcutDigit: Character {
        Character(String(rawValue + 1))
    }

    /// A filled dot in the label's colour, for menus. Not a template, so menus keep the colour.
    var dot: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
